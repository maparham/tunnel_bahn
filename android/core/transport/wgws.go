package transport

import (
	"context"
	"net"
	"net/netip"
	"sync"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"

	"tunnelbahn/core/wstunnel"
)

// relayEndpoint is a stub conn.Endpoint. The relay bind always forwards to the
// wstunnel relay regardless of endpoint, so the address is cosmetic; it only needs
// to be a syntactically stable value for WG's single peer.
type relayEndpoint struct{ dst netip.AddrPort }

func (e relayEndpoint) ClearSrc()           {}
func (e relayEndpoint) SrcToString() string { return "" }
func (e relayEndpoint) DstToString() string { return e.dst.String() }
func (e relayEndpoint) DstToBytes() []byte  { return nil }
func (e relayEndpoint) DstIP() netip.Addr   { return e.dst.Addr() }
func (e relayEndpoint) SrcIP() netip.Addr   { return netip.Addr{} }

// relayBind is a conn.Bind that routes WireGuard's UDP through the wstunnel relay
// instead of a real socket. This keeps raw WG off the wire.
//
// The closed channel is per open/close cycle: wireguard-go's BindUpdate always runs
// Close() then Open() on the same bind (even on the first Up), so a one-shot close
// would leave every reopened bind's receive fn returning ErrClosed immediately.
type relayBind struct {
	send    func(ctx context.Context, dg []byte) error
	inbound <-chan []byte

	mu     sync.Mutex
	closed chan struct{}
}

func newRelayBind(send func(context.Context, []byte) error, inbound <-chan []byte) *relayBind {
	return &relayBind{send: send, inbound: inbound, closed: make(chan struct{})}
}

func (b *relayBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	select {
	case <-b.closed:
		b.closed = make(chan struct{})
	default:
	}
	closed := b.closed
	b.mu.Unlock()
	receive := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		select {
		case dg, ok := <-b.inbound:
			if !ok {
				return 0, net.ErrClosed
			}
			n := copy(packets[0], dg)
			sizes[0] = n
			eps[0] = relayEndpoint{}
			return 1, nil
		case <-closed:
			return 0, net.ErrClosed
		}
	}
	return []conn.ReceiveFunc{receive}, port, nil
}

func (b *relayBind) Close() error {
	b.mu.Lock()
	select {
	case <-b.closed:
	default:
		close(b.closed)
	}
	b.mu.Unlock()
	return nil
}

func (b *relayBind) SetMark(uint32) error { return nil }

func (b *relayBind) Send(bufs [][]byte, ep conn.Endpoint) error {
	for _, buf := range bufs {
		dg := make([]byte, len(buf)) // copy: the device reuses bufs after Send returns
		copy(dg, buf)
		if err := b.send(context.Background(), dg); err != nil {
			return err
		}
	}
	return nil
}

func (b *relayBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	if err != nil {
		return relayEndpoint{}, nil // endpoint is ignored; tolerate anything
	}
	return relayEndpoint{dst: ap}, nil
}

func (b *relayBind) BatchSize() int { return 1 }

type WGWS struct {
	dev   *device.Device
	tnet  *netstack.Net
	relay *wstunnel.Relay
}

func NewWGWS(cfg WGConfig) (*WGWS, error) {
	inbound := make(chan []byte, 256)
	bind := newRelayBind(cfg.Relay.Send, inbound)
	// Endpoint is ignored by relayBind but must be syntactically valid.
	dev, tnet, err := newWGDevice(cfg, bind, "127.0.0.1:51820")
	if err != nil {
		cfg.Relay.Close()
		return nil, err
	}
	// Forward relay -> WG only after the device is up. Starting this before the
	// fallible IpcSet/Up steps meant an early construction failure left the goroutine
	// blocked on Recv() forever and the relay leaked (the relay dials lazily, so its
	// Recv channel never closes on its own). close(inbound) fires when the relay is
	// closed, which unblocks the bind's receive fn.
	go func() {
		defer close(inbound)
		for dg := range cfg.Relay.Recv() {
			select {
			case inbound <- dg:
			default: // drop if WG is not draining fast enough
			}
		}
	}()
	return &WGWS{dev: dev, tnet: tnet, relay: cfg.Relay}, nil
}

// WaitReady blocks until the WG peer completes its first handshake (proving the
// tunnel actually reaches the server), or ctx is done, or the carrier dial fails.
//
// NewWGWS does zero network I/O, and dev.Up() only brings the local device up, so a
// constructed WGWS is not yet connected. The peer's persistent keepalive makes
// wireguard-go send a handshake initiation on Up, which drives the relay's lazy dial;
// we poll last_handshake_time_sec until it goes non-zero. If that dial fails outright
// (no internet), DialErr surfaces it immediately so we do not idle until the ctx
// deadline.
func (w *WGWS) WaitReady(ctx context.Context) error {
	return waitHandshake(ctx, w.dev, w.relay.DialErr)
}

func (w *WGWS) DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	c, err := w.tnet.DialContextTCPAddrPort(ctx, dst)
	if err != nil {
		return nil, err
	}
	return c, nil
}

func (w *WGWS) DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error) {
	c, err := w.tnet.DialUDPAddrPort(netip.AddrPort{}, dst)
	if err != nil {
		return nil, err
	}
	return c, nil
}

func (w *WGWS) Close() error {
	w.dev.Close()
	return w.relay.Close()
}

package transport

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// udpBind is a conn.Bind over a single, already-connected UDP socket. The socket is
// dialed by the caller through the VpnService-protected dialer, so WireGuard's own
// packets never loop back into the tunnel. Because the socket is connected, the
// endpoint wireguard-go passes to Send is cosmetic and ignored.
//
// Close does not close the socket: wireguard-go's BindUpdate always runs Close() then
// Open() on the same bind (even on the first Up), and waits for the receive goroutines
// to exit in between. Close therefore only has to unblock a pending Read, which it does
// with a read deadline; Open clears that deadline and starts a fresh generation.
type udpBind struct {
	conn net.Conn

	mu     sync.Mutex
	closed chan struct{}
}

func newUDPBind(c net.Conn) *udpBind {
	return &udpBind{conn: c, closed: make(chan struct{})}
}

func (b *udpBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	select {
	case <-b.closed:
		b.closed = make(chan struct{})
	default:
	}
	closed := b.closed
	b.mu.Unlock()
	_ = b.conn.SetReadDeadline(time.Time{})

	receive := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		for {
			n, err := b.conn.Read(packets[0])
			if err != nil {
				select {
				case <-closed:
					return 0, net.ErrClosed
				default:
				}
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() {
					continue // stale deadline from a previous generation
				}
				return 0, err
			}
			sizes[0] = n
			eps[0] = relayEndpoint{}
			return 1, nil
		}
	}
	return []conn.ReceiveFunc{receive}, port, nil
}

func (b *udpBind) Close() error {
	b.mu.Lock()
	select {
	case <-b.closed:
	default:
		close(b.closed)
	}
	b.mu.Unlock()
	// Wake a receive fn blocked in Read so it can observe the closed generation.
	return b.conn.SetReadDeadline(time.Now())
}

func (b *udpBind) SetMark(uint32) error { return nil }

func (b *udpBind) Send(bufs [][]byte, _ conn.Endpoint) error {
	for _, buf := range bufs {
		if _, err := b.conn.Write(buf); err != nil {
			return err
		}
	}
	return nil
}

func (b *udpBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	if err != nil {
		return relayEndpoint{}, nil // endpoint is ignored; tolerate anything
	}
	return relayEndpoint{dst: ap}, nil
}

func (b *udpBind) BatchSize() int { return 1 }

const (
	// watchdogTick is how often the watchdog samples the peer's handshake age.
	watchdogTick = 5 * time.Second
	// handshakeStale is the handshake age past which the server is considered
	// unreachable. With a 25 s persistent keepalive wireguard-go rekeys at least every
	// 2 minutes while packets flow, so 3 minutes of silence is a dead peer, not a
	// quiet one.
	handshakeStale = 180 * time.Second
)

// WG is plain UDP WireGuard over one protected socket. Unlike WGWS it has no carrier
// connection whose liveness can be observed, so a watchdog on the handshake age plays
// that role: it reports degraded when handshakes stop and running when they resume.
type WG struct {
	dev  *device.Device
	tnet *netstack.Net
	conn net.Conn

	stop     chan struct{}
	stopOnce sync.Once
}

// NewWG dials endpoint (host:port; a hostname resolves through dial, i.e. outside the
// tunnel) and builds the device with the socket's resolved remote address as the uapi
// endpoint. onState receives false when handshakes go stale and true when they resume;
// it never fires before the first handshake, which WaitReady owns.
func NewWG(ctx context.Context, cfg WGConfig, endpoint string, dial DialFunc, onState func(bool)) (*WG, error) {
	c, err := dial(ctx, "udp", endpoint)
	if err != nil {
		return nil, fmt.Errorf("wg dial %s: %w", endpoint, err)
	}
	dev, tnet, err := newWGDevice(cfg, newUDPBind(c), c.RemoteAddr().String())
	if err != nil {
		c.Close()
		return nil, err
	}
	w := &WG{dev: dev, tnet: tnet, conn: c, stop: make(chan struct{})}
	go runWatchdog(w.stop, watchdogTick, handshakeStale,
		func() (time.Duration, bool) { return handshakeAge(dev, time.Now()) }, onState)
	return w, nil
}

// runWatchdog samples age every tick and calls onState on each transition between
// fresh (age <= stale) and stale. It starts in the "up" state and ignores samples
// taken before the first handshake, so it cannot fire during the connect phase.
func runWatchdog(stop <-chan struct{}, tick, stale time.Duration, age func() (time.Duration, bool), onState func(bool)) {
	t := time.NewTicker(tick)
	defer t.Stop()
	up := true
	for {
		select {
		case <-stop:
			return
		case <-t.C:
		}
		a, ok := age()
		if !ok {
			continue
		}
		fresh := a <= stale
		if fresh == up {
			continue
		}
		up = fresh
		if onState != nil {
			onState(fresh)
		}
	}
}

// WaitReady blocks until the first handshake or ctx is done. A UDP dial to an
// unreachable network already failed in NewWG, so there is no carrier error to
// short-circuit on here; a silent server runs to the caller's deadline.
func (w *WG) WaitReady(ctx context.Context) error {
	return waitHandshake(ctx, w.dev, nil)
}

func (w *WG) DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	return w.tnet.DialContextTCPAddrPort(ctx, dst)
}

func (w *WG) DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error) {
	return w.tnet.DialUDPAddrPort(netip.AddrPort{}, dst)
}

func (w *WG) Close() error {
	w.stopOnce.Do(func() { close(w.stop) })
	w.dev.Close()
	return w.conn.Close()
}

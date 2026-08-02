package transport

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"net/netip"
	"strings"
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
type relayBind struct {
	send    func(ctx context.Context, dg []byte) error
	inbound <-chan []byte
	closed  chan struct{}
	once    sync.Once
}

func newRelayBind(send func(context.Context, []byte) error, inbound <-chan []byte) *relayBind {
	return &relayBind{send: send, inbound: inbound, closed: make(chan struct{})}
}

func (b *relayBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	return []conn.ReceiveFunc{b.receive}, port, nil
}

func (b *relayBind) receive(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
	select {
	case dg, ok := <-b.inbound:
		if !ok {
			return 0, net.ErrClosed
		}
		n := copy(packets[0], dg)
		sizes[0] = n
		eps[0] = relayEndpoint{}
		return 1, nil
	case <-b.closed:
		return 0, net.ErrClosed
	}
}

func (b *relayBind) Close() error {
	b.once.Do(func() { close(b.closed) })
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

// WGConfig configures a WG-over-wstunnel transport.
type WGConfig struct {
	PrivateKey       string // standard-base64 32-byte key
	PeerPublicKey    string // standard-base64 32-byte key
	PeerPresharedKey string // optional standard-base64 32-byte key
	LocalAddrs       []netip.Addr
	DNS              []netip.Addr
	MTU              int
	Relay            *wstunnel.Relay
}

type WGWS struct {
	dev   *device.Device
	tnet  *netstack.Net
	relay *wstunnel.Relay
}

func NewWGWS(cfg WGConfig) (*WGWS, error) {
	tunDev, tnet, err := netstack.CreateNetTUN(cfg.LocalAddrs, cfg.DNS, mtuOrDefault(cfg.MTU))
	if err != nil {
		return nil, err
	}
	inbound := make(chan []byte, 256)
	go func() {
		defer close(inbound)
		for dg := range cfg.Relay.Recv() {
			select {
			case inbound <- dg:
			default: // drop if WG is not draining fast enough
			}
		}
	}()
	bind := newRelayBind(cfg.Relay.Send, inbound)
	dev := device.NewDevice(tunDev, bind, device.NewLogger(device.LogLevelError, "wg "))

	uapi, err := uapiConfig(cfg)
	if err != nil {
		dev.Close()
		return nil, err
	}
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		return nil, err
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, err
	}
	return &WGWS{dev: dev, tnet: tnet, relay: cfg.Relay}, nil
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

func mtuOrDefault(m int) int {
	if m <= 0 {
		return 1280
	}
	return m
}

// uapiConfig builds the wireguard-go IpcSet string. WG keys arrive standard-base64
// (the format the macOS profile stores) and must be converted to hex for uapi.
func uapiConfig(cfg WGConfig) (string, error) {
	priv, err := keyHex(cfg.PrivateKey)
	if err != nil {
		return "", fmt.Errorf("private key: %w", err)
	}
	pub, err := keyHex(cfg.PeerPublicKey)
	if err != nil {
		return "", fmt.Errorf("peer public key: %w", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", priv)
	fmt.Fprintf(&b, "public_key=%s\n", pub)
	if cfg.PeerPresharedKey != "" {
		psk, err := keyHex(cfg.PeerPresharedKey)
		if err != nil {
			return "", fmt.Errorf("preshared key: %w", err)
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", psk)
	}
	// Endpoint is ignored by relayBind but must be syntactically valid.
	fmt.Fprintf(&b, "endpoint=127.0.0.1:51820\n")
	fmt.Fprintf(&b, "persistent_keepalive_interval=25\n")
	fmt.Fprintf(&b, "allowed_ip=0.0.0.0/0\n")
	fmt.Fprintf(&b, "allowed_ip=::/0\n")
	return b.String(), nil
}

func keyHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("want 32-byte key, got %d", len(raw))
	}
	return hex.EncodeToString(raw), nil
}

package core

import (
	"context"
	"net"
	"net/netip"
	"os"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/xjasonlyu/tun2socks/v2/core"
	"github.com/xjasonlyu/tun2socks/v2/core/device"
	"github.com/xjasonlyu/tun2socks/v2/core/device/fdbased"
	M "github.com/xjasonlyu/tun2socks/v2/metadata"
	"github.com/xjasonlyu/tun2socks/v2/tunnel"
	"gvisor.dev/gvisor/pkg/tcpip/stack"

	"tunnelbahn/core/transport"
)

// dispatcher classifies a destination into "tunnel", "bypass", or "dns".
type dispatcher struct {
	r        *Router
	resolver netip.Addr
}

func newDispatcher(r *Router, resolver netip.Addr) *dispatcher {
	return &dispatcher{r: r, resolver: resolver}
}

func (d *dispatcher) route(dst netip.AddrPort, isUDP bool) string {
	// DNS interception: intercept UDP/53 either to the configured resolver (so
	// include mode still resolves through the tunnel, defeating poisoning) OR to any
	// address the router already tunnels (full-tunnel apps with hardcoded resolvers).
	if isUDP && dst.Port() == 53 {
		if d.resolver.IsValid() && dst.Addr() == d.resolver {
			return "dns"
		}
		if d.r.Decision(dst.Addr()) == Tunnel {
			return "dns"
		}
	}
	if d.r.Decision(dst.Addr()) == Tunnel {
		return "tunnel"
	}
	return "bypass"
}

// coreProxy adapts our routing + transports to the tun2socks proxy.Proxy interface.
type coreProxy struct {
	disp     *dispatcher
	tr       transport.Transport
	resolver netip.AddrPort
	dialer   *net.Dialer
	listen   *net.ListenConfig
	ctr      *counters
}

func newCoreProxy(disp *dispatcher, tr transport.Transport, resolver netip.AddrPort, prot Protector, ctr *counters) *coreProxy {
	ctrl := protectedControl(prot)
	return &coreProxy{
		disp:     disp,
		tr:       tr,
		resolver: resolver,
		dialer:   &net.Dialer{Control: ctrl},
		listen:   &net.ListenConfig{Control: ctrl},
		ctr:      ctr,
	}
}

func (p *coreProxy) DialContext(ctx context.Context, m *M.Metadata) (net.Conn, error) {
	dst := m.DestinationAddrPort()
	if p.disp.route(dst, false) == "tunnel" {
		conn, err := p.tr.DialTCP(ctx, dst)
		if err != nil {
			return nil, err
		}
		return p.ctr.wrapConn(conn), nil
	}
	return p.dialer.DialContext(ctx, "tcp", dst.String())
}

func (p *coreProxy) DialUDP(m *M.Metadata) (net.PacketConn, error) {
	dst := m.DestinationAddrPort()
	switch p.disp.route(dst, true) {
	case "dns":
		return newDNSPacketConn(p.tr, p.resolver, m.UDPAddr()), nil
	case "tunnel":
		pc, err := p.tr.DialUDP(context.Background(), dst)
		if err != nil {
			return nil, err
		}
		return p.ctr.wrapPacketConn(tunnelUDP(pc, dst)), nil
	default:
		return p.listen.ListenPacket(context.Background(), "udp", ":0")
	}
}

// protectedControl returns a socket Control hook that calls VpnService.protect(fd),
// keeping the carrier and bypass sockets outside the tunnel (no routing loop).
func protectedControl(prot Protector) func(network, address string, c syscall.RawConn) error {
	return func(_, _ string, rc syscall.RawConn) error {
		if prot == nil {
			return nil
		}
		var perr error
		if err := rc.Control(func(fd uintptr) { perr = prot.Protect(int(fd)) }); err != nil {
			return err
		}
		return perr
	}
}

// singleDstPacketConn adapts a connected net.Conn (e.g. wireguard-go's gonet UDP
// conn) to net.PacketConn for a single fixed destination. gonet's WriteTo sets a
// per-write To address, which a connected endpoint rejects; mapping WriteTo->Write
// sidesteps that. Each tun2socks UDP flow is single-destination, so this is exact.
type singleDstPacketConn struct {
	net.Conn
	dst net.Addr
}

func tunnelUDP(pc net.PacketConn, dst netip.AddrPort) net.PacketConn {
	if nc, ok := pc.(net.Conn); ok {
		return &singleDstPacketConn{Conn: nc, dst: net.UDPAddrFromAddrPort(dst)}
	}
	return pc
}

func (c *singleDstPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, err := c.Conn.Read(p)
	return n, c.dst, err
}

func (c *singleDstPacketConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	return c.Conn.Write(p)
}

// dnsPacketConn intercepts UDP/53 flows and answers each query via DNS-over-TCP
// through the tunnel transport, defeating the gateway's UDP DNS poisoning.
type dnsPacketConn struct {
	tr        transport.Transport
	resolver  netip.AddrPort
	dst       net.Addr
	localAddr net.Addr

	resp   chan []byte
	closed chan struct{}
	once   sync.Once

	mu          sync.Mutex
	readDeadline time.Time
}

func newDNSPacketConn(tr transport.Transport, resolver netip.AddrPort, dst net.Addr) *dnsPacketConn {
	return &dnsPacketConn{
		tr:        tr,
		resolver:  resolver,
		dst:       dst,
		localAddr: &net.UDPAddr{IP: net.IPv4zero, Port: 0},
		resp:      make(chan []byte, 8),
		closed:    make(chan struct{}),
	}
}

func (c *dnsPacketConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	query := append([]byte(nil), p...)
	n := len(p)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		resp, err := ResolveOverTCP(ctx, c.tr, c.resolver, query)
		if err != nil {
			return
		}
		select {
		case c.resp <- resp:
		case <-c.closed:
		}
	}()
	return n, nil
}

func (c *dnsPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	c.mu.Lock()
	dl := c.readDeadline
	c.mu.Unlock()

	var timeout <-chan time.Time
	if !dl.IsZero() {
		d := time.Until(dl)
		if d <= 0 {
			return 0, nil, os.ErrDeadlineExceeded
		}
		timer := time.NewTimer(d)
		defer timer.Stop()
		timeout = timer.C
	}

	select {
	case resp := <-c.resp:
		return copy(p, resp), c.dst, nil
	case <-timeout:
		return 0, nil, os.ErrDeadlineExceeded
	case <-c.closed:
		return 0, nil, net.ErrClosed
	}
}

func (c *dnsPacketConn) Close() error {
	c.once.Do(func() { close(c.closed) })
	return nil
}

func (c *dnsPacketConn) LocalAddr() net.Addr { return c.localAddr }

func (c *dnsPacketConn) SetDeadline(t time.Time) error {
	return c.SetReadDeadline(t)
}

func (c *dnsPacketConn) SetReadDeadline(t time.Time) error {
	c.mu.Lock()
	c.readDeadline = t
	c.mu.Unlock()
	return nil
}

func (c *dnsPacketConn) SetWriteDeadline(time.Time) error { return nil }

// engine holds the running tun2socks netstack stack and its device.
type engine struct {
	dev   device.Device
	stack *stack.Stack
}

// startEngine brings up the netstack tun2socks stack on the tun fd with our proxy.
// It deliberately does NOT use engine.Start(), which log.Fatalf's on error (fatal on
// Android). tunnel.T() is a global singleton, so Stop must fully tear the stack down.
func startEngine(tunFD int, mtu int, p *coreProxy) (*engine, error) {
	tunnel.T().SetProxy(p)
	dev, err := fdbased.Open(strconv.Itoa(tunFD), uint32(mtu), 0)
	if err != nil {
		return nil, err
	}
	st, err := core.CreateStack(&core.Config{
		LinkEndpoint:     dev,
		TransportHandler: tunnel.T(),
	})
	if err != nil {
		// Do not close dev here: it would close the tun fd, but Session.Start's
		// deferred close owns the fd on every non-started path. Avoid a double close.
		return nil, err
	}
	return &engine{dev: dev, stack: st}, nil
}

func (e *engine) stop() {
	e.dev.Close()
	e.stack.Close()
	e.stack.Wait()
}

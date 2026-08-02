package core

import (
	"context"
	"net"
	"net/netip"
	"testing"

	M "github.com/xjasonlyu/tun2socks/v2/metadata"

	"tunnelbahn/core/transport"
)

func TestDispatchRoutes(t *testing.T) {
	// resolver 9.9.9.9 is neither in the exclude set nor a test target below.
	d := newDispatcher(NewRouter(ModeExclude, RuleSet{CIDRs: []netip.Prefix{mustPfx("10.0.0.0/8")}}), netip.MustParseAddr("9.9.9.9"))
	if got := d.route(netip.MustParseAddrPort("10.1.1.1:443"), false); got != "bypass" {
		t.Fatalf("exclude in-set: want bypass, got %s", got)
	}
	if got := d.route(netip.MustParseAddrPort("8.8.8.8:443"), false); got != "tunnel" {
		t.Fatalf("exclude out-of-set: want tunnel, got %s", got)
	}
	if got := d.route(netip.MustParseAddrPort("8.8.8.8:53"), true); got != "dns" {
		t.Fatalf("udp/53 to tunneled resolver: want dns, got %s", got)
	}
	if got := d.route(netip.MustParseAddrPort("10.0.0.1:53"), true); got != "bypass" {
		t.Fatalf("udp/53 in bypass set stays bypass, got %s", got)
	}
	// TCP/53 is not the DNS short-circuit path (only UDP/53 is intercepted).
	if got := d.route(netip.MustParseAddrPort("8.8.8.8:53"), false); got != "tunnel" {
		t.Fatalf("tcp/53 to tunneled resolver: want tunnel, got %s", got)
	}
}

func TestDispatchIncludeModeResolverIsTunneled(t *testing.T) {
	// Include mode with a set that does NOT contain the resolver. DNS to the
	// configured resolver must still be intercepted (else it goes direct and is
	// poisoned); other traffic to the resolver IP is not tunneled.
	d := newDispatcher(NewRouter(ModeInclude, RuleSet{CIDRs: []netip.Prefix{mustPfx("172.16.0.0/12")}}), netip.MustParseAddr("1.1.1.1"))
	if got := d.route(netip.MustParseAddrPort("1.1.1.1:53"), true); got != "dns" {
		t.Fatalf("include-mode resolver DNS: want dns, got %s", got)
	}
	if got := d.route(netip.MustParseAddrPort("1.1.1.1:443"), false); got != "bypass" {
		t.Fatalf("include-mode non-DNS to resolver IP: want bypass, got %s", got)
	}
	if got := d.route(netip.MustParseAddrPort("172.16.5.5:443"), false); got != "tunnel" {
		t.Fatalf("include-mode in-set: want tunnel, got %s", got)
	}
}

// fakeTunnelTransport tunnels every DialTCP to an in-memory echo pipe so the test can
// drive bytes through coreProxy's tunnel branch and assert the counters moved.
type fakeTunnelTransport struct{ peer net.Conn }

func (f *fakeTunnelTransport) DialTCP(_ context.Context, _ netip.AddrPort) (net.Conn, error) {
	client, server := net.Pipe()
	f.peer = server
	return client, nil
}
func (f *fakeTunnelTransport) DialUDP(_ context.Context, _ netip.AddrPort) (net.PacketConn, error) {
	return nil, transport.ErrUnsupportedProtocol
}
func (f *fakeTunnelTransport) Close() error { return nil }

func TestCoreProxyCountsTunneledTCP(t *testing.T) {
	// Router in exclude mode with an empty set => every dst is Tunnel.
	disp := newDispatcher(NewRouter(ModeExclude, RuleSet{}), netip.Addr{})
	ctr := &counters{}
	tr := &fakeTunnelTransport{}
	p := newCoreProxy(disp, tr, netip.AddrPort{}, nil, ctr)

	m := &M.Metadata{DstIP: netip.MustParseAddr("93.184.216.34"), DstPort: 443}
	conn, err := p.DialContext(context.Background(), m)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	go func() {
		buf := make([]byte, 8)
		tr.peer.Read(buf)
		tr.peer.Write([]byte("resp"))
	}()
	conn.Write([]byte("get")) // 3 TX
	buf := make([]byte, 4)
	conn.Read(buf) // 4 RX

	if ctr.Tx() != 3 || ctr.Rx() != 4 {
		t.Fatalf("counters: tx=%d rx=%d, want tx=3 rx=4", ctr.Tx(), ctr.Rx())
	}
}

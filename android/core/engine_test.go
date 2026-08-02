package core

import (
	"net/netip"
	"testing"
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

package core

import (
	"net/netip"
	"testing"
)

func TestDispatchRoutes(t *testing.T) {
	d := newDispatcher(NewRouter(ModeExclude, RuleSet{CIDRs: []netip.Prefix{mustPfx("10.0.0.0/8")}}))
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

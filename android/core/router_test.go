package core

import (
	"net/netip"
	"testing"
)

func mustPfx(s string) netip.Prefix { return netip.MustParsePrefix(s) }

func TestRouterIncludeMode(t *testing.T) {
	r := NewRouter(ModeInclude, RuleSet{CIDRs: []netip.Prefix{mustPfx("10.0.0.0/8")}})
	if got := r.Decision(netip.MustParseAddr("10.1.2.3")); got != Tunnel {
		t.Fatalf("in-set include: want Tunnel, got %v", got)
	}
	if got := r.Decision(netip.MustParseAddr("8.8.8.8")); got != Bypass {
		t.Fatalf("out-of-set include: want Bypass, got %v", got)
	}
}

func TestRouterExcludeMode(t *testing.T) {
	r := NewRouter(ModeExclude, RuleSet{CIDRs: []netip.Prefix{mustPfx("10.0.0.0/8")}})
	if got := r.Decision(netip.MustParseAddr("10.1.2.3")); got != Bypass {
		t.Fatalf("in-set exclude: want Bypass, got %v", got)
	}
	if got := r.Decision(netip.MustParseAddr("8.8.8.8")); got != Tunnel {
		t.Fatalf("out-of-set exclude: want Tunnel, got %v", got)
	}
}

func TestRouterBoundaryAndOverlap(t *testing.T) {
	r := NewRouter(ModeInclude, RuleSet{CIDRs: []netip.Prefix{
		mustPfx("192.168.1.0/24"), mustPfx("192.168.0.0/16"),
	}})
	if got := r.Decision(netip.MustParseAddr("192.168.255.255")); got != Tunnel {
		t.Fatalf("overlapping supernet: want Tunnel, got %v", got)
	}
	if got := r.Decision(netip.MustParseAddr("192.169.0.1")); got != Bypass {
		t.Fatalf("just outside: want Bypass, got %v", got)
	}
}

package core

import (
	"net/netip"

	"go4.org/netipx"
)

type Mode int

const (
	ModeInclude Mode = iota
	ModeExclude
)

type Decision int

const (
	Tunnel Decision = iota
	Bypass
)

type RuleSet struct {
	CIDRs []netip.Prefix
}

type Router struct {
	mode Mode
	set  *netipx.IPSet
}

func NewRouter(mode Mode, active RuleSet) *Router {
	var b netipx.IPSetBuilder
	for _, p := range active.CIDRs {
		b.AddPrefix(p)
	}
	set, _ := b.IPSet()
	return &Router{mode: mode, set: set}
}

func (r *Router) Decision(dst netip.Addr) Decision {
	in := r.set.Contains(dst)
	switch r.mode {
	case ModeExclude:
		if in {
			return Bypass
		}
		return Tunnel
	default: // ModeInclude
		if in {
			return Tunnel
		}
		return Bypass
	}
}

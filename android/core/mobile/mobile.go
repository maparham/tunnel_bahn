// Package mobile is the gomobile-bound entry point. gomobile only emits proxy
// classes for types defined in the bound package itself, so the exported surface is
// declared concretely here and delegates to tunnelbahn/core via thin adapters.
package mobile

import "tunnelbahn/core"

// Protector wraps VpnService.protect(fd). Implemented in Kotlin.
type Protector interface {
	Protect(fd int) error
}

// EventSink receives connection lifecycle strings. Implemented in Kotlin.
type EventSink interface {
	OnState(state string)
	OnError(msg string)
}

// Session is the tunnel session facade.
type Session struct {
	inner *core.Session
}

// NewSession creates a new, unstarted session.
func NewSession() *Session { return &Session{inner: core.NewSession()} }

// Start builds the transport, opens the tun engine, and blocks until Stop.
func (s *Session) Start(tunFD int, configJSON string, prot Protector, sink EventSink) error {
	return s.inner.Start(tunFD, configJSON, protectorAdapter{prot}, sinkAdapter{sink})
}

// Stop tears the tunnel down and unblocks Start.
func (s *Session) Stop() { s.inner.Stop() }

type protectorAdapter struct{ p Protector }

func (a protectorAdapter) Protect(fd int) error { return a.p.Protect(fd) }

type sinkAdapter struct{ s EventSink }

func (a sinkAdapter) OnState(state string) { a.s.OnState(state) }
func (a sinkAdapter) OnError(msg string)   { a.s.OnError(msg) }

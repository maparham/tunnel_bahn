package transport

import (
	"context"
	"errors"
	"net"
	"net/netip"
)

// ErrUnsupportedProtocol is returned by a transport that cannot carry a given
// protocol (e.g. the SSH transport rejects UDP).
var ErrUnsupportedProtocol = errors.New("transport: protocol unsupported")

// DialFunc dials the underlying carrier. The caller supplies a protect()ed dialer.
type DialFunc func(ctx context.Context, network, addr string) (net.Conn, error)

// Transport carries tunneled flows to their destination.
type Transport interface {
	// WaitReady blocks until the transport has actually reached the server (the
	// carrier is up and, where applicable, the tunnel has handshaked), or ctx is
	// done. It exists because "constructed" does not mean "connected": the WG
	// transport builds and brings its device up without any network I/O, so the
	// session must gate its "running" signal on this instead of on construction.
	// Returns nil once reachable, ctx.Err() on cancel/timeout, or the carrier's
	// dial error when the server is unreachable (e.g. no internet).
	WaitReady(ctx context.Context) error
	DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error)
	DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error)
	Close() error
}

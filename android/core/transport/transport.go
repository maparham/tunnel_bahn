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
	DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error)
	DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error)
	Close() error
}

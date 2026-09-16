package transport

import (
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

// udpBind is a conn.Bind over a single, already-connected UDP socket. The socket is
// dialed by the caller through the VpnService-protected dialer, so WireGuard's own
// packets never loop back into the tunnel. Because the socket is connected, the
// endpoint wireguard-go passes to Send is cosmetic and ignored.
//
// Close does not close the socket: wireguard-go's BindUpdate always runs Close() then
// Open() on the same bind (even on the first Up), and waits for the receive goroutines
// to exit in between. Close therefore only has to unblock a pending Read, which it does
// with a read deadline; Open clears that deadline and starts a fresh generation.
type udpBind struct {
	conn net.Conn

	mu     sync.Mutex
	closed chan struct{}
}

func newUDPBind(c net.Conn) *udpBind {
	return &udpBind{conn: c, closed: make(chan struct{})}
}

func (b *udpBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	select {
	case <-b.closed:
		b.closed = make(chan struct{})
	default:
	}
	closed := b.closed
	b.mu.Unlock()
	_ = b.conn.SetReadDeadline(time.Time{})

	receive := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		for {
			n, err := b.conn.Read(packets[0])
			if err != nil {
				select {
				case <-closed:
					return 0, net.ErrClosed
				default:
				}
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() {
					continue // stale deadline from a previous generation
				}
				return 0, err
			}
			sizes[0] = n
			eps[0] = relayEndpoint{}
			return 1, nil
		}
	}
	return []conn.ReceiveFunc{receive}, port, nil
}

func (b *udpBind) Close() error {
	b.mu.Lock()
	select {
	case <-b.closed:
	default:
		close(b.closed)
	}
	b.mu.Unlock()
	// Wake a receive fn blocked in Read so it can observe the closed generation.
	return b.conn.SetReadDeadline(time.Now())
}

func (b *udpBind) SetMark(uint32) error { return nil }

func (b *udpBind) Send(bufs [][]byte, _ conn.Endpoint) error {
	for _, buf := range bufs {
		if _, err := b.conn.Write(buf); err != nil {
			return err
		}
	}
	return nil
}

func (b *udpBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	if err != nil {
		return relayEndpoint{}, nil // endpoint is ignored; tolerate anything
	}
	return relayEndpoint{dst: ap}, nil
}

func (b *udpBind) BatchSize() int { return 1 }

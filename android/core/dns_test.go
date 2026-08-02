package core

import (
	"context"
	"encoding/binary"
	"net"
	"net/netip"
	"testing"

	"tunnelbahn/core/transport"
)

// fakeTransport.DialTCP returns a pipe wired to a tiny DoT-shaped echo: it reads the
// 2-byte length + body and replies with the same framing.
type fakeTransport struct{}

func (fakeTransport) DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		var lenBuf [2]byte
		if _, err := readFull(server, lenBuf[:]); err != nil {
			return
		}
		n := binary.BigEndian.Uint16(lenBuf[:])
		body := make([]byte, n)
		if _, err := readFull(server, body); err != nil {
			return
		}
		out := make([]byte, 2+len(body))
		binary.BigEndian.PutUint16(out[:2], uint16(len(body)))
		copy(out[2:], body)
		server.Write(out)
	}()
	return client, nil
}
func (fakeTransport) DialUDP(context.Context, netip.AddrPort) (net.PacketConn, error) {
	return nil, transport.ErrUnsupportedProtocol
}
func (fakeTransport) Close() error { return nil }

func readFull(c net.Conn, b []byte) (int, error) {
	got := 0
	for got < len(b) {
		n, err := c.Read(b[got:])
		got += n
		if err != nil {
			return got, err
		}
	}
	return got, nil
}

func TestResolveOverTCPFraming(t *testing.T) {
	query := []byte{0xAB, 0xCD, 0x01, 0x00} // opaque; server echoes it
	resp, err := ResolveOverTCP(context.Background(), fakeTransport{}, netip.MustParseAddrPort("1.1.1.1:53"), query)
	if err != nil {
		t.Fatal(err)
	}
	if string(resp) != string(query) {
		t.Fatalf("resolve echo mismatch: %x", resp)
	}
}

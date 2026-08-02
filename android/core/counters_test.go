package core

import (
	"net"
	"testing"
)

func TestCountingConnTalliesBothDirections(t *testing.T) {
	c := &counters{}
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	wrapped := c.wrapConn(client)

	go func() {
		buf := make([]byte, 8)
		server.Read(buf)   // drains the client's Write
		server.Write([]byte("world")) // 5 bytes back to the client
	}()

	if _, err := wrapped.Write([]byte("hi!")); err != nil { // 3 bytes TX
		t.Fatalf("write: %v", err)
	}
	buf := make([]byte, 5)
	if _, err := wrapped.Read(buf); err != nil { // 5 bytes RX
		t.Fatalf("read: %v", err)
	}

	if got := c.Tx(); got != 3 {
		t.Fatalf("tx: want 3, got %d", got)
	}
	if got := c.Rx(); got != 5 {
		t.Fatalf("rx: want 5, got %d", got)
	}
}

type fakePacketConn struct {
	net.PacketConn
	readData []byte
}

func (f *fakePacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	return copy(p, f.readData), &net.UDPAddr{}, nil
}
func (f *fakePacketConn) WriteTo(p []byte, _ net.Addr) (int, error) { return len(p), nil }

func TestCountingPacketConnTalliesBothDirections(t *testing.T) {
	c := &counters{}
	wrapped := c.wrapPacketConn(&fakePacketConn{readData: []byte("abcd")}) // 4 RX
	if _, err := wrapped.WriteTo([]byte("xyz"), &net.UDPAddr{}); err != nil { // 3 TX
		t.Fatalf("writeto: %v", err)
	}
	buf := make([]byte, 16)
	wrapped.ReadFrom(buf)
	if got := c.Tx(); got != 3 {
		t.Fatalf("tx: want 3, got %d", got)
	}
	if got := c.Rx(); got != 4 {
		t.Fatalf("rx: want 4, got %d", got)
	}
}

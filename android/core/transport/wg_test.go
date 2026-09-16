package transport

import (
	"errors"
	"net"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

// startUDPEcho returns a loopback UDP server that echoes every datagram back with an
// "echo:" prefix, and its address.
func startUDPEcho(t *testing.T) string {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			pc.WriteTo(append([]byte("echo:"), buf[:n]...), from)
		}
	}()
	return pc.LocalAddr().String()
}

func dialUDP(t *testing.T, addr string) net.Conn {
	t.Helper()
	c, err := net.Dial("udp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func recvOne(t *testing.T, fn conn.ReceiveFunc) (string, error) {
	t.Helper()
	packets := [][]byte{make([]byte, 1500)}
	sizes := make([]int, 1)
	eps := make([]conn.Endpoint, 1)
	n, err := fn(packets, sizes, eps)
	if err != nil {
		return "", err
	}
	if n != 1 {
		t.Fatalf("want 1 packet, got %d", n)
	}
	return string(packets[0][:sizes[0]]), nil
}

func TestUDPBindRoundTrips(t *testing.T) {
	b := newUDPBind(dialUDP(t, startUDPEcho(t)))
	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	if len(fns) != 1 {
		t.Fatalf("want 1 receive fn, got %d", len(fns))
	}
	if err := b.Send([][]byte{[]byte("wg-handshake")}, relayEndpoint{}); err != nil {
		t.Fatal(err)
	}
	got, err := recvOne(t, fns[0])
	if err != nil || got != "echo:wg-handshake" {
		t.Fatalf("round trip: got=%q err=%v", got, err)
	}
}

// wireguard-go's closeBindLocked calls Close() and then waits for every receive
// goroutine to exit before Open(). A receive fn blocked in Read must therefore return
// net.ErrClosed promptly after Close(), without the socket itself being closed.
func TestUDPBindCloseUnblocksReceive(t *testing.T) {
	b := newUDPBind(dialUDP(t, startUDPEcho(t)))
	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := recvOne(t, fns[0])
		done <- err
	}()
	time.Sleep(50 * time.Millisecond) // let the goroutine block in Read
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("want net.ErrClosed after Close, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("receive fn did not return after Close")
	}
}

// The bind must come back alive after a Close-then-Open cycle: wireguard-go does this
// on the very first Up.
func TestUDPBindSurvivesCloseThenOpen(t *testing.T) {
	b := newUDPBind(dialUDP(t, startUDPEcho(t)))
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}
	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	if err := b.Send([][]byte{[]byte("again")}, relayEndpoint{}); err != nil {
		t.Fatal(err)
	}
	got, err := recvOne(t, fns[0])
	if err != nil || got != "echo:again" {
		t.Fatalf("reopened bind is dead: got=%q err=%v", got, err)
	}
}

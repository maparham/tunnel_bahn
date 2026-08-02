package transport

import (
	"context"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

// The custom bind adapter is the unit under test: WG's outbound datagrams must reach
// Relay.Send, and datagrams from Relay.Recv() must be surfaced to WG's ReceiveFunc.
// Full end-to-end WG is validated on-device (Task 15).
func TestRelayBindRoundTrips(t *testing.T) {
	sent := make(chan []byte, 1)
	inbound := make(chan []byte, 1)
	b := newRelayBind(
		func(ctx context.Context, dg []byte) error { sent <- dg; return nil },
		inbound,
	)

	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	if len(fns) != 1 {
		t.Fatalf("want 1 receive fn, got %d", len(fns))
	}

	// Outbound: WG "sends" a handshake datagram; the bind forwards it to the relay.
	if err := b.Send([][]byte{[]byte("wg-handshake")}, relayEndpoint{}); err != nil {
		t.Fatal(err)
	}
	select {
	case dg := <-sent:
		if string(dg) != "wg-handshake" {
			t.Fatalf("send mismatch: %q", dg)
		}
	case <-time.After(time.Second):
		t.Fatal("bind did not forward outbound datagram to relay")
	}

	// Inbound: server "replies"; the bind's receive fn must surface it to WG.
	inbound <- []byte("wg-reply")
	packets := [][]byte{make([]byte, 1500)}
	sizes := make([]int, 1)
	eps := make([]conn.Endpoint, 1)
	n, err := fns[0](packets, sizes, eps)
	if err != nil || n != 1 || string(packets[0][:sizes[0]]) != "wg-reply" {
		t.Fatalf("bind did not surface inbound datagram: n=%d err=%v got=%q", n, err, packets[0][:sizes[0]])
	}
}

// wireguard-go's BindUpdate always runs Close() then Open() on the same bind (device.go
// closeBindLocked before Open), including on the very first Up. The bind must come back
// alive after that cycle: a receive fn from the reopened bind must still deliver inbound
// datagrams instead of returning net.ErrClosed.
func TestRelayBindSurvivesCloseThenOpen(t *testing.T) {
	inbound := make(chan []byte, 1)
	b := newRelayBind(
		func(ctx context.Context, dg []byte) error { return nil },
		inbound,
	)

	if err := b.Close(); err != nil { // BindUpdate: close existing sockets
		t.Fatal(err)
	}
	fns, _, err := b.Open(0) // BindUpdate: open new sockets
	if err != nil {
		t.Fatal(err)
	}

	inbound <- []byte("wg-reply")
	packets := [][]byte{make([]byte, 1500)}
	sizes := make([]int, 1)
	eps := make([]conn.Endpoint, 1)
	n, err := fns[0](packets, sizes, eps)
	if err != nil || n != 1 || string(packets[0][:sizes[0]]) != "wg-reply" {
		t.Fatalf("reopened bind is dead: n=%d err=%v", n, err)
	}
}

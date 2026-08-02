package transport

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"
)

func TestSSHDialFailsFastWhenDown(t *testing.T) {
	// Construct manually with no live client: DialTCP must fail immediately, not hang.
	s := &SSH{cfg: SSHConfig{
		Addr: "127.0.0.1:1", User: "u",
		Dial: func(ctx context.Context, network, a string) (net.Conn, error) { return net.Dial(network, a) },
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	_, err := s.DialTCP(ctx, netip.MustParseAddrPort("1.1.1.1:80"))
	if err == nil {
		t.Fatal("want fast failure when down, got nil")
	}
	if ctx.Err() != nil {
		t.Fatal("DialTCP hung until ctx deadline instead of failing fast")
	}
}

func TestSSHOnStateFiresOnConnect(t *testing.T) {
	addr, hostPub, signer := startTestSSHD(t)
	states := make(chan bool, 4)
	tr, err := NewSSH(SSHConfig{
		Addr: addr, User: "u", Signer: signer, HostKey: hostPub,
		Dial:    func(ctx context.Context, network, a string) (net.Conn, error) { return net.Dial(network, a) },
		OnState: func(connected bool) { states <- connected },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer tr.Close()
	select {
	case got := <-states:
		if !got {
			t.Fatalf("first OnState: want true, got false")
		}
	case <-time.After(time.Second):
		t.Fatal("OnState(true) not fired on connect")
	}
}

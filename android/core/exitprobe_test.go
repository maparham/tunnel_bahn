package core

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"

	"tunnelbahn/core/transport"
)

func TestParseIPInfo(t *testing.T) {
	body := []byte(`{"ip":"5.6.7.8","city":"Berlin","region":"Berlin","country":"DE"}`)
	ip, city, country, err := parseIPInfo(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if ip != "5.6.7.8" || city != "Berlin" || country != "DE" {
		t.Fatalf("got ip=%q city=%q country=%q", ip, city, country)
	}
}

// blockingTransport never returns from DialTCP until ctx is done, so the test can
// assert runExitProbe respects cancellation instead of hanging.
type blockingTransport struct{}

func (blockingTransport) DialTCP(ctx context.Context, _ netip.AddrPort) (net.Conn, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}
func (blockingTransport) DialUDP(context.Context, netip.AddrPort) (net.PacketConn, error) {
	return nil, transport.ErrUnsupportedProtocol
}
func (blockingTransport) Close() error { return nil }

func TestRunExitProbeHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runExitProbe(ctx, blockingTransport{}, nil) // nil sink: cancellation path emits nothing
		close(done)
	}()
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("runExitProbe did not return after context cancel")
	}
}

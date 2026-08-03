package transport

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"

	"tunnelbahn/core/wstunnel"
)

func randKeyB64(t *testing.T) string {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(b)
}

func newTestWGWS(t *testing.T, relay *wstunnel.Relay) *WGWS {
	t.Helper()
	tr, err := NewWGWS(WGConfig{
		PrivateKey:    randKeyB64(t),
		PeerPublicKey: randKeyB64(t),
		LocalAddrs:    []netip.Addr{netip.MustParseAddr("10.0.0.2")},
		MTU:           1280,
		Relay:         relay,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tr.Close() })
	return tr
}

// This is the reported bug at the unit level: with no internet the carrier dial fails,
// so the WG peer can never handshake. WaitReady must report that failure (not nil),
// and must do so fast via the carrier dial error rather than idling until the ctx
// deadline. WG sends its first handshake initiation synchronously while the device is
// configured, which is what drives the relay to dial in the first place.
func TestWGWSWaitReadyFailsFastWhenCarrierUnreachable(t *testing.T) {
	dialErr := errors.New("network is unreachable")
	relay := wstunnel.NewRelay(wstunnel.Config{
		WSURL: "wss://10.255.255.1:443/x/events", ForwardHost: "127.0.0.1", ForwardPort: 51820,
	}, func(context.Context, string, string) (net.Conn, error) { return nil, dialErr })

	tr := newTestWGWS(t, relay)

	// Deadline is deliberately long: if WaitReady only returned on it, this would take
	// ~5s. A fast return proves it short-circuited on the carrier dial error.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	start := time.Now()
	err := tr.WaitReady(ctx)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("WaitReady returned nil on an unreachable carrier; the UI would show Connected with no internet")
	}
	if elapsed > 2*time.Second {
		t.Fatalf("WaitReady took %v; expected a fast fail via the carrier dial error", elapsed)
	}
}

// A server that is reachable (the carrier dial and WS upgrade succeed) but never
// answers the WG handshake: DialErr stays nil, the handshake never completes, so
// WaitReady must fall back to the ctx deadline instead of blocking forever.
func TestWGWSWaitReadyHonorsContextWhenServerSilent(t *testing.T) {
	addr := silentWSServer(t)
	relay := wstunnel.NewRelay(wstunnel.Config{
		WSURL: "ws://" + addr + "/x/events", ForwardHost: "127.0.0.1", ForwardPort: 51820,
	}, func(ctx context.Context, network, a string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, a)
	})

	tr := newTestWGWS(t, relay)

	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	start := time.Now()
	err := tr.WaitReady(ctx)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("WaitReady returned nil though the server never completed a WG handshake")
	}
	if elapsed > 2*time.Second {
		t.Fatalf("WaitReady took %v; expected it to return near the ctx deadline", elapsed)
	}
}

// silentWSServer completes the WebSocket upgrade handshake, then reads and discards
// everything without ever replying. It is enough for the relay to connect and for WG
// to send handshake initiations that go unanswered.
func silentWSServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				br := bufio.NewReader(c)
				for {
					line, err := br.ReadString('\n')
					if err != nil {
						return
					}
					if line == "\r\n" {
						break
					}
				}
				io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
				io.Copy(io.Discard, c) // stay connected, never answer
			}()
		}
	}()
	return ln.Addr().String()
}

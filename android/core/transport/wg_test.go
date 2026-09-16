package transport

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strings"
	"sync"
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

// ageSource is a swappable handshake-age reading for the watchdog tests.
type ageSource struct {
	mu  sync.Mutex
	age time.Duration
	ok  bool
}

func (a *ageSource) set(age time.Duration, ok bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.age, a.ok = age, ok
}

func (a *ageSource) get() (time.Duration, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.age, a.ok
}

func expectState(t *testing.T, states <-chan bool, want bool) {
	t.Helper()
	select {
	case got := <-states:
		if got != want {
			t.Fatalf("onState: want %v, got %v", want, got)
		}
	case <-time.After(time.Second):
		t.Fatalf("onState(%v) not fired", want)
	}
}

func expectNoState(t *testing.T, states <-chan bool, within time.Duration) {
	t.Helper()
	select {
	case got := <-states:
		t.Fatalf("unexpected onState(%v)", got)
	case <-time.After(within):
	}
}

func TestWatchdogReportsStaleThenRecovered(t *testing.T) {
	src := &ageSource{}
	states := make(chan bool, 8)
	stop := make(chan struct{})
	defer close(stop)
	go runWatchdog(stop, 5*time.Millisecond, 50*time.Millisecond, src.get, func(up bool) { states <- up })

	// Before the first handshake the watchdog stays silent: WaitReady owns that phase.
	expectNoState(t, states, 60*time.Millisecond)

	// A fresh handshake while already up is not news.
	src.set(10*time.Millisecond, true)
	expectNoState(t, states, 60*time.Millisecond)

	// Handshakes stop: degraded, reported once.
	src.set(100*time.Millisecond, true)
	expectState(t, states, false)
	expectNoState(t, states, 60*time.Millisecond)

	// A handshake lands again: running, reported once.
	src.set(0, true)
	expectState(t, states, true)
	expectNoState(t, states, 60*time.Millisecond)
}

func TestWatchdogStopsOnClose(t *testing.T) {
	src := &ageSource{}
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		runWatchdog(stop, time.Millisecond, time.Second, src.get, nil)
		close(done)
	}()
	close(stop)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("watchdog did not exit after stop")
	}
}

func TestNewWGFailsWhenDialFails(t *testing.T) {
	dialErr := errors.New("network is unreachable")
	dial := func(context.Context, string, string) (net.Conn, error) { return nil, dialErr }
	_, err := NewWG(context.Background(), WGConfig{
		PrivateKey: randKeyB64(t), PeerPublicKey: randKeyB64(t),
		LocalAddrs: []netip.Addr{netip.MustParseAddr("10.0.0.2")},
	}, "example.invalid:51820", dial, nil)
	if !errors.Is(err, dialErr) {
		t.Fatalf("want dial error at construction, got %v", err)
	}
}

// The uapi endpoint must be the resolved address of the connected socket, and the
// keepalive must be the configured one. Both are readable back through IpcGet.
func TestNewWGConfiguresResolvedEndpointAndKeepalive(t *testing.T) {
	addr := startUDPEcho(t)
	dial := func(ctx context.Context, network, a string) (net.Conn, error) { return net.Dial(network, a) }
	w, err := NewWG(context.Background(), WGConfig{
		PrivateKey: randKeyB64(t), PeerPublicKey: randKeyB64(t),
		LocalAddrs: []netip.Addr{netip.MustParseAddr("10.0.0.2")}, Keepalive: 15,
	}, addr, dial, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	uapi, err := w.dev.IpcGet()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(uapi, "endpoint="+addr+"\n") {
		t.Fatalf("uapi endpoint not the resolved socket address:\n%s", uapi)
	}
	if !strings.Contains(uapi, "persistent_keepalive_interval=15\n") {
		t.Fatalf("uapi keepalive not applied:\n%s", uapi)
	}
}

// With a server that never answers, WaitReady must return the ctx error at the
// deadline (there is no carrier dial error to short-circuit on), and Close must be
// clean afterwards.
func TestWGWaitReadyTimesOutOnSilentServer(t *testing.T) {
	addr := startUDPEcho(t) // echoes garbage back; WG will discard it, never handshake
	dial := func(ctx context.Context, network, a string) (net.Conn, error) { return net.Dial(network, a) }
	w, err := NewWG(context.Background(), WGConfig{
		PrivateKey: randKeyB64(t), PeerPublicKey: randKeyB64(t),
		LocalAddrs: []netip.Addr{netip.MustParseAddr("10.0.0.2")},
	}, addr, dial, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	if err := w.WaitReady(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("want deadline exceeded, got %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}

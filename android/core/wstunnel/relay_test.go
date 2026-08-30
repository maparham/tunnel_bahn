package wstunnel

import (
	"bufio"
	"context"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func TestEncodeFrameIsUnmasked(t *testing.T) {
	f := encodeFrame(opBinary, []byte("hi"))
	if f[0] != 0x82 {
		t.Fatalf("byte0: want 0x82 (FIN+binary), got 0x%02x", f[0])
	}
	if f[1]&0x80 != 0 {
		t.Fatalf("mask bit must be 0, got 0x%02x", f[1])
	}
	if int(f[1]&0x7f) != 2 {
		t.Fatalf("len: want 2, got %d", f[1]&0x7f)
	}
	if string(f[2:]) != "hi" {
		t.Fatalf("payload: %q", f[2:])
	}
}

func TestDecodeFrameExtendedLengthRoundTrip(t *testing.T) {
	payload := make([]byte, 300) // 300 > 125 forces the 16-bit extended length path
	for i := range payload {
		payload[i] = byte(i)
	}
	enc := encodeFrame(opBinary, payload)
	op, got, consumed, ok, err := decodeFrame(enc)
	if err != nil || !ok || op != opBinary || consumed != len(enc) || string(got) != string(payload) {
		t.Fatalf("roundtrip failed: err=%v ok=%v op=%d consumed=%d len=%d", err, ok, op, consumed, len(got))
	}
}

// fakeWSTunnel is a minimal stand-in for the wstunnel server: it completes the manual
// HTTP upgrade, then echoes every binary frame back UNMASKED. A compliant WS library
// would reject the client's unmasked frames; this fake accepts them, which is exactly
// the behavior the real server exhibits (websocket_mask_frame=false).
func fakeWSTunnel(t *testing.T) (addr string, stop func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go serveFakeWS(c)
		}
	}()
	return ln.Addr().String(), func() { ln.Close() }
}

func serveFakeWS(c net.Conn) {
	defer c.Close()
	br := bufio.NewReader(c)
	for { // consume request headers up to the blank line
		line, err := br.ReadString('\n')
		if err != nil {
			return
		}
		if line == "\r\n" {
			break
		}
	}
	io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

	var buf []byte
	tmp := make([]byte, 4096)
	for {
		for {
			op, payload, consumed, ok, err := decodeFrame(buf)
			if err != nil {
				return
			}
			if !ok {
				break
			}
			buf = buf[consumed:]
			switch op {
			case opBinary:
				c.Write(encodeFrame(opBinary, payload))
			case opPing:
				c.Write(encodeFrame(opPong, payload)) // the real server auto-pongs
			}
		}
		n, err := br.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			return
		}
	}
}

func TestRelayLazyDialAndEcho(t *testing.T) {
	addr, stop := fakeWSTunnel(t)
	defer stop()

	wsURL := "ws://" + addr + "/secretpath/events"
	r := NewRelay(Config{WSURL: wsURL, ForwardHost: "127.0.0.1", ForwardPort: 51840},
		func(ctx context.Context, network, a string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, a)
		})
	defer r.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := r.Send(ctx, []byte("hello")); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-r.Recv():
		if string(got) != "hello" {
			t.Fatalf("echo mismatch: %q", got)
		}
	case <-ctx.Done():
		t.Fatal("timeout waiting for echo")
	}
}

// upgradeFakeWS drains the client's HTTP upgrade request and writes the 101 response.
func upgradeFakeWS(c net.Conn) *bufio.Reader {
	br := bufio.NewReader(c)
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return nil
		}
		if line == "\r\n" {
			break
		}
	}
	io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
	return br
}

// serveFakeWSDropAfterOne completes the upgrade, echoes exactly one binary frame, then
// hangs up, simulating a carrier that drops after being briefly usable.
func serveFakeWSDropAfterOne(c net.Conn) {
	defer c.Close()
	br := upgradeFakeWS(c)
	if br == nil {
		return
	}
	var buf []byte
	tmp := make([]byte, 4096)
	for {
		for {
			op, payload, consumed, ok, err := decodeFrame(buf)
			if err != nil || !ok {
				break
			}
			buf = buf[consumed:]
			if op == opBinary {
				c.Write(encodeFrame(opBinary, payload))
				return // drop the carrier right after one echo
			}
		}
		n, err := br.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			return
		}
	}
}

// TestRelayReconnectsAfterCarrierDrop proves the relay transparently re-dials when the
// underlying carrier drops, instead of permanently killing the tunnel.
func TestRelayReconnectsAfterCarrierDrop(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	var accepted int32
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			// First carrier drops after one echo; the reconnect lands on a stable one.
			if atomic.AddInt32(&accepted, 1) == 1 {
				go serveFakeWSDropAfterOne(c)
			} else {
				go serveFakeWS(c)
			}
		}
	}()

	wsURL := "ws://" + ln.Addr().String() + "/p/events"
	r := NewRelay(Config{WSURL: wsURL, ForwardHost: "127.0.0.1", ForwardPort: 51840},
		func(ctx context.Context, network, a string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, a)
		})
	defer r.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := r.Send(ctx, []byte("one")); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-r.Recv():
		if string(got) != "one" {
			t.Fatalf("first echo: %q", got)
		}
	case <-ctx.Done():
		t.Fatal("timeout waiting for first echo")
	}

	// The server has now dropped carrier 1. Keep sending: sends during the reconnect
	// window error and are dropped (WG would retransmit), but once the relay re-dials to
	// carrier 2 a send lands and echoes back. Fail if that never happens.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		_ = r.Send(context.Background(), []byte("two"))
		select {
		case got := <-r.Recv():
			if string(got) == "two" {
				return // reconnected and carried traffic again
			}
		case <-time.After(200 * time.Millisecond):
		}
	}
	t.Fatal("relay did not recover after carrier drop")
}

// serveFakeWSSilentAfterOne completes the upgrade, echoes exactly one binary frame, then
// goes silent: it keeps the TCP connection open and drains everything the client sends
// without ever replying, including to pings.
//
// This is the shape of the interference measured on the Iranian mobile network against
// the AWS endpoint: the carrier is not reset, it is blackholed. A reader with no deadline
// blocks on it forever, so the relay never learns the tunnel is dead.
func serveFakeWSSilentAfterOne(c net.Conn) {
	defer c.Close()
	br := upgradeFakeWS(c)
	if br == nil {
		return
	}
	var buf []byte
	tmp := make([]byte, 4096)
	for {
		for {
			op, payload, consumed, ok, err := decodeFrame(buf)
			if err != nil || !ok {
				break
			}
			buf = buf[consumed:]
			if op == opBinary {
				c.Write(encodeFrame(opBinary, payload))
				io.Copy(io.Discard, c) // go silent, but hold the connection open
				return
			}
		}
		n, err := br.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			return
		}
	}
}

// TestRelayRecoversFromSilentlyBlackholedCarrier is the reported bug at the unit level.
// A carrier that stops carrying without closing is indistinguishable from an idle one
// unless the relay probes it, so the relay must ping and treat a silent peer as dead.
// Without that, the tunnel stays wedged forever while the UI still says Connected.
func TestRelayRecoversFromSilentlyBlackholedCarrier(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	var accepted int32
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			// The first carrier goes silent after one echo; the re-dial must land on a
			// working one and resume carrying traffic.
			if atomic.AddInt32(&accepted, 1) == 1 {
				go serveFakeWSSilentAfterOne(c)
			} else {
				go serveFakeWS(c)
			}
		}
	}()

	wsURL := "ws://" + ln.Addr().String() + "/p/events"
	r := NewRelay(Config{
		WSURL: wsURL, ForwardHost: "127.0.0.1", ForwardPort: 51840,
		KeepAlive: 100 * time.Millisecond, // scaled down; production uses seconds
	}, func(ctx context.Context, network, a string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, a)
	})
	defer r.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := r.Send(ctx, []byte("one")); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-r.Recv():
		if string(got) != "one" {
			t.Fatalf("first echo: %q", got)
		}
	case <-ctx.Done():
		t.Fatal("timeout waiting for first echo")
	}

	// The carrier is now blackholed. Keep sending: sends during the reconnect window are
	// dropped (WG retransmits), but once the relay notices the silence and re-dials, a
	// send must land and echo back.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		_ = r.Send(context.Background(), []byte("two"))
		select {
		case got := <-r.Recv():
			if string(got) == "two" {
				return // detected the dead carrier and recovered
			}
		case <-time.After(100 * time.Millisecond):
		}
	}
	t.Fatal("relay never detected the blackholed carrier; the tunnel would stay wedged")
}

// TestRelayReportsCarrierStateChanges pins the other half of the bug: detection is not
// enough if the app keeps claiming Connected. The relay must report the drop and the
// recovery so the UI can show "Reconnecting", the way the SSH transport already does.
func TestRelayReportsCarrierStateChanges(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	var accepted int32
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			if atomic.AddInt32(&accepted, 1) == 1 {
				go serveFakeWSSilentAfterOne(c)
			} else {
				go serveFakeWS(c)
			}
		}
	}()

	states := make(chan bool, 8)
	wsURL := "ws://" + ln.Addr().String() + "/p/events"
	r := NewRelay(Config{
		WSURL: wsURL, ForwardHost: "127.0.0.1", ForwardPort: 51840,
		KeepAlive: 100 * time.Millisecond,
		OnState:   func(up bool) { states <- up },
	}, func(ctx context.Context, network, a string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, a)
	})
	defer r.Close()

	if err := r.Send(context.Background(), []byte("one")); err != nil {
		t.Fatal(err)
	}
	// Drive sends so the relay keeps working through the drop and the re-dial.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			select {
			case <-stop:
				return
			case <-time.After(50 * time.Millisecond):
				_ = r.Send(context.Background(), []byte("x"))
			}
		}
	}()
	go func() {
		for range r.Recv() { //nolint:revive // drain so the inbox never backs up
		}
	}()

	if up := waitState(t, states); up {
		t.Fatal("expected the blackholed carrier to be reported down first")
	}
	if up := waitState(t, states); !up {
		t.Fatal("expected the re-dialed carrier to be reported up")
	}
}

func waitState(t *testing.T, states chan bool) bool {
	t.Helper()
	select {
	case s := <-states:
		return s
	case <-time.After(10 * time.Second):
		t.Fatal("timeout waiting for a carrier state report")
		return false
	}
}

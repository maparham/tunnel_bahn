package transport

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func testSigner(t *testing.T) ssh.Signer {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	return signer
}

// silentListener accepts TCP connections and then says nothing at all — never sending
// the SSH version banner. This is what a filtered or blackholed path looks like from
// the client: the connection is established, so the dial succeeds, and the handshake
// then waits on data that never arrives.
func silentListener(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			// Hold the connection open and idle until the test tears the listener down.
			t.Cleanup(func() { c.Close() })
		}
	}()
	return ln
}

// The SSH transport proves it reached the server inside NewSSH (WaitReady is a no-op),
// so if that call is unbounded a silent server wedges the whole connect attempt and the
// UI spins on "Connecting" forever. The handshake must respect the context deadline.
func TestSSHConnectHonoursContextDeadline(t *testing.T) {
	ln := silentListener(t)
	signer := testSigner(t)

	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()

	start := time.Now()
	done := make(chan error, 1)
	go func() {
		_, err := NewSSHContext(ctx, SSHConfig{
			Addr:   ln.Addr().String(),
			User:   "u",
			Signer: signer,
			Dial:   DialFunc((&net.Dialer{}).DialContext),
		})
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("connect to a silent server succeeded; want a timeout error")
		}
		if elapsed := time.Since(start); elapsed > 5*time.Second {
			t.Errorf("connect took %v; the deadline did not bound the handshake", elapsed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("connect never returned: the handshake is unbounded")
	}
}

// A user tapping cancel must actually stop the attempt, not wait out the full budget.
func TestSSHConnectIsCancellable(t *testing.T) {
	ln := silentListener(t)
	signer := testSigner(t)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := NewSSHContext(ctx, SSHConfig{
			Addr:   ln.Addr().String(),
			User:   "u",
			Signer: signer,
			Dial:   DialFunc((&net.Dialer{}).DialContext),
		})
		done <- err
	}()

	// Let the handshake get under way, then cancel it the way Stop does.
	time.Sleep(100 * time.Millisecond)
	cancel()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled connect returned success")
		}
		if !errors.Is(err, context.Canceled) {
			// The socket close can surface as a read error instead; either way the
			// call must have returned, which is what the UI depends on.
			t.Logf("cancelled connect returned %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancel did not unblock the handshake")
	}
}

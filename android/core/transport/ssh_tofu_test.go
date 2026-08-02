package transport

import (
	"context"
	"crypto/ed25519"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestSSHTOFUReportsHostKey(t *testing.T) {
	_, hostPriv, _ := ed25519.GenerateKey(nil)
	hostSigner, err := ssh.NewSignerFromKey(hostPriv)
	if err != nil {
		t.Fatal(err)
	}
	wantLine := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(hostSigner.PublicKey())))

	// Client key (server accepts any).
	_, cliPriv, _ := ed25519.GenerateKey(nil)
	cliSigner, _ := ssh.NewSignerFromKey(cliPriv)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	go func() {
		nc, err := ln.Accept()
		if err != nil {
			return
		}
		cfg := &ssh.ServerConfig{PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) { return nil, nil }}
		cfg.AddHostKey(hostSigner)
		conn, chans, reqs, err := ssh.NewServerConn(nc, cfg)
		if err != nil {
			return
		}
		go ssh.DiscardRequests(reqs)
		for ch := range chans {
			ch.Reject(ssh.Prohibited, "no channels in test")
		}
		_ = conn
	}()

	var mu sync.Mutex
	var got string
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		return net.Dial(network, addr)
	}
	s, err := NewSSH(SSHConfig{
		Addr:    ln.Addr().String(),
		User:    "tb",
		Signer:  cliSigner,
		HostKey: nil, // TOFU
		Dial:    DialFunc(dial),
		OnHostKey: func(line string) {
			mu.Lock()
			got = line
			mu.Unlock()
		},
	})
	if err != nil {
		t.Fatalf("NewSSH: %v", err)
	}
	defer s.Close()

	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if got != wantLine {
		t.Fatalf("OnHostKey line = %q, want %q", got, wantLine)
	}
}

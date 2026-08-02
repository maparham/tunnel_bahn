package transport

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"io"
	"net"
	"net/netip"
	"testing"

	"golang.org/x/crypto/ssh"
)

// startTestSSHD spins up a minimal sshd that allows direct-tcpip to a backing echo server.
func startTestSSHD(t *testing.T) (addr string, hostPub ssh.PublicKey, signer ssh.Signer) {
	t.Helper()
	echoLn, _ := net.Listen("tcp", "127.0.0.1:0")
	go func() {
		for {
			c, err := echoLn.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	t.Cleanup(func() { echoLn.Close() })

	_, hostPriv, _ := ed25519.GenerateKey(nil)
	hostSigner, _ := ssh.NewSignerFromKey(hostPriv)
	_, clientPriv, _ := ed25519.GenerateKey(nil)
	clientSigner, _ := ssh.NewSignerFromKey(clientPriv)

	scfg := &ssh.ServerConfig{PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) { return nil, nil }}
	// Offer an ecdsa host key too, so the server has a choice. The client pins the
	// ed25519 key; without HostKeyAlgorithms it could negotiate ecdsa and mismatch.
	ecKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	ecSigner, _ := ssh.NewSignerFromKey(ecKey)
	scfg.AddHostKey(ecSigner)
	scfg.AddHostKey(hostSigner)

	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			nc, err := ln.Accept()
			if err != nil {
				return
			}
			go serveSSHConn(nc, scfg, echoLn.Addr().String())
		}
	}()
	return ln.Addr().String(), hostSigner.PublicKey(), clientSigner
}

func serveSSHConn(nc net.Conn, scfg *ssh.ServerConfig, echoAddr string) {
	_, chans, reqs, err := ssh.NewServerConn(nc, scfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for newCh := range chans {
		if newCh.ChannelType() != "direct-tcpip" {
			newCh.Reject(ssh.UnknownChannelType, "only direct-tcpip")
			continue
		}
		ch, chReqs, _ := newCh.Accept()
		go ssh.DiscardRequests(chReqs)
		backend, _ := net.Dial("tcp", echoAddr)
		go func() { io.Copy(ch, backend); ch.Close() }()
		go func() { io.Copy(backend, ch); backend.Close() }()
	}
}

func TestSSHDialTCPEchoes(t *testing.T) {
	addr, hostPub, signer := startTestSSHD(t)
	host, _, _ := net.SplitHostPort(addr)
	tr, err := NewSSH(SSHConfig{
		Addr: addr, User: "u", Signer: signer, HostKey: hostPub,
		Dial: func(ctx context.Context, network, a string) (net.Conn, error) { return net.Dial(network, a) },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer tr.Close()

	dst := netip.MustParseAddrPort(host + ":9999")
	conn, err := tr.DialTCP(context.Background(), dst)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte("ping"))
	buf := make([]byte, 4)
	io.ReadFull(conn, buf)
	if string(buf) != "ping" {
		t.Fatalf("echo mismatch: %q", buf)
	}

	if _, err := tr.DialUDP(context.Background(), dst); err != ErrUnsupportedProtocol {
		t.Fatalf("DialUDP: want ErrUnsupportedProtocol, got %v", err)
	}
}

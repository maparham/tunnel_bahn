package transport

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

type SSHConfig struct {
	Addr    string
	User    string
	Signer  ssh.Signer
	HostKey ssh.PublicKey
	Dial    DialFunc

	// KeepAlive is the interval between keepalive@openssh.com probes. Defaults to 15s.
	KeepAlive time.Duration
	// OnState reports transport liveness: true on (re)connect, false when the client
	// dies and reconnect begins. The UI surfaces false as a "Degraded" chip.
	OnState func(connected bool)
	// OnHostKey is called once, during the first successful handshake, with the
	// server's presented key as an authorized_keys line, when HostKey is nil (TOFU).
	// The Kotlin layer persists it so the next connect pins it via HostKey.
	OnHostKey func(line string)
}

type SSH struct {
	cfg    SSHConfig
	mu     sync.Mutex
	client *ssh.Client
	closed bool
}

func NewSSH(cfg SSHConfig) (*SSH, error) {
	s := &SSH{cfg: cfg}
	if err := s.connect(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *SSH) connect(ctx context.Context) error {
	nc, err := s.cfg.Dial(ctx, "tcp", s.cfg.Addr)
	if err != nil {
		return err
	}
	s.mu.Lock()
	hostKey := s.cfg.HostKey
	s.mu.Unlock()
	ccfg := &ssh.ClientConfig{
		User: s.cfg.User,
		Auth: []ssh.AuthMethod{ssh.PublicKeys(s.cfg.Signer)},
	}
	if hostKey != nil {
		ccfg.HostKeyCallback = ssh.FixedHostKey(hostKey)
		// Constrain negotiation to the pinned key's type, otherwise the server may
		// present a different host key algorithm (e.g. ecdsa) that will never match
		// the pinned key and the handshake fails with "host key mismatch".
		ccfg.HostKeyAlgorithms = []string{hostKey.Type()}
	} else {
		// TOFU: accept whatever the server presents on this first connect, report it,
		// and pin it for the remainder of this session. Without pinning here, the
		// background reconnect loop would re-run accept-any on every reconnect, so an
		// on-path attacker (this app's threat model) could drop the carrier to force a
		// reconnect and then present a substitute host key that is silently accepted.
		ccfg.HostKeyCallback = func(_ string, _ net.Addr, key ssh.PublicKey) error {
			if s.cfg.OnHostKey != nil {
				s.cfg.OnHostKey(strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key))))
			}
			s.mu.Lock()
			s.cfg.HostKey = key
			s.mu.Unlock()
			return nil
		}
	}
	conn, chans, reqs, err := ssh.NewClientConn(nc, s.cfg.Addr, ccfg)
	if err != nil {
		nc.Close()
		return err
	}
	client := ssh.NewClient(conn, chans, reqs)
	s.mu.Lock()
	if s.closed {
		// Close() ran while this connect was mid-handshake. Don't publish the client
		// or start keepAlive, or we'd leak a live connection and emit a spurious
		// "connected" state after Close returned.
		s.mu.Unlock()
		client.Close()
		return fmt.Errorf("ssh: closed during connect")
	}
	s.client = client
	s.mu.Unlock()
	if s.cfg.OnState != nil {
		s.cfg.OnState(true)
	}
	go s.keepAlive(client)
	return nil
}

func (s *SSH) keepAlive(c *ssh.Client) {
	interval := s.cfg.KeepAlive
	if interval <= 0 {
		interval = 15 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for range t.C {
		if _, _, err := c.SendRequest("keepalive@openssh.com", true, nil); err != nil {
			s.markDead(c)
			return
		}
	}
}

func (s *SSH) markDead(dead *ssh.Client) {
	s.mu.Lock()
	if s.client == dead {
		s.client = nil
	}
	closed := s.closed
	s.mu.Unlock()
	if s.cfg.OnState != nil {
		s.cfg.OnState(false)
	}
	if closed {
		return
	}
	go s.reconnectLoop()
}

func (s *SSH) reconnectLoop() {
	backoff := 100 * time.Millisecond
	for {
		s.mu.Lock()
		closed := s.closed
		s.mu.Unlock()
		if closed {
			return
		}
		if err := s.connect(context.Background()); err == nil {
			return
		}
		time.Sleep(backoff)
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

// WaitReady is a no-op for SSH: NewSSH already blocked on a synchronous dial and
// handshake, so a constructed *SSH is connected. Later drops are handled by the
// background reconnect loop and surfaced via OnState, not gated here.
func (s *SSH) WaitReady(_ context.Context) error { return nil }

func (s *SSH) DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	s.mu.Lock()
	c := s.client
	s.mu.Unlock()
	if c == nil {
		return nil, fmt.Errorf("ssh: not connected")
	}
	return c.DialContext(ctx, "tcp", dst.String())
}

func (s *SSH) DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error) {
	return nil, ErrUnsupportedProtocol
}

func (s *SSH) Close() error {
	s.mu.Lock()
	s.closed = true
	c := s.client
	s.client = nil
	s.mu.Unlock()
	if c != nil {
		return c.Close()
	}
	return nil
}

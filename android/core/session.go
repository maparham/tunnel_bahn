package core

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"syscall"

	"golang.org/x/crypto/ssh"

	"tunnelbahn/core/transport"
	"tunnelbahn/core/wstunnel"
)

// Protector wraps VpnService.protect(fd): it keeps a socket outside the tunnel so
// the carrier and bypass flows do not route back into the tun (no loop).
type Protector interface {
	Protect(fd int) error
}

// EventSink reports connection lifecycle to the Android layer. These methods are
// the gomobile-exported surface, so they take only strings.
type EventSink interface {
	OnState(state string)
	OnError(msg string)
	OnHostKey(line string)
	OnExitInfo(ip, city, country string)
}

type Session struct {
	mu     sync.Mutex
	tr     transport.Transport
	eng    *engine
	stopCh chan struct{}
	ctr    *counters
}

func NewSession() *Session { return &Session{} }

// Start builds the transport, wires the routing/DNS proxy, opens the netstack engine
// on tunFD, and blocks until Stop. It is meant to run on a dedicated thread.
func (s *Session) Start(tunFD int, configJSON string, prot Protector, sink EventSink) error {
	// The tun fd is owned by Go once passed in. Close it on every path that does not
	// hand it to a running engine, so a failed connect never blackholes the tun.
	started := false
	defer func() {
		if !started {
			syscall.Close(tunFD)
		}
	}()

	cfg, err := parseConfig(configJSON)
	if err != nil {
		return err
	}

	tr, err := buildTransport(cfg, prot, sink)
	if err != nil {
		return err
	}

	ctr := &counters{}

	router := NewRouter(cfg.Mode, cfg.activeRuleSet())
	proxy := newCoreProxy(newDispatcher(router, cfg.Resolver.Addr()), tr, cfg.Resolver, prot, ctr)

	// The tun MTU (set by VpnService) and the engine MTU must match to avoid MSS
	// clamping mismatches; both derive from the profile's mtu.
	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = 1280
	}
	eng, err := startEngine(tunFD, mtu, proxy)
	if err != nil {
		tr.Close()
		return err
	}
	started = true // the engine now owns the fd and closes it on Stop

	s.mu.Lock()
	s.tr = tr
	s.eng = eng
	s.ctr = ctr
	s.stopCh = make(chan struct{})
	stopCh := s.stopCh
	s.mu.Unlock()

	// Tie a cancellable context to stopCh so Stop cancels an in-flight exit probe.
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-stopCh
		cancel()
	}()

	if sink != nil {
		sink.OnState("running")
	}
	go runExitProbe(ctx, tr, sink)

	<-stopCh
	cancel()

	eng.stop()
	tr.Close()
	if sink != nil {
		sink.OnState("disconnected")
	}
	return nil
}

// RxBytes and TxBytes report cumulative tunneled inner-payload bytes for this session.
// They are 0 before Start and after a fresh Session is created. Safe to call concurrently.
func (s *Session) RxBytes() int64 {
	s.mu.Lock()
	c := s.ctr
	s.mu.Unlock()
	if c == nil {
		return 0
	}
	return c.Rx()
}

func (s *Session) TxBytes() int64 {
	s.mu.Lock()
	c := s.ctr
	s.mu.Unlock()
	if c == nil {
		return 0
	}
	return c.Tx()
}

func (s *Session) Stop() {
	s.mu.Lock()
	ch := s.stopCh
	s.stopCh = nil
	s.mu.Unlock()
	if ch != nil {
		close(ch)
	}
}

// buildTransport constructs the SSH or WG-over-wstunnel transport from config. The
// carrier socket is protected so it egresses directly instead of looping into the tun.
func buildTransport(cfg *coreConfig, prot Protector, sink EventSink) (transport.Transport, error) {
	dial := protectedDialFunc(prot)

	switch cfg.Transport {
	case "ssh":
		signer, err := ssh.ParsePrivateKey([]byte(cfg.SSH.PrivateKeyPEM))
		if err != nil {
			return nil, fmt.Errorf("ssh private key: %w", err)
		}
		var hostKey ssh.PublicKey
		if strings.TrimSpace(cfg.SSH.HostKeyAuthorized) != "" {
			hostKey, _, _, _, err = ssh.ParseAuthorizedKey([]byte(cfg.SSH.HostKeyAuthorized))
			if err != nil {
				return nil, fmt.Errorf("ssh host key: %w", err)
			}
		}
		return transport.NewSSH(transport.SSHConfig{
			Addr:    cfg.SSH.Addr,
			User:    cfg.SSH.User,
			Signer:  signer,
			HostKey: hostKey, // nil => trust-on-first-use
			Dial:    transport.DialFunc(dial),
			OnHostKey: func(line string) {
				if sink != nil {
					sink.OnHostKey(line)
				}
			},
			OnState: func(connected bool) {
				if sink == nil {
					return
				}
				if connected {
					sink.OnState("running")
				} else {
					sink.OnState("degraded")
				}
			},
		})

	case "wgws":
		locals, err := parseAddrs(cfg.WG.LocalAddrs)
		if err != nil {
			return nil, fmt.Errorf("wg localAddrs: %w", err)
		}
		dns, err := parseAddrs(cfg.WG.DNS)
		if err != nil {
			return nil, fmt.Errorf("wg dns: %w", err)
		}
		relay := wstunnel.NewRelay(wstunnel.Config{
			WSURL:       cfg.WG.WSURL,
			ForwardHost: cfg.WG.ForwardHost,
			ForwardPort: cfg.WG.ForwardPort,
			// The wstunnel TLS is obfuscation cover, not the security boundary: WireGuard's
			// Noise handshake (peer key + PSK) protects the payload regardless. Reference
			// servers use bare-IP certs with no SANs, so verifying would break every connect
			// for no security gain. This matches wstunnel's own default and the macOS side.
			TLSConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // see comment
		}, wstunnel.DialFunc(dial))
		return transport.NewWGWS(transport.WGConfig{
			PrivateKey:       cfg.WG.PrivateKey,
			PeerPublicKey:    cfg.WG.PeerPublicKey,
			PeerPresharedKey: cfg.WG.PeerPresharedKey,
			LocalAddrs:       locals,
			DNS:              dns,
			MTU:              cfg.WG.MTU,
			Relay:            relay,
		})

	default:
		return nil, fmt.Errorf("unknown transport %q", cfg.Transport)
	}
}

// protectedDialFunc returns a dialer whose sockets are kept outside the tunnel.
func protectedDialFunc(prot Protector) func(ctx context.Context, network, addr string) (net.Conn, error) {
	d := &net.Dialer{Control: func(_, _ string, rc syscall.RawConn) error {
		if prot == nil {
			return nil
		}
		var perr error
		if err := rc.Control(func(fd uintptr) { perr = prot.Protect(int(fd)) }); err != nil {
			return err
		}
		return perr
	}}
	return d.DialContext
}

func parseAddrs(ss []string) ([]netip.Addr, error) {
	out := make([]netip.Addr, 0, len(ss))
	for _, s := range ss {
		a, err := netip.ParseAddr(s)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, nil
}

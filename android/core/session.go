package core

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/netip"
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
}

type Session struct {
	mu     sync.Mutex
	tr     transport.Transport
	eng    *engine
	stopCh chan struct{}
}

func NewSession() *Session { return &Session{} }

// Start builds the transport, wires the routing/DNS proxy, opens the netstack engine
// on tunFD, and blocks until Stop. It is meant to run on a dedicated thread.
func (s *Session) Start(tunFD int, configJSON string, prot Protector, sink EventSink) error {
	cfg, err := parseConfig(configJSON)
	if err != nil {
		return err
	}

	tr, err := buildTransport(cfg, prot, sink)
	if err != nil {
		return err
	}

	router := NewRouter(cfg.Mode, cfg.activeRuleSet())
	proxy := newCoreProxy(newDispatcher(router), tr, cfg.Resolver, prot)

	mtu := cfg.WG.MTU
	if mtu <= 0 {
		mtu = 1500
	}
	eng, err := startEngine(tunFD, mtu, proxy)
	if err != nil {
		tr.Close()
		return err
	}

	s.mu.Lock()
	s.tr = tr
	s.eng = eng
	s.stopCh = make(chan struct{})
	stopCh := s.stopCh
	s.mu.Unlock()

	if sink != nil {
		sink.OnState("running")
	}

	<-stopCh

	eng.stop()
	tr.Close()
	if sink != nil {
		sink.OnState("disconnected")
	}
	return nil
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
		hostKey, _, _, _, err := ssh.ParseAuthorizedKey([]byte(cfg.SSH.HostKeyAuthorized))
		if err != nil {
			return nil, fmt.Errorf("ssh host key: %w", err)
		}
		return transport.NewSSH(transport.SSHConfig{
			Addr:    cfg.SSH.Addr,
			User:    cfg.SSH.User,
			Signer:  signer,
			HostKey: hostKey,
			Dial:    transport.DialFunc(dial),
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
			TLSConfig:   &tls.Config{},
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

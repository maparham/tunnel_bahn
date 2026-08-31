package core

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/crypto/ssh"

	"tunnelbahn/core/transport"
	"tunnelbahn/core/wstunnel"
)

// connectTimeout bounds how long Start waits for the transport to reach the server
// before reporting a failed connect. WG on a good network handshakes in well under a
// second; on a dead network the carrier dial error short-circuits the wait, so this
// only bites a reachable-but-silent server.
const connectTimeout = 15 * time.Second

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

// errStopped is returned by Start when Stop was already requested. Stop latches, so a
// cancel that races ahead of Start cannot be lost.
var errStopped = errors.New("session stopped before it started")

type Session struct {
	mu     sync.Mutex
	tr     transport.Transport
	eng    *engine
	stopCh chan struct{}
	ctr    *counters

	// stopRequested latches Stop. Without it a Stop arriving before Start published
	// stopCh was dropped on the floor, and Start would then run to completion — or
	// block forever — with nothing left to cancel it.
	stopRequested bool
	// stopClosed guards stopCh against a double close when both Stop and the Start
	// teardown reach it.
	stopClosed bool

	stMu     sync.Mutex
	stCancel context.CancelFunc
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
		Logf("connect: bad config: %v", err)
		return err
	}
	Logf("connect: start transport=%s mode=%v mtu=%d", cfg.Transport, cfg.Mode, cfg.MTU)

	// Publish the stop channel BEFORE building the transport. Transport construction
	// performs network I/O (the SSH handshake happens inside NewSSH), and until stopCh
	// exists Stop() has nothing to close, so a cancel arriving during construction was
	// silently dropped and the UI span "Connecting" with no way out.
	ctx, cancel := context.WithCancel(context.Background())
	stopCh, err := s.publishStop()
	if err != nil {
		Logf("connect: aborted before start (stop already requested)")
		cancel()
		return err
	}
	go func() {
		<-stopCh
		cancel()
	}()
	// From here on every failure path must retire stopCh so a later Start can publish
	// a fresh one and the watcher goroutine above exits.
	fail := func(err error) error {
		Logf("connect: failed: %v", err)
		cancel()
		s.retireStop()
		return err
	}

	// Bound transport construction by the same budget as the readiness gate, and make
	// it cancellable, so a server that accepts TCP but never completes a handshake
	// cannot wedge the connect forever.
	buildCtx, buildCancel := context.WithTimeout(ctx, connectTimeout)
	tr, err := buildTransport(buildCtx, cfg, prot, sink)
	buildCancel()
	if err != nil {
		return fail(fmt.Errorf("build transport: %w", err))
	}
	Logf("connect: transport built, waiting for server")

	ctr := &counters{}

	router := NewRouter(cfg.Mode, cfg.activeRuleSet())
	proxy := newCoreProxy(newDispatcher(router, cfg.Resolver.Addr()), tr, cfg.Resolver, prot, ctr)

	// Gate on the transport actually reaching the server before committing the tun to
	// an engine and announcing "running". WG builds and brings its device up with zero
	// network I/O, so without this the UI would show Connected on a dead network. The
	// tun fd is still owned by the deferred close on this failure path (started==false).
	readyCtx, readyCancel := context.WithTimeout(ctx, connectTimeout)
	err = tr.WaitReady(readyCtx)
	readyCancel()
	if err != nil {
		tr.Close()
		return fail(fmt.Errorf("server not reachable: %w", err))
	}
	Logf("connect: server reached")

	// The tun MTU (set by VpnService) and the engine MTU must match to avoid MSS
	// clamping mismatches; both derive from the profile's mtu.
	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = 1280
	}
	eng, err := startEngine(tunFD, mtu, proxy)
	if err != nil {
		tr.Close()
		return fail(fmt.Errorf("start engine: %w", err))
	}
	started = true // the engine now owns the fd and closes it on Stop

	s.mu.Lock()
	s.tr = tr
	s.eng = eng
	s.ctr = ctr
	s.mu.Unlock()

	Logf("connect: running (mtu=%d)", mtu)
	if sink != nil {
		sink.OnState("running")
	}
	go runExitProbe(ctx, tr, sink)

	<-stopCh
	cancel()
	s.retireStop()
	Logf("disconnect: tearing down")

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
	Logf("disconnect: stop requested")
	s.mu.Lock()
	s.stopRequested = true
	ch := s.stopCh
	closed := s.stopClosed
	s.stopClosed = true
	s.mu.Unlock()
	if ch != nil && !closed {
		close(ch)
	}
}

// publishStop installs a fresh stop channel for a starting session, or reports
// errStopped if Stop already ran. Callers must pair it with retireStop.
func (s *Session) publishStop() (chan struct{}, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopRequested {
		return nil, errStopped
	}
	ch := make(chan struct{})
	s.stopCh = ch
	s.stopClosed = false
	return ch, nil
}

// retireStop closes the published stop channel if nobody has yet (unblocking the
// watcher goroutine that cancels the session context) and clears it.
func (s *Session) retireStop() {
	s.mu.Lock()
	ch := s.stopCh
	closed := s.stopClosed
	s.stopCh = nil
	s.stopClosed = true
	s.mu.Unlock()
	if ch != nil && !closed {
		close(ch)
	}
}

// RunTunnelSpeedTest runs the speed test over the live transport. Blocking; call off-thread.
// The run's context is tied to the session's stopCh, so a tunnel drop (Stop/endSession)
// cancels the run promptly. This is load-bearing: the Kotlin coroutine is parked in this
// blocking JNI call and cannot self-interrupt, so cancellation MUST come from the Go side.
func (s *Session) RunTunnelSpeedTest(sink SpeedTestSink) error {
	s.mu.Lock()
	tr := s.tr
	stopCh := s.stopCh
	s.mu.Unlock()
	if tr == nil {
		err := fmt.Errorf("tunnel not running")
		sink.OnError(err.Error())
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.stMu.Lock()
	s.stCancel = cancel
	s.stMu.Unlock()
	defer func() {
		s.stMu.Lock()
		s.stCancel = nil
		s.stMu.Unlock()
		cancel()
	}()
	// Cancel the run when the session stops (drop) or when it finishes normally.
	if stopCh != nil {
		go func() {
			select {
			case <-stopCh:
				cancel()
			case <-ctx.Done():
			}
		}()
	}
	return runSpeedTest(ctx, tunnelDialTLS(tr), sink)
}

// CancelSpeedTest cancels an in-flight tunnel speed test, if any.
func (s *Session) CancelSpeedTest() {
	s.stMu.Lock()
	c := s.stCancel
	s.stMu.Unlock()
	if c != nil {
		c()
	}
}

// buildTransport constructs the SSH or WG-over-wstunnel transport from config. The
// carrier socket is protected so it egresses directly instead of looping into the tun.
//
// ctx bounds and cancels any network I/O construction performs. That matters for SSH,
// which completes its whole handshake here (its WaitReady is a no-op), so without a
// deadline a server that accepts TCP and then goes silent would block Start forever.
func buildTransport(ctx context.Context, cfg *coreConfig, prot Protector, sink EventSink) (transport.Transport, error) {
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
		Logf("connect: ssh dial %s user=%s", cfg.SSH.Addr, cfg.SSH.User)
		return transport.NewSSHContext(ctx, transport.SSHConfig{
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
				logCarrier("ssh", connected)
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
		Logf("connect: wgws carrier %s -> %s:%d", cfg.WG.WSURL, cfg.WG.ForwardHost, cfg.WG.ForwardPort)
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
			// Surface carrier drops the way the SSH transport does. Networks that
			// blackhole a long-lived connection (rather than resetting it) leave the
			// tunnel carrying nothing; without this the UI would keep showing Connected
			// for the whole outage instead of "Reconnecting".
			OnState: func(connected bool) {
				logCarrier("wgws", connected)
				if sink == nil {
					return
				}
				if connected {
					sink.OnState("running")
				} else {
					sink.OnState("degraded")
				}
			},
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

// logCarrier records carrier liveness flips, which is the signal that distinguishes a
// server that is down from a network that silently drops long-lived connections.
func logCarrier(kind string, connected bool) {
	if connected {
		Logf("carrier(%s): connected", kind)
	} else {
		Logf("carrier(%s): dropped, reconnecting", kind)
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

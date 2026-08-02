# TunnelBahn for Android Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a sideloadable Android WireGuard/SSH split-tunnel client that connects to the existing TunnelBahn servers, with SSH `direct-tcpip` as the primary (Iran-proven) transport and WG-over-wstunnel as the secondary, sharing a per-app + per-CIDR routing layer.

**Architecture:** A single Go core (`libtunnelbahn.aar`, built with gomobile) owns all packet movement: a gVisor netstack tun2socks engine terminates TCP+UDP flows from the Android tun fd, a `Router` classifies each flow (tunnel vs bypass) against per-mode CIDR sets, a DNS interceptor forwards UDP/53 over TCP/53 through the tunnel, and two `Transport` implementations (SSH, WG+wstunnel) carry tunneled flows. A thin Kotlin/Android layer owns OS integration only: the `VpnService` (tun fd, per-app allow/deny, coarse routes, `protect()` callback), profile storage, and Material 3 UI.

**Tech Stack:** Go 1.22+ (gomobile), `github.com/xjasonlyu/tun2socks/v2` (netstack engine, `fd://` device), `golang.zx2c4.com/wireguard` (`wireguard-go` + `tun/netstack`), `golang.org/x/crypto/ssh`, `nhooyr.io/websocket` (or `github.com/coder/websocket`) for the wstunnel client, `github.com/golang-jwt/jwt/v5`; Kotlin, Android Gradle Plugin, Jetpack Security (`EncryptedSharedPreferences`), Material 3 Compose.

## Global Constraints

- **No server changes.** Client connects to the existing WG+wstunnel (443) and sshd servers using the existing TunnelBahn profile format. Copy the profile schema from the macOS `Shared/` models; do not invent a new one.
- **Sideload/personal distribution.** No Play/F-Droid constraints; native libs bundled freely. No VPN-policy review work.
- **v1 routing is CIDR-only.** No per-destination domain-name rules. (DNS-for-connectivity IS implemented — that is separate.)
- **Raw WG is never on the wire.** The `wireguard-go` peer endpoint is always the local loopback relay.
- **wstunnel frames are sent UNMASKED.** The client must not RFC-6455-mask frames (wstunnel does not unmask).
- **Private keys never in profile JSON.** Stored encrypted at rest under a Keystore-wrapped AES key (`EncryptedSharedPreferences`). Not held in Android Keystore directly.
- **SSH auth is public-key only**, ed25519 / ECDSA (P-256/384/521). No RSA.
- **SSH transport drops UDP** (`ErrUnsupportedProtocol`) except the DNS interceptor path, which uses TCP/53.
- **No-legacy-code policy:** this is a fresh app; no compat shims, no schemaVersion, no migrations.
- **No em dashes in UI strings.** Tooltips one or two short sentences; use questionmark+tooltip idiom, not inline footnotes.

**Repository layout:** new top-level `android/` directory in this repo.
- `android/core/` — Go module (`module tunnelbahn/core`), the gomobile-bound core.
- `android/app/` — Gradle Android application module.

---

## Task 1: Go core scaffold + Router CIDR classification

**Files:**
- Create: `android/core/go.mod`
- Create: `android/core/router.go`
- Test: `android/core/router_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `type Mode int; const ( ModeInclude Mode = iota; ModeExclude )`
  - `type RuleSet struct { CIDRs []netip.Prefix }`
  - `type Router struct { ... }`
  - `func NewRouter(mode Mode, active RuleSet) *Router`
  - `func (r *Router) Decision(dst netip.Addr) Decision` where `type Decision int; const ( Tunnel Decision = iota; Bypass )`

- [ ] **Step 1: Init the Go module**

Run:
```bash
cd android/core && go mod init tunnelbahn/core && go get go4.org/netipx@latest
```
`netipx` gives an efficient `IPSet` for CIDR membership.

- [ ] **Step 2: Write the failing test**

```go
// android/core/router_test.go
package core

import (
	"net/netip"
	"testing"
)

func mustPfx(s string) netip.Prefix { return netip.MustParsePrefix(s) }

func TestRouterIncludeMode(t *testing.T) {
	r := NewRouter(ModeInclude, RuleSet{CIDRs: []netip.Prefix{mustPfx("10.0.0.0/8")}})
	if got := r.Decision(netip.MustParseAddr("10.1.2.3")); got != Tunnel {
		t.Fatalf("in-set include: want Tunnel, got %v", got)
	}
	if got := r.Decision(netip.MustParseAddr("8.8.8.8")); got != Bypass {
		t.Fatalf("out-of-set include: want Bypass, got %v", got)
	}
}

func TestRouterExcludeMode(t *testing.T) {
	r := NewRouter(ModeExclude, RuleSet{CIDRs: []netip.Prefix{mustPfx("10.0.0.0/8")}})
	if got := r.Decision(netip.MustParseAddr("10.1.2.3")); got != Bypass {
		t.Fatalf("in-set exclude: want Bypass, got %v", got)
	}
	if got := r.Decision(netip.MustParseAddr("8.8.8.8")); got != Tunnel {
		t.Fatalf("out-of-set exclude: want Tunnel, got %v", got)
	}
}

func TestRouterBoundaryAndOverlap(t *testing.T) {
	r := NewRouter(ModeInclude, RuleSet{CIDRs: []netip.Prefix{
		mustPfx("192.168.1.0/24"), mustPfx("192.168.0.0/16"),
	}})
	if got := r.Decision(netip.MustParseAddr("192.168.255.255")); got != Tunnel {
		t.Fatalf("overlapping supernet: want Tunnel, got %v", got)
	}
	if got := r.Decision(netip.MustParseAddr("192.169.0.1")); got != Bypass {
		t.Fatalf("just outside: want Bypass, got %v", got)
	}
}
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `cd android/core && go test ./... -run TestRouter -v`
Expected: FAIL (undefined `NewRouter`, etc.).

- [ ] **Step 4: Write the minimal implementation**

```go
// android/core/router.go
package core

import (
	"net/netip"

	"go4.org/netipx"
)

type Mode int

const (
	ModeInclude Mode = iota
	ModeExclude
)

type Decision int

const (
	Tunnel Decision = iota
	Bypass
)

type RuleSet struct {
	CIDRs []netip.Prefix
}

type Router struct {
	mode Mode
	set  *netipx.IPSet
}

func NewRouter(mode Mode, active RuleSet) *Router {
	var b netipx.IPSetBuilder
	for _, p := range active.CIDRs {
		b.AddPrefix(p)
	}
	set, _ := b.IPSet()
	return &Router{mode: mode, set: set}
}

func (r *Router) Decision(dst netip.Addr) Decision {
	in := r.set.Contains(dst)
	switch r.mode {
	case ModeExclude:
		if in {
			return Bypass
		}
		return Tunnel
	default: // ModeInclude
		if in {
			return Tunnel
		}
		return Bypass
	}
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd android/core && go test ./... -run TestRouter -v`
Expected: PASS (all three).

- [ ] **Step 6: Commit**

```bash
git add android/core/go.mod android/core/go.sum android/core/router.go android/core/router_test.go
git commit -m "feat(core): CIDR router with include/exclude modes"
```

---

## Task 2: wstunnel v10 JWT builder

**Files:**
- Create: `android/core/wstunnel/jwt.go`
- Test: `android/core/wstunnel/jwt_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `func BuildTunnelRequest(forwardHost string, forwardPort int, udpTimeout time.Duration) (protocolHeader string, err error)` — returns the full `sec-websocket-protocol` value `"v1, authorization.bearer.<JWT>"`.
  - `func randomID() string` — uuid-v7-shaped id.

The macOS ground truth (from `docs/superpowers/specs/2026-07-29-wireguard-over-tcp-design.md`): JWT header `{"typ":"JWT","alg":"HS256"}`; claims `{"id":"<uuid>","p":{"Udp":{"timeout":{"secs":30,"nanos":0}}},"r":"<forward-host>","rp":<forward-port>}`; signature is NOT verified by the server (random per-run secret is fine).

- [ ] **Step 1: Add the JWT dependency**

Run: `cd android/core && go get github.com/golang-jwt/jwt/v5 github.com/google/uuid`

- [ ] **Step 2: Write the failing test**

```go
// android/core/wstunnel/jwt_test.go
package wstunnel

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestBuildTunnelRequestShape(t *testing.T) {
	hdr, err := BuildTunnelRequest("127.0.0.1", 51840, 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(hdr, "v1, authorization.bearer.") {
		t.Fatalf("bad prefix: %q", hdr)
	}
	tokenStr := strings.TrimPrefix(hdr, "v1, authorization.bearer.")

	// Server decodes without verifying the signature; mirror that here.
	parser := jwt.NewParser()
	claims := jwt.MapClaims{}
	_, _, err = parser.ParseUnverified(tokenStr, claims)
	if err != nil {
		t.Fatal(err)
	}
	if claims["r"] != "127.0.0.1" {
		t.Fatalf("r claim: want 127.0.0.1, got %v", claims["r"])
	}
	if claims["rp"].(float64) != 51840 {
		t.Fatalf("rp claim: want 51840, got %v", claims["rp"])
	}
	p, _ := json.Marshal(claims["p"])
	if !strings.Contains(string(p), `"Udp"`) {
		t.Fatalf("p claim missing Udp: %s", p)
	}
}
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `cd android/core && go test ./wstunnel/ -run TestBuildTunnelRequest -v`
Expected: FAIL (undefined `BuildTunnelRequest`).

- [ ] **Step 4: Write the minimal implementation**

```go
// android/core/wstunnel/jwt.go
package wstunnel

import (
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

type udpTimeout struct {
	Secs  int `json:"secs"`
	Nanos int `json:"nanos"`
}

func BuildTunnelRequest(forwardHost string, forwardPort int, timeout time.Duration) (string, error) {
	claims := jwt.MapClaims{
		"id": uuid.NewString(),
		"p":  map[string]any{"Udp": map[string]any{"timeout": udpTimeout{Secs: int(timeout.Seconds()), Nanos: 0}}},
		"r":  forwardHost,
		"rp": forwardPort,
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	// Server does not verify; any HS256 signature bytes are accepted.
	signed, err := tok.SignedString([]byte(uuid.NewString()))
	if err != nil {
		return "", err
	}
	return "v1, authorization.bearer." + signed, nil
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd android/core && go test ./wstunnel/ -run TestBuildTunnelRequest -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add android/core/wstunnel/jwt.go android/core/wstunnel/jwt_test.go android/core/go.mod android/core/go.sum
git commit -m "feat(core): wstunnel v10 tunnel-request JWT builder"
```

---

## Task 3: wstunnel v10 UDP-over-WebSocket relay

**Files:**
- Create: `android/core/wstunnel/relay.go`
- Test: `android/core/wstunnel/relay_test.go`

**Interfaces:**
- Consumes: `BuildTunnelRequest` (Task 2).
- Produces:
  - `type Config struct { WSURL string; ForwardHost string; ForwardPort int; TLSConfig *tls.Config }`
  - `type Relay struct { ... }`
  - `func NewRelay(cfg Config, dial DialFunc) *Relay` where `type DialFunc func(ctx context.Context, network, addr string) (net.Conn, error)` (so the caller supplies a `protect()`ed dialer).
  - `func (r *Relay) Send(ctx context.Context, datagram []byte) error` — lazily opens the WS on first datagram, then writes one binary frame.
  - `func (r *Relay) Recv() <-chan []byte` — inbound datagrams.
  - `func (r *Relay) Close() error`

Wire protocol (ground truth): path `/<secret-path>/events`; tunnel request rides in the `sec-websocket-protocol` header; after the 101, each UDP datagram is exactly one **unmasked** WebSocket binary frame, no length prefix; WS ping/pong keepalive.

- [ ] **Step 1: Add the websocket dependency**

Run: `cd android/core && go get github.com/coder/websocket`

**CRITICAL — frames MUST be sent UNMASKED.** The macOS root cause (memory `wgtcp-websocket-masking-rootcause`) established that the wstunnel server does NOT unmask client frames: RFC-6455-compliant masking (what `NWProtocolWebSocket` did, and what `coder/websocket` also does) breaks the handshake. Do NOT rely on a compliant WS client library's write path. Options, in order of preference: (a) fork/patch the WS write path to skip masking, or (b) do the HTTP Upgrade with the WS library but then write raw unmasked binary frames directly onto the underlying `net.Conn` yourself (a WS binary frame with mask bit 0 is trivial: `0x82`, length, payload). Verify on the live server in Task 15 case 5; masked WILL fail, so build unmasked from the start.

- [ ] **Step 2: Write the failing test (loopback echo WS server)**

```go
// android/core/wstunnel/relay_test.go
package wstunnel

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestRelayLazyDialAndEcho(t *testing.T) {
	// Fake wstunnel server: accepts the WS upgrade, echoes binary frames.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/events") {
			http.Error(w, "bad path", 400)
			return
		}
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"v1"}})
		if err != nil {
			return
		}
		defer c.Close(websocket.StatusNormalClosure, "")
		for {
			typ, data, err := c.Read(context.Background())
			if err != nil {
				return
			}
			_ = c.Write(context.Background(), typ, data)
		}
	}))
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/secretpath/events"
	r := NewRelay(Config{WSURL: wsURL, ForwardHost: "127.0.0.1", ForwardPort: 51840},
		func(ctx context.Context, network, addr string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
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
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `cd android/core && go test ./wstunnel/ -run TestRelayLazyDial -v`
Expected: FAIL (undefined `NewRelay`/`Config`).

- [ ] **Step 4: Write the minimal implementation**

```go
// android/core/wstunnel/relay.go
package wstunnel

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type DialFunc func(ctx context.Context, network, addr string) (net.Conn, error)

type Config struct {
	WSURL       string
	ForwardHost string
	ForwardPort int
	TLSConfig   *tls.Config
}

type Relay struct {
	cfg   Config
	dial  DialFunc
	inbox chan []byte

	mu   sync.Mutex
	conn *websocket.Conn
	once sync.Once
	err  error
}

func NewRelay(cfg Config, dial DialFunc) *Relay {
	return &Relay{cfg: cfg, dial: dial, inbox: make(chan []byte, 256)}
}

func (r *Relay) ensure(ctx context.Context) error {
	r.once.Do(func() {
		hdr, err := BuildTunnelRequest(r.cfg.ForwardHost, r.cfg.ForwardPort, 30*time.Second)
		if err != nil {
			r.err = err
			return
		}
		httpClient := &http.Client{Transport: &http.Transport{
			DialContext:     func(ctx context.Context, network, addr string) (net.Conn, error) { return r.dial(ctx, network, addr) },
			TLSClientConfig: r.cfg.TLSConfig,
		}}
		c, _, err := websocket.Dial(ctx, r.cfg.WSURL, &websocket.DialOptions{
			HTTPClient:   httpClient,
			Subprotocols: []string{hdr}, // "v1, authorization.bearer.<JWT>"
		})
		if err != nil {
			r.err = err
			return
		}
		c.SetReadLimit(-1)
		r.conn = c
		go r.readLoop()
	})
	return r.err
}

func (r *Relay) readLoop() {
	for {
		_, data, err := r.conn.Read(context.Background())
		if err != nil {
			close(r.inbox)
			return
		}
		select {
		case r.inbox <- data:
		default: // drop if consumer is slow
		}
	}
}

func (r *Relay) Send(ctx context.Context, datagram []byte) error {
	if err := r.ensure(ctx); err != nil {
		return err
	}
	return r.conn.Write(ctx, websocket.MessageBinary, datagram)
}

func (r *Relay) Recv() <-chan []byte { return r.inbox }

func (r *Relay) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.conn != nil {
		return r.conn.Close(websocket.StatusNormalClosure, "")
	}
	return nil
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd android/core && go test ./wstunnel/ -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add android/core/wstunnel/relay.go android/core/wstunnel/relay_test.go android/core/go.mod android/core/go.sum
git commit -m "feat(core): wstunnel v10 UDP-over-WebSocket relay"
```

---

## Task 4: Transport interface + SSH transport

**Files:**
- Create: `android/core/transport/transport.go`
- Create: `android/core/transport/ssh.go`
- Test: `android/core/transport/ssh_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `var ErrUnsupportedProtocol = errors.New("transport: protocol unsupported")`
  - `type Transport interface { DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error); DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error); Close() error }`
  - `type SSHConfig struct { Addr string; User string; Signer ssh.Signer; HostKey ssh.PublicKey; Dial transport.DialFunc }` (reuses `wstunnel.DialFunc` shape; define a local `DialFunc` alias in `transport` package)
  - `func NewSSH(cfg SSHConfig) (*SSH, error)`
  - `SSH.DialTCP` opens a `direct-tcpip` channel; `SSH.DialUDP` returns `ErrUnsupportedProtocol`.

- [ ] **Step 1: Add the ssh dependency**

Run: `cd android/core && go get golang.org/x/crypto/ssh`

- [ ] **Step 2: Write the failing test (real in-process sshd)**

```go
// android/core/transport/ssh_test.go
package transport

import (
	"context"
	"crypto/ed25519"
	"io"
	"net"
	"net/netip"
	"testing"

	"golang.org/x/crypto/ssh"
)

// startTestSSHD spins up a minimal sshd that allows direct-tcpip to a backing echo server.
func startTestSSHD(t *testing.T) (addr string, hostPub ssh.PublicKey, signer ssh.Signer) {
	t.Helper()
	// Backing TCP echo server the client will reach via direct-tcpip.
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

	// dst is irrelevant to the test sshd (it always forwards to echo), but must parse.
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
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `cd android/core && go test ./transport/ -run TestSSH -v`
Expected: FAIL (undefined `NewSSH`/`SSHConfig`).

- [ ] **Step 4: Write the implementation**

```go
// android/core/transport/transport.go
package transport

import (
	"context"
	"errors"
	"net"
	"net/netip"
)

var ErrUnsupportedProtocol = errors.New("transport: protocol unsupported")

type DialFunc func(ctx context.Context, network, addr string) (net.Conn, error)

type Transport interface {
	DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error)
	DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error)
	Close() error
}
```

```go
// android/core/transport/ssh.go
package transport

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"sync"

	"golang.org/x/crypto/ssh"
)

type SSHConfig struct {
	Addr    string
	User    string
	Signer  ssh.Signer
	HostKey ssh.PublicKey
	Dial    DialFunc
}

type SSH struct {
	cfg    SSHConfig
	mu     sync.Mutex
	client *ssh.Client
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
	ccfg := &ssh.ClientConfig{
		User:            s.cfg.User,
		Auth:            []ssh.AuthMethod{ssh.PublicKeys(s.cfg.Signer)},
		HostKeyCallback: ssh.FixedHostKey(s.cfg.HostKey),
	}
	conn, chans, reqs, err := ssh.NewClientConn(nc, s.cfg.Addr, ccfg)
	if err != nil {
		nc.Close()
		return err
	}
	s.mu.Lock()
	s.client = ssh.NewClient(conn, chans, reqs)
	s.mu.Unlock()
	return nil
}

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
	defer s.mu.Unlock()
	if s.client != nil {
		return s.client.Close()
	}
	return nil
}
```

Note: `ssh.Client.DialContext` exists in recent `x/crypto`; if the pinned version lacks it, use `c.Dial("tcp", dst.String())` and honor ctx via a goroutine. Verify against the pinned version.

- [ ] **Step 5: Run tests, verify pass**

Run: `cd android/core && go test ./transport/ -run TestSSH -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add android/core/transport/ android/core/go.mod android/core/go.sum
git commit -m "feat(core): Transport interface + SSH direct-tcpip transport"
```

---

## Task 5: SSH keepalive + bounded reconnect

**Files:**
- Modify: `android/core/transport/ssh.go`
- Test: `android/core/transport/ssh_reconnect_test.go`

**Interfaces:**
- Consumes: Task 4 `SSH`.
- Produces:
  - `SSHConfig` gains `KeepAlive time.Duration` and `OnState func(connected bool)`.
  - `SSH.DialTCP` triggers a bounded exponential-backoff reconnect when the client is dead, and fails the current dial fast (does not hang) while reconnecting.

- [ ] **Step 1: Write the failing test**

```go
// android/core/transport/ssh_reconnect_test.go
package transport

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"
)

func TestSSHDialFailsFastWhenDown(t *testing.T) {
	// Point at a closed port: connect() in NewSSH will fail, so construct manually.
	s := &SSH{cfg: SSHConfig{
		Addr: "127.0.0.1:1", User: "u",
		Dial: func(ctx context.Context, network, a string) (net.Conn, error) { return net.Dial(network, a) },
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	_, err := s.DialTCP(ctx, netip.MustParseAddrPort("1.1.1.1:80"))
	if err == nil {
		t.Fatal("want fast failure when down, got nil")
	}
	if ctx.Err() != nil {
		t.Fatal("DialTCP hung until ctx deadline instead of failing fast")
	}
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd android/core && go test ./transport/ -run TestSSHDialFailsFast -v`
Expected: FAIL (`DialTCP` returns nil-client error path may hang or panic).

- [ ] **Step 3: Implement keepalive + reconnect**

Add to `ssh.go`: a background goroutine (started in `connect`) that sends `client.SendRequest("keepalive@openssh.com", true, nil)` every `KeepAlive`; on error it marks the client dead (`s.client = nil`), calls `OnState(false)`, and starts a bounded backoff reconnect loop (100ms, 200ms, ... cap 30s). `DialTCP` returns an immediate error if `s.client == nil` (fail fast). Full code:

```go
// add fields
type SSH struct {
	cfg     SSHConfig
	mu      sync.Mutex
	client  *ssh.Client
	closed  bool
}

// in connect(), after setting s.client:
if s.cfg.OnState != nil {
	s.cfg.OnState(true)
}
go s.keepAlive(s.client)

func (s *SSH) keepAlive(c *ssh.Client) {
	interval := s.cfg.KeepAlive
	if interval <= 0 {
		interval = 15 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for range t.C {
		_, _, err := c.SendRequest("keepalive@openssh.com", true, nil)
		if err != nil {
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
```

Update `Close()` to set `s.closed = true`. Update `NewSSH` to tolerate an initial failure by starting the reconnect loop instead of returning an error only if `cfg.OnState` is set — but for v1 keep `NewSSH` returning the initial error (caller decides). Ensure `DialTCP`'s `c == nil` path returns immediately.

- [ ] **Step 4: Run tests, verify pass**

Run: `cd android/core && go test ./transport/ -v`
Expected: PASS (both SSH tests).

- [ ] **Step 5: Commit**

```bash
git add android/core/transport/ssh.go android/core/transport/ssh_reconnect_test.go
git commit -m "feat(core): SSH keepalive and bounded-backoff reconnect"
```

---

## Task 6: WG-over-wstunnel transport

**Files:**
- Create: `android/core/transport/wgws.go`
- Test: `android/core/transport/wgws_test.go`

**Interfaces:**
- Consumes: `wstunnel.NewRelay` (Task 3), `transport.Transport` (Task 4).
- Produces:
  - `type WGConfig struct { PrivateKey string; PeerPublicKey string; PeerPresharedKey string; LocalAddrs []netip.Prefix; DNS []netip.Addr; MTU int; Relay *wstunnel.Relay }`
  - `func NewWGWS(cfg WGConfig) (*WGWS, error)` — brings up `wireguard-go` on a netstack `tnet.Net`, with a bind that forwards outbound UDP through the wstunnel `Relay` instead of a real socket.
  - `WGWS.DialTCP` → `tnet.DialContextTCPAddrPort`; `WGWS.DialUDP` → `tnet.DialUDPAddrPort`.

Key detail: `wireguard-go`'s default `conn.Bind` sends UDP to the peer endpoint via a real socket. Replace it with a custom `conn.Bind` whose `Send` writes datagrams to `Relay.Send` and whose receive path reads from `Relay.Recv()`. This is what keeps raw WG off the wire and routes it through the WebSocket. MTU is set from `cfg.MTU` (default 1280) to absorb WS/TLS/TCP overhead.

- [ ] **Step 1: Add wireguard deps**

Run: `cd android/core && go get golang.zx2c4.com/wireguard@latest`

- [ ] **Step 2: Write the failing test (bind adapter is the unit under test)**

Full end-to-end WG is validated on-device (Task 15). Here, unit-test the custom bind adapter in isolation: datagrams written by WG reach `Relay.Send`, and datagrams from `Relay.Recv()` are delivered to WG's receive callback.

```go
// android/core/transport/wgws_test.go
package transport

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestRelayBindRoundTrips(t *testing.T) {
	sent := make(chan []byte, 1)
	inbound := make(chan []byte, 1)
	b := newRelayBind(
		func(ctx context.Context, dg []byte) error { sent <- dg; return nil },
		inbound,
	)

	// WG "sends" a handshake datagram.
	eps, _ := b.Open(0)
	_ = eps
	ep := stubEndpoint{}
	if err := b.Send([][]byte{[]byte("wg-handshake")}, ep); err != nil {
		t.Fatal(err)
	}
	select {
	case dg := <-sent:
		if string(dg) != "wg-handshake" {
			t.Fatalf("send mismatch: %q", dg)
		}
	case <-time.After(time.Second):
		t.Fatal("bind did not forward outbound datagram to relay")
	}

	// Server "replies"; the bind's receive fn must surface it.
	recvFns, _, _ := b.Open(0)
	inbound <- []byte("wg-reply")
	bufs := [][]byte{make([]byte, 1500)}
	sizes := make([]int, 1)
	eps2 := make([]connEndpoint, 1)
	n, err := recvFns[0](bufs, sizes, eps2)
	if err != nil || n != 1 || string(bufs[0][:sizes[0]]) != "wg-reply" {
		t.Fatalf("bind did not surface inbound datagram: n=%d err=%v got=%q", n, err, bufs[0][:sizes[0]])
	}
}

type stubEndpoint struct{}

func (stubEndpoint) ClearSrc()           {}
func (stubEndpoint) SrcToString() string { return "" }
func (stubEndpoint) DstToString() string { return "" }
func (stubEndpoint) DstToBytes() []byte  { return nil }
func (stubEndpoint) DstIP() net.IP       { return nil }
func (stubEndpoint) SrcIP() net.IP       { return nil }
```

Note: `conn.Bind`, `conn.Endpoint`, and the `ReceiveFunc` signature are defined by `golang.zx2c4.com/wireguard/conn`. The exact method set (e.g. `Open(port uint16) ([]ReceiveFunc, uint16, error)`, `Send([][]byte, Endpoint) error`) must be matched to the pinned version — **read the `conn.Bind` interface godoc for the pinned wireguard-go and adjust the stub/aliases (`connEndpoint = conn.Endpoint`) accordingly** before writing the impl. This is the one task where the implementer must consult the library source first.

- [ ] **Step 3: Run the test, verify it fails**

Run: `cd android/core && go test ./transport/ -run TestRelayBind -v`
Expected: FAIL (undefined `newRelayBind`).

- [ ] **Step 4: Implement the relay bind + WGWS bring-up**

Implement `newRelayBind(send func(context.Context,[]byte) error, inbound <-chan []byte) conn.Bind` returning a bind whose `Send` calls `send` and whose `ReceiveFunc` drains `inbound`. Then `NewWGWS`:

```go
// android/core/transport/wgws.go (bring-up sketch — fill in per pinned API)
func NewWGWS(cfg WGConfig) (*WGWS, error) {
	tunDev, tnet, err := netstack.CreateNetTUN(cfg.LocalAddrs, cfg.DNS, mtuOrDefault(cfg.MTU))
	if err != nil {
		return nil, err
	}
	relayInbound := make(chan []byte, 256)
	go func() { for dg := range cfg.Relay.Recv() { relayInbound <- dg } }()
	bind := newRelayBind(cfg.Relay.Send, relayInbound)
	dev := device.NewDevice(tunDev, bind, device.NewLogger(device.LogLevelError, "wg "))
	if err := dev.IpcSet(uapiConfig(cfg)); err != nil { // private key, peer, endpoint=127.0.0.1:PORT, allowed_ips=0.0.0.0/0
		return nil, err
	}
	if err := dev.Up(); err != nil {
		return nil, err
	}
	return &WGWS{dev: dev, tnet: tnet}, nil
}

func (w *WGWS) DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	return w.tnet.DialContextTCPAddrPort(ctx, dst)
}
func (w *WGWS) DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error) {
	return w.tnet.DialUDPAddrPort(netip.AddrPort{}, dst)
}
func mtuOrDefault(m int) int { if m <= 0 { return 1280 }; return m }
```

`uapiConfig` builds the `IpcSet` string with `private_key`, `public_key`, `preshared_key` (hex), `endpoint=127.0.0.1:<relayLocalPort>`, `persistent_keepalive_interval=25`, `allowed_ip=0.0.0.0/0`. Confirm `DialContextTCPAddrPort` / `DialUDPAddrPort` names against the pinned `tun/netstack` godoc.

- [ ] **Step 5: Run tests, verify pass**

Run: `cd android/core && go test ./transport/ -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add android/core/transport/wgws.go android/core/transport/wgws_test.go android/core/go.mod android/core/go.sum
git commit -m "feat(core): WG-over-wstunnel transport with relay bind"
```

---

## Task 7: DNS interceptor

**Files:**
- Create: `android/core/dns.go`
- Test: `android/core/dns_test.go`

**Interfaces:**
- Consumes: `transport.Transport` (Task 4).
- Produces:
  - `func ResolveOverTCP(ctx context.Context, tr transport.Transport, resolver netip.AddrPort, query []byte) ([]byte, error)` — sends a DNS query as DNS-over-TCP (RFC 7766: 2-byte length prefix) to `resolver:53` via `tr.DialTCP`, returns the raw response payload (length prefix stripped).

- [ ] **Step 1: Write the failing test (fake DNS-over-TCP server via a fake Transport)**

```go
// android/core/dns_test.go
package core

import (
	"context"
	"encoding/binary"
	"net"
	"net/netip"
	"testing"

	"tunnelbahn/core/transport"
)

// fakeTransport.DialTCP returns a pipe wired to a tiny DoT-shaped echo:
// it reads the 2-byte length + body and replies with the same framing.
type fakeTransport struct{}

func (fakeTransport) DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		var lenBuf [2]byte
		if _, err := readFull(server, lenBuf[:]); err != nil {
			return
		}
		n := binary.BigEndian.Uint16(lenBuf[:])
		body := make([]byte, n)
		if _, err := readFull(server, body); err != nil {
			return
		}
		out := make([]byte, 2+len(body))
		binary.BigEndian.PutUint16(out[:2], uint16(len(body)))
		copy(out[2:], body)
		server.Write(out)
	}()
	return client, nil
}
func (fakeTransport) DialUDP(context.Context, netip.AddrPort) (net.PacketConn, error) {
	return nil, transport.ErrUnsupportedProtocol
}
func (fakeTransport) Close() error { return nil }

func readFull(c net.Conn, b []byte) (int, error) {
	got := 0
	for got < len(b) {
		n, err := c.Read(b[got:])
		got += n
		if err != nil {
			return got, err
		}
	}
	return got, nil
}

func TestResolveOverTCPFraming(t *testing.T) {
	query := []byte{0xAB, 0xCD, 0x01, 0x00} // opaque; server echoes it
	resp, err := ResolveOverTCP(context.Background(), fakeTransport{}, netip.MustParseAddrPort("1.1.1.1:53"), query)
	if err != nil {
		t.Fatal(err)
	}
	if string(resp) != string(query) {
		t.Fatalf("resolve echo mismatch: %x", resp)
	}
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd android/core && go test ./ -run TestResolveOverTCP -v`
Expected: FAIL (undefined `ResolveOverTCP`).

- [ ] **Step 3: Implement DNS-over-TCP forwarding**

```go
// android/core/dns.go
package core

import (
	"context"
	"encoding/binary"
	"io"
	"net/netip"

	"tunnelbahn/core/transport"
)

func ResolveOverTCP(ctx context.Context, tr transport.Transport, resolver netip.AddrPort, query []byte) ([]byte, error) {
	conn, err := tr.DialTCP(ctx, resolver)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	msg := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(msg[:2], uint16(len(query)))
	copy(msg[2:], query)
	if _, err := conn.Write(msg); err != nil {
		return nil, err
	}

	var lenBuf [2]byte
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint16(lenBuf[:])
	resp := make([]byte, n)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	return resp, nil
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd android/core && go test ./ -run TestResolveOverTCP -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/core/dns.go android/core/dns_test.go
git commit -m "feat(core): DNS-over-TCP resolver for UDP/53 interception"
```

---

## Task 8: Core config schema + Session facade

**Files:**
- Create: `android/core/config.go`
- Create: `android/core/session.go`
- Test: `android/core/config_test.go`

**Interfaces:**
- Consumes: Router (1), transports (4/6), DNS (7).
- Produces (this is the gomobile-exported surface — keep types gomobile-safe: only `string`, `int`, `bool`, and interfaces with such methods):
  - `type Protector interface { Protect(fd int) error }`
  - `type EventSink interface { OnState(state string); OnError(msg string) }`
  - `type Session struct { ... }`
  - `func NewSession() *Session`
  - `func (s *Session) Start(tunFD int, configJSON string, prot Protector, sink EventSink) error`
  - `func (s *Session) Stop()`
  - Internal `type coreConfig struct` parsed from `configJSON` (transport kind, SSH params, WG params, resolver, mode, include/exclude CIDR lists as strings).

Config JSON is produced by the Kotlin layer (Task 11) from the profile. It carries base64/hex key material because keys can't live in Android Keystore directly (see spec).

- [ ] **Step 1: Write the failing test (config parse + validation)**

```go
// android/core/config_test.go
package core

import "testing"

const sampleSSHConfig = `{
  "transport": "ssh",
  "mode": "exclude",
  "includeCIDRs": [],
  "excludeCIDRs": ["10.0.0.0/8"],
  "resolver": "1.1.1.1:53",
  "ssh": {"addr":"1.2.3.4:443","user":"tb","privateKeyPEM":"-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----\n","hostKeyAuthorized":"ssh-ed25519 AAAA..."}
}`

func TestParseConfigSSH(t *testing.T) {
	c, err := parseConfig(sampleSSHConfig)
	if err != nil {
		t.Fatal(err)
	}
	if c.Transport != "ssh" {
		t.Fatalf("transport: %q", c.Transport)
	}
	if c.Mode != ModeExclude {
		t.Fatalf("mode: %v", c.Mode)
	}
	if len(c.ExcludeCIDRs) != 1 || c.ExcludeCIDRs[0].String() != "10.0.0.0/8" {
		t.Fatalf("excludeCIDRs: %v", c.ExcludeCIDRs)
	}
}

func TestParseConfigRejectsUnknownTransport(t *testing.T) {
	if _, err := parseConfig(`{"transport":"telepathy"}`); err == nil {
		t.Fatal("want error for unknown transport")
	}
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd android/core && go test ./ -run TestParseConfig -v`
Expected: FAIL (undefined `parseConfig`).

- [ ] **Step 3: Implement config parsing + Session skeleton**

`config.go`: define the JSON structs, `parseConfig(s string) (*coreConfig, error)` that unmarshals, parses CIDR strings into `[]netip.Prefix`, maps `"include"/"exclude"` to `Mode`, and rejects unknown `transport` values (only `"ssh"`, `"wgws"`).

`session.go`: `Session.Start` — (1) parse config; (2) build the chosen `Transport` (SSH signer from `privateKeyPEM`, host key from `hostKeyAuthorized`; WG from key material + a `wstunnel.Relay` whose `DialFunc` wraps `prot.Protect` around a raw dialer); (3) build the `Router`; (4) open the netstack engine on `tunFD` (Task 9 wires the engine — for now Start may return a "engine not wired" sentinel so this task's tests target only `parseConfig`). Keep `Start`'s engine wiring as a documented stub that Task 9 completes.

- [ ] **Step 4: Run tests, verify pass**

Run: `cd android/core && go test ./ -run TestParseConfig -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/core/config.go android/core/session.go android/core/config_test.go
git commit -m "feat(core): core config schema and Session facade skeleton"
```

---

## Task 9: Wire the netstack tun2socks engine into Session

**Files:**
- Modify: `android/core/session.go`
- Create: `android/core/engine.go`
- Test: `android/core/engine_test.go`

**Interfaces:**
- Consumes: `Session` (8), `Router` (1), `Transport` (4/6), `ResolveOverTCP` (7).
- Produces:
  - Implements `github.com/xjasonlyu/tun2socks/v2/proxy`.`Proxy`-shaped dispatch: TCP conns from netstack are dialed via Router→Transport (or a `protect()`ed direct dialer on Bypass); UDP conns likewise, with dst-port 53 short-circuited to `ResolveOverTCP`.
  - `func (s *Session) Start(...)` now opens the engine on `fd://<tunFD>` and blocks until `Stop`.

- [ ] **Step 1: Add tun2socks dep**

Run: `cd android/core && go get github.com/xjasonlyu/tun2socks/v2@latest`

Read the pinned version's `engine` / `core` and `proxy.Proxy` interface godoc; the handler contract (`DialContext(ctx, *metadata) (net.Conn, error)` and `DialUDP(*metadata) (net.PacketConn, error)`) must be matched exactly. Adjust the adapter below to the real signatures.

- [ ] **Step 2: Write the failing test (dispatch logic, no real tun)**

Test the dispatch decision in isolation via a `dispatch(dst netip.AddrPort, isUDP bool) (route string)` helper returning `"tunnel"`, `"bypass"`, or `"dns"`, so we can assert routing without a tun device.

```go
// android/core/engine_test.go
package core

import (
	"net/netip"
	"testing"
)

func TestDispatchDNSShortCircuit() (t *testing.T) {}

func TestDispatchRoutes(t *testing.T) {
	d := newDispatcher(NewRouter(ModeExclude, RuleSet{CIDRs: []netip.Prefix{mustPfx("10.0.0.0/8")}}))
	if got := d.route(netip.MustParseAddrPort("10.1.1.1:443"), false); got != "bypass" {
		t.Fatalf("exclude in-set: want bypass, got %s", got)
	}
	if got := d.route(netip.MustParseAddrPort("8.8.8.8:443"), false); got != "tunnel" {
		t.Fatalf("exclude out-of-set: want tunnel, got %s", got)
	}
	if got := d.route(netip.MustParseAddrPort("8.8.8.8:53"), true); got != "dns" {
		t.Fatalf("udp/53: want dns, got %s", got)
	}
	if got := d.route(netip.MustParseAddrPort("10.0.0.1:53"), true); got != "bypass" {
		t.Fatalf("udp/53 in bypass set stays bypass, got %s", got)
	}
}
```

(Delete the stray empty `TestDispatchDNSShortCircuit` line — it's shown only to remind you to also cover the in-bypass-set DNS case, which the last assertion does.)

- [ ] **Step 3: Run the test, verify it fails**

Run: `cd android/core && go test ./ -run TestDispatchRoutes -v`
Expected: FAIL (undefined `newDispatcher`).

- [ ] **Step 4: Implement dispatcher + engine wiring**

`engine.go`: `type dispatcher struct { r *Router }`; `route(dst, isUDP)` returns `"dns"` when `isUDP && dst.Port()==53 && r.Decision(dst.Addr())==Tunnel`, else `"tunnel"`/`"bypass"` from `r.Decision`. Then the tun2socks `proxy.Proxy` adapter uses `route` to pick: tunnel→`transport.DialTCP/DialUDP`; bypass→a `protect()`ed direct dial; dns→wrap the UDP conn so writes become `ResolveOverTCP` calls and the answer is written back. Wire `Session.Start` to `engine.Insert`/`engine.Start` with `Device: "fd://<fd>"`, `MTU`, and this proxy. Block until `Stop()` calls `engine.Stop()`.

- [ ] **Step 5: Run tests, verify pass**

Run: `cd android/core && go test ./... -v`
Expected: PASS (all core packages).

- [ ] **Step 6: Commit**

```bash
git add android/core/engine.go android/core/session.go android/core/engine_test.go android/core/go.mod android/core/go.sum
git commit -m "feat(core): wire netstack engine with routing + DNS dispatch"
```

---

## Task 10: gomobile build of libtunnelbahn.aar

**Files:**
- Create: `android/core/mobile/mobile.go` (the gomobile entry package that re-exports `Session`, `Protector`, `EventSink`)
- Create: `android/build-core.sh`

**Interfaces:**
- Consumes: everything in `android/core`.
- Produces: `android/app/libs/libtunnelbahn.aar`.

- [ ] **Step 1: Create the gomobile entry package**

```go
// android/core/mobile/mobile.go
package mobile

import "tunnelbahn/core"

// gomobile exports the types referenced from this package's exported funcs.
type Protector = core.Protector
type EventSink = core.EventSink
type Session = core.Session

func NewSession() *Session { return core.NewSession() }
```

- [ ] **Step 2: Write the build script**

```bash
# android/build-core.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/core"
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init
gomobile bind -target=android -androidapi 24 -o ../app/libs/libtunnelbahn.aar ./mobile
echo "built android/app/libs/libtunnelbahn.aar"
```

- [ ] **Step 3: Run the build, verify the AAR is produced**

Run: `chmod +x android/build-core.sh && ANDROID_NDK_HOME=<ndk> android/build-core.sh`
Expected: `android/app/libs/libtunnelbahn.aar` exists. Verify with `unzip -l android/app/libs/libtunnelbahn.aar | grep -E 'classes.jar|arm64-v8a'`.

- [ ] **Step 4: Commit**

```bash
git add android/core/mobile/mobile.go android/build-core.sh
git commit -m "build(core): gomobile bind entry package and build script"
```

(Do not commit the AAR; it is a build artifact. Add `android/app/libs/*.aar` to `.gitignore` in this task.)

---

## Task 11: Android app scaffold + profile model + encrypted store

**Files:**
- Create: `android/app/build.gradle.kts`, `android/settings.gradle.kts`, `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/java/tunnelbahn/app/profile/Profile.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/profile/ProfileStore.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/profile/ProfileStoreTest.kt`

**Interfaces:**
- Consumes: nothing (mirrors the macOS profile schema — read `Shared/` models: WG keys, endpoint, SSH host/user key, wstunnel path, `DestinationRouting` mode + CIDR lists).
- Produces:
  - `data class Profile(...)` — transport kind, endpoint, keys (as strings), routing mode, include/exclude CIDR lists, per-app package list + app mode.
  - `class ProfileStore(context)` — `save(Profile)`, `load(id): Profile?`, `all(): List<Profile>`; keys are stored via `EncryptedSharedPreferences`, non-key fields in plain prefs/JSON.
  - `fun Profile.toCoreConfigJson(): String` — produces the exact JSON Task 8 parses.

- [ ] **Step 1: Scaffold Gradle + manifest**

Set `minSdk 24`, `targetSdk 35`. Manifest declares `<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>`, `FOREGROUND_SERVICE_SYSTEM_EXEMPTED` (or `SPECIAL_USE`), and the `VpnService` with `<intent-filter><action android:name="android.net.VpnService"/></intent-filter>`. Add `androidx.security:security-crypto` and Compose/Material3 deps. Add `implementation(files("libs/libtunnelbahn.aar"))`.

- [ ] **Step 2: Write the failing test**

```kotlin
// ProfileStoreTest.kt (Robolectric so EncryptedSharedPreferences has a context)
@RunWith(RobolectricTestRunner::class)
class ProfileStoreTest {
    @Test fun saveThenLoadRoundTrips() {
        val ctx = RuntimeEnvironment.getApplication()
        val store = ProfileStore(ctx)
        val p = Profile(
            id = "p1", name = "SSH exit", transport = Transport.SSH,
            endpoint = "1.2.3.4:443", sshUser = "tb",
            sshPrivateKeyPem = "-----BEGIN OPENSSH PRIVATE KEY-----\nX\n-----END OPENSSH PRIVATE KEY-----\n",
            sshHostKeyAuthorized = "ssh-ed25519 AAAA",
            routingMode = RoutingMode.EXCLUDE,
            includeCIDRs = emptyList(), excludeCIDRs = listOf("10.0.0.0/8"),
            resolver = "1.1.1.1:53",
            appMode = AppMode.INCLUDE, packages = listOf("com.example.app"),
        )
        store.save(p)
        val loaded = store.load("p1")!!
        assertEquals(p.sshPrivateKeyPem, loaded.sshPrivateKeyPem)
        assertEquals(listOf("10.0.0.0/8"), loaded.excludeCIDRs)
    }

    @Test fun coreConfigJsonHasNoRawKeyInPlainFields() {
        // toCoreConfigJson is the boundary to Go; assert it carries the SSH block.
        val p = /* same as above */ TODO("reuse builder")
        val json = p.toCoreConfigJson()
        assertTrue(json.contains("\"transport\":\"ssh\""))
        assertTrue(json.contains("\"excludeCIDRs\":[\"10.0.0.0/8\"]"))
    }
}
```

(Replace the `TODO` with the shared `Profile` builder from the first test.)

- [ ] **Step 3: Run the test, verify it fails**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests '*ProfileStoreTest*'`
Expected: FAIL (unresolved `Profile`/`ProfileStore`).

- [ ] **Step 4: Implement Profile + ProfileStore**

`Profile.kt`: the `data class` + enums `Transport{SSH,WGWS}`, `RoutingMode{INCLUDE,EXCLUDE}`, `AppMode{INCLUDE,EXCLUDE}`, and `toCoreConfigJson()` building the Task-8 JSON (kotlinx.serialization). `ProfileStore.kt`: key fields (`sshPrivateKeyPem`, WG `privateKey`) written to `EncryptedSharedPreferences`; the rest serialized to a plain prefs JSON keyed by id.

- [ ] **Step 5: Run tests, verify pass**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests '*ProfileStoreTest*'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add android/settings.gradle.kts android/app/build.gradle.kts android/app/src/main/AndroidManifest.xml android/app/src/main/java/tunnelbahn/app/profile/ android/app/src/test/ android/.gitignore
git commit -m "feat(app): scaffold + Profile model + encrypted ProfileStore"
```

---

## Task 12: TunnelBahnVpnService (tun builder + per-app + routes + Protector)

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/vpn/AndroidProtector.kt`
- Test: `android/app/src/androidTest/java/tunnelbahn/app/vpn/VpnServiceInstrumentedTest.kt`

**Interfaces:**
- Consumes: `Profile` (11), `libtunnelbahn` `Session`/`Protector`/`EventSink` (10).
- Produces:
  - `class TunnelBahnVpnService : VpnService()` — on start intent, builds the tun (`Builder`), applies per-app allow/deny by `AppMode`, `addRoute` per routing mode (include: each include CIDR; exclude: `0.0.0.0/0`), `addDnsServer` (a sentinel in-tunnel resolver IP so apps send DNS into the tun), then `session.Start(fd, profile.toCoreConfigJson(), AndroidProtector(this), sink)`.
  - `class AndroidProtector(vpn: VpnService) : Protector { override fun protect(fd: Int): Unit ... }` (wraps `VpnService.protect(fd)`; throw on false).

- [ ] **Step 1: Write the instrumented test (requires a device/emulator + user VPN consent)**

Instrumented, not unit: assert the service builds a tun and reaches `RUNNING` state for a loopback profile. Because `VpnService.prepare` needs user consent, the test uses a profile pointing at a local mock and is `@Ignore`-able in CI but runnable locally.

```kotlin
@RunWith(AndroidJUnit4::class)
class VpnServiceInstrumentedTest {
    @Test fun serviceReachesRunningForLocalProfile() {
        // Preconditions: VPN consent already granted on the test device.
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val intent = Intent(ctx, TunnelBahnVpnService::class.java)
            .putExtra("profileId", seedLocalLoopbackProfile(ctx))
        ctx.startService(intent)
        assertTrue(waitForState(ctx, "RUNNING", timeoutMs = 8000))
    }
}
```

`waitForState` observes states the service broadcasts from the `EventSink`.

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd android && ./gradlew :app:connectedDebugAndroidTest --tests '*VpnServiceInstrumentedTest*'`
Expected: FAIL (service class does not exist).

- [ ] **Step 3: Implement the service + protector**

Build the tun in `onStartCommand`, spawn `session.Start` on a background thread (it blocks), broadcast `OnState`/`OnError` from the `EventSink` via `LocalBroadcastManager`. Run as a foreground service with a persistent notification (needed while the tunnel is up).

- [ ] **Step 4: Run the test, verify pass**

Run: `cd android && ./gradlew :app:connectedDebugAndroidTest --tests '*VpnServiceInstrumentedTest*'`
Expected: PASS on a device with VPN consent granted.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/vpn/ android/app/src/androidTest/
git commit -m "feat(app): VpnService with per-app + route setup and Protector bridge"
```

---

## Task 13: Connect/disconnect UI + profile list + transport picker

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/ui/MainScreen.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/ui/ProfileEditor.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/MainActivity.kt`

**Interfaces:**
- Consumes: `ProfileStore` (11), `TunnelBahnVpnService` (12).
- Produces: a Compose UI: profile list with connect/disconnect, an editor to create/edit a profile (name, transport radio SSH/WGWS, endpoint, key import, resolver). Connect calls `VpnService.prepare()` then starts the service; state chip reflects the broadcast state.

- [ ] **Step 1: Build the UI**

Material 3 Compose. Profile list (LazyColumn) + FAB to add. Editor with a transport `RadioButton` pair. Connect button: `startActivityForResult(VpnService.prepare(ctx))`, and on OK start the service with the selected `profileId`. Show a state chip: Disconnected / Connecting / Running / Degraded (from the `OnState` broadcast; "Degraded" is emitted by the SSH transport `OnState(false)` while reconnecting).

- [ ] **Step 2: Manual verification (no unit test for Compose wiring here)**

Run: `cd android && ./gradlew :app:installDebug` then launch. Verify: create an SSH profile, tap Connect, grant VPN consent, chip goes Running. Tap Disconnect, chip goes Disconnected. This is the happy-path smoke check; e2e traffic is Task 15.

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/ android/app/src/main/java/tunnelbahn/app/MainActivity.kt
git commit -m "feat(app): main screen, profile editor, transport picker, connect flow"
```

---

## Task 14: Per-app picker + CIDR rule editor (include/exclude)

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/ui/AppPickerScreen.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/ui/CidrRulesScreen.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/ui/CidrParseTest.kt`

**Interfaces:**
- Consumes: `Profile` (11).
- Produces:
  - App picker: lists installed launchable apps (`PackageManager`), multi-select, with an include/exclude mode toggle; writes `profile.packages` + `profile.appMode`.
  - CIDR editor: include/exclude mode radios swapping two independent rule lists; a bulk-paste box that parses newline/space-separated CIDRs; per-mode enable toggles. Writes `profile.includeCIDRs` / `profile.excludeCIDRs`.
  - `fun parseCidrLines(text: String): Pair<List<String>, List<String>>` returning (valid, invalid) for inline validation feedback.

- [ ] **Step 1: Write the failing test for CIDR parsing**

```kotlin
class CidrParseTest {
    @Test fun splitsValidFromInvalid() {
        val (ok, bad) = parseCidrLines("10.0.0.0/8\n not-a-cidr \n192.168.1.0/24\n999.1.1.1/8")
        assertEquals(listOf("10.0.0.0/8", "192.168.1.0/24"), ok)
        assertEquals(listOf("not-a-cidr", "999.1.1.1/8"), bad)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests '*CidrParseTest*'`
Expected: FAIL (unresolved `parseCidrLines`).

- [ ] **Step 3: Implement parsing + screens**

`parseCidrLines` validates each token with `java.net`-based or a small manual CIDR check (address + `/len`), returning valid/invalid lists. Build the two Compose screens; mode radios swap which list is shown/edited (mirrors macOS per-mode independent sets). Follow the tooltip idiom (questionmark + tooltip), no inline footnotes, no em dashes.

- [ ] **Step 4: Run tests, verify pass**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests '*CidrParseTest*'`
Expected: PASS.

- [ ] **Step 5: Manual verification**

Install, edit a profile: select 2 apps in include mode; add `10.0.0.0/8` to the exclude list; paste a bad line and confirm it is flagged. Save, reopen, confirm persistence.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/AppPickerScreen.kt android/app/src/main/java/tunnelbahn/app/ui/CidrRulesScreen.kt android/app/src/test/java/tunnelbahn/app/ui/CidrParseTest.kt
git commit -m "feat(app): per-app picker and per-mode CIDR rule editor"
```

---

## Task 15: On-device e2e validation against existing servers

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/debug/HeadlessDriver.kt`
- Create: `docs/superpowers/plans/2026-08-02-android-e2e-checklist.md`

**Interfaces:**
- Consumes: the whole app.
- Produces: a `tunnelbahn-android://test?profile=<id>` deep-link driver (mirroring the macOS `tunnelbahn://test` URL driver) that connects, runs an exit-IP probe, and logs the result; plus a written e2e checklist.

- [ ] **Step 1: Implement the headless driver**

An activity/`intent-filter` on `tunnelbahn-android://test` that: loads the profile, connects the VPN, waits for `Running`, performs an HTTP GET to an exit-IP echo service through the tunnel, logs the observed IP + pass/fail, and (optionally) disconnects. This lets e2e run without hand-tapping.

- [ ] **Step 2: Run the e2e checklist (real servers, real device)**

Write and execute `2026-08-02-android-e2e-checklist.md` covering exactly these cases:

1. **SSH, include mode:** only a chosen app tunneled; exit IP for that app is the server, others direct. DNS resolves.
2. **SSH, exclude/full-tunnel mode:** `addRoute 0.0.0.0/0`; **confirm DNS resolves** (UDP/53 → TCP/53 path) and a page loads. This is the case that would silently fail without the DNS interceptor.
3. **SSH through the Iranian gateway:** confirm real traffic flows (the empirical reason SSH is primary).
4. **WG+wstunnel:** handshake completes; exit-IP check shows the server; **a UDP/QUIC flow is carried** (e.g. an HTTP/3 request succeeds), proving `DialUDP` works.
5. **wstunnel frame masking:** confirm the relay's UNMASKED frames complete the handshake (masked frames are known to fail per the macOS root cause). If the implementer accidentally shipped masked frames, this is where it surfaces.
6. **protect() loop check:** confirm bypass flows and the transport's own sockets egress directly (no routing loop, no handshake stall).

- [ ] **Step 3: Fix any failures, then commit the driver + checklist with results**

```bash
git add android/app/src/main/java/tunnelbahn/app/debug/HeadlessDriver.kt docs/superpowers/plans/2026-08-02-android-e2e-checklist.md
git commit -m "test(app): headless e2e driver + on-device validation checklist"
```

---

## Self-Review

**Spec coverage:**
- Two transports (SSH primary, WG+wstunnel secondary) → Tasks 4/5 (SSH), 6 (WG). ✓
- Transport interface with `DialTCP`+`DialUDP`, SSH `ErrUnsupportedProtocol` → Task 4. ✓
- Per-app routing → Task 12 (`addAllowed/DisallowedApplication`), 14 (picker). ✓
- Per-destination CIDR, include/exclude per-mode independent sets → Task 1 (Router), 14 (editor), 11 (profile). ✓
- AND-composition of OS route + Router → Task 12 (`addRoute` per mode) + Task 9 (dispatcher). ✓
- wstunnel v10 (JWT, one binary frame per datagram, unmasked concern) → Tasks 2, 3, and 15 step 5 (masking verification). ✓
- WG never raw on wire (endpoint = local relay via custom bind) → Task 6. ✓
- WG inner MTU lowered → Task 6 (`mtuOrDefault` 1280). ✓
- DNS-through-tunnel (UDP/53 → TCP/53), defeats poisoning → Task 7 + Task 9 dispatch + Task 15 case 2. ✓
- Keys encrypted at rest, not in Keystore, never in profile JSON → Task 11 (`EncryptedSharedPreferences`). ✓
- `protect()` callback seam → Task 8 (`Protector`), 12 (`AndroidProtector`), 15 case 6. ✓
- Error handling: state events, degraded on reconnect, protect() loud → Task 5 (`OnState`), 12/13 (broadcast + chip). ✓
- Testing: Router, wstunnel codec, SSH integration, DNS, e2e incl. SSH full-tunnel DNS + WG UDP → Tasks 1,3,4,7,15. ✓
- gomobile-safe exported surface (string/int/interface only) → Task 8/10. ✓
- No domain rules (deferred) → not implemented, correctly. ✓

**Placeholder scan:** Task 9's `TestDispatchDNSShortCircuit` empty line and Task 11's `TODO("reuse builder")` are called out inline as reminders to inline the shared builder, not left as silent gaps. Tasks 6 and 9 explicitly flag "read the pinned library godoc and match signatures" rather than fabricating exact external API names — this is deliberate, since `conn.Bind`, `tun/netstack`, and `tun2socks` signatures vary by version and must be verified, not guessed.

**Type consistency:** `Transport{DialTCP,DialUDP,Close}`, `Router.Decision`, `Mode`, `RuleSet`, `Protector.Protect`, `EventSink.OnState/OnError`, `Session.Start/Stop`, `Profile.toCoreConfigJson` are used consistently across tasks.

## Open risks the implementer must actively verify (not blocking)

1. **wstunnel client-frame masking (Task 3 / Task 15 case 5).** Frames MUST be unmasked — the macOS root cause proved the server does not unmask. Build the unmasked writer from the start; do not use a compliant WS client's masked write path.
2. **External library signatures (Tasks 6, 9).** `conn.Bind`, `tun/netstack` dialers, and `tun2socks` proxy interface must be matched to pinned versions.
3. **gomobile + 16KB page size (Task 10).** Recent NDK required; build script pins `-androidapi 24`.

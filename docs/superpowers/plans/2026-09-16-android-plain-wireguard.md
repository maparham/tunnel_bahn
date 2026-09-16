# Android Plain WireGuard Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a plain UDP WireGuard transport (`wg`) to the Android client, importable by QR from macOS and creatable by hand in the Android editor.

**Architecture:** The Go core's WireGuard-over-wstunnel transport already runs wireguard-go plus gVisor netstack in userspace; only its socket layer (a custom `conn.Bind` over the WebSocket relay) is wstunnel-specific. We extract the shared device setup into `wg_device.go`, add a `udpBind` over one protected UDP socket plus a handshake-age watchdog in `wg.go`, and thread a new `"wg"` transport value with `endpoint`/`keepalive` fields through the core config, the Kotlin profile model, QR import, the editor, and the macOS QR encoder.

**Tech Stack:** Go 1.27 (module floor 1.26.3), wireguard-go + netstack, gomobile; Kotlin + Jetpack Compose + kotlinx.serialization + JUnit/Robolectric; Swift + XCTest.

**Spec:** `docs/superpowers/specs/2026-09-16-android-plain-wireguard-design.md`

## Global Constraints

- Transport string values are exactly `"ssh"`, `"wgws"`, `"wg"` in both the QR payload and the core config JSON.
- New `wg` JSON fields are `"endpoint"` (string, `host:port`) and `"keepalive"` (int, default 25) inside the existing `"wg"` object.
- Watchdog constants: tick 5 s, stale threshold 180 s. Default keepalive 25 s.
- Existing `wgws` behaviour and its tests must not change (tests pass unmodified).
- Go tests: run from `android/core` with `go test ./...`. The machine has Go 1.27.1 and `GOPROXY=https://goproxy.io,direct` (proxy.golang.org is geo-blocked here; do not change that).
- Kotlin unit tests: `cd android && ./gradlew --offline :app:testDebugUnitTest --tests 'tunnelbahn.app.profile.*'`. If `--offline` fails on a missing dependency, retry without it once.
- Swift tests need `xcodebuild`, which slows the user's machine. **Propose the exact command and wait for the user's approval before running it.** Never run it unprompted.
- Commit on the current branch (`main`). Do not create branches. End every commit message with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01PZNQf6WPdEcpZRZ9hJJasP
  ```

---

## File map

| File | Responsibility |
|---|---|
| `android/core/config.go` | Parse/validate core config JSON; gains `wg` transport + `endpoint`/`keepalive`. |
| `android/core/transport/wg_device.go` (new) | Shared wireguard-go device construction, uapi rendering, handshake polling. Extracted from `wgws.go`. |
| `android/core/transport/wgws.go` | Relay bind + thin `WGWS` transport over the shared helpers. |
| `android/core/transport/wg.go` (new) | `udpBind`, `WG` transport, handshake-age watchdog. |
| `android/core/session.go` | `buildTransport` gains `case "wg"`. |
| `android/app/.../profile/Profile.kt` | `Transport.WG`, `wgEndpoint`, `wgKeepalive`, `displayEndpoint()`, core-config JSON. |
| `android/app/.../profile/QRImport.kt` | Parse `"wg"` QR payloads. |
| `android/app/.../ui/ProfileEditor.kt` | Third transport radio; endpoint field. |
| `android/app/.../ui/MainScreen.kt` | Profile subtitle uses `displayEndpoint()`. |
| `TunnelBahn/Services/AndroidProfileQRCodec.swift` | Encode plain WG profiles as `"wg"`. |
| `TunnelBahn/Views/ProfilesView.swift` | Error text in the QR panel wraps instead of truncating. |
| `docs/superpowers/specs/2026-08-02-android-client-design.md` | Dated note relaxing the "never raw WG" principle. |

---

### Task 1: Core config accepts `wg` with an endpoint

**Files:**
- Modify: `android/core/config.go:18-28` (`wgParams`), `android/core/config.go:59-63` (transport switch)
- Test: `android/core/config_test.go`

**Interfaces:**
- Produces: `wgParams.Endpoint string` (json `endpoint`), `wgParams.Keepalive int` (json `keepalive`); `parseConfig` accepts `"wg"`.

- [ ] **Step 1: Write the failing tests**

Append to `android/core/config_test.go`:

```go
func TestParseConfigWGRequiresEndpoint(t *testing.T) {
	if _, err := parseConfig(`{"transport":"wg","wg":{"endpoint":""}}`); err == nil {
		t.Fatal("want error for wg without endpoint")
	}
	if _, err := parseConfig(`{"transport":"wg","wg":{"endpoint":"   "}}`); err == nil {
		t.Fatal("want error for whitespace-only wg endpoint")
	}
}

func TestParseConfigWGCarriesEndpointAndKeepalive(t *testing.T) {
	c, err := parseConfig(`{"transport":"wg","wg":{"endpoint":"3.139.146.5:51820","keepalive":15}}`)
	if err != nil {
		t.Fatal(err)
	}
	if c.Transport != "wg" {
		t.Fatalf("transport: %q", c.Transport)
	}
	if c.WG.Endpoint != "3.139.146.5:51820" {
		t.Fatalf("endpoint: %q", c.WG.Endpoint)
	}
	if c.WG.Keepalive != 15 {
		t.Fatalf("keepalive: %d", c.WG.Keepalive)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd android/core && go test ./ -run 'TestParseConfigWG' -v`
Expected: both FAIL (`unknown transport "wg"` / endpoint test gets nil error).

- [ ] **Step 3: Implement**

In `android/core/config.go`, add `"strings"` to the imports, add two fields to `wgParams`:

```go
type wgParams struct {
	PrivateKey       string   `json:"privateKey"`
	PeerPublicKey    string   `json:"peerPublicKey"`
	PeerPresharedKey string   `json:"peerPresharedKey"`
	LocalAddrs       []string `json:"localAddrs"`
	DNS              []string `json:"dns"`
	MTU              int      `json:"mtu"`
	WSURL            string   `json:"wsURL"`
	ForwardHost      string   `json:"forwardHost"`
	ForwardPort      int      `json:"forwardPort"`
	// Plain-UDP WireGuard only ("wg" transport).
	Endpoint  string `json:"endpoint"`  // host:port of the WG peer
	Keepalive int    `json:"keepalive"` // persistent keepalive seconds; 0 => 25
}
```

and replace the transport switch:

```go
	switch raw.Transport {
	case "ssh", "wgws":
	case "wg":
		if strings.TrimSpace(raw.WG.Endpoint) == "" {
			return nil, fmt.Errorf("config: wg endpoint required")
		}
	default:
		return nil, fmt.Errorf("config: unknown transport %q", raw.Transport)
	}
```

- [ ] **Step 4: Run the package tests**

Run: `cd android/core && go test ./ -run 'TestParseConfig' -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add android/core/config.go android/core/config_test.go
git commit -m "feat(core): accept the wg transport in the core config"
```

---

### Task 2: Extract shared WireGuard device helpers from `wgws.go`

Pure refactor plus one new config field. Existing `wgws_*` tests must pass unmodified.

**Files:**
- Create: `android/core/transport/wg_device.go`
- Modify: `android/core/transport/wgws.go` (remove what moved; `NewWGWS` and `WaitReady` call the helpers)
- Test: `android/core/transport/wg_device_test.go` (new)

**Interfaces:**
- Produces (all package-private, in `wg_device.go`):
  - `WGConfig.Keepalive int` (new field; 0 means 25)
  - `func newWGDevice(cfg WGConfig, bind conn.Bind, endpoint string) (*device.Device, *netstack.Net, error)`
  - `func uapiConfig(cfg WGConfig, endpoint string) (string, error)`
  - `func handshakeAge(dev *device.Device, now time.Time) (time.Duration, bool)`
  - `func waitHandshake(ctx context.Context, dev *device.Device, dialErr func() error) error`
  - `func keepaliveOrDefault(k int) int`, `func mtuOrDefault(m int) int`, `func keyHex(b64 string) (string, error)`

- [ ] **Step 1: Write the failing tests**

Create `android/core/transport/wg_device_test.go`:

```go
package transport

import (
	"strings"
	"testing"
)

func TestUapiConfigUsesEndpointAndKeepalive(t *testing.T) {
	cfg := WGConfig{PrivateKey: randKeyB64(t), PeerPublicKey: randKeyB64(t), Keepalive: 15}
	s, err := uapiConfig(cfg, "3.139.146.5:51820")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"endpoint=3.139.146.5:51820\n",
		"persistent_keepalive_interval=15\n",
		"allowed_ip=0.0.0.0/0\n",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("uapi missing %q:\n%s", want, s)
		}
	}
}

func TestUapiConfigDefaultsKeepaliveTo25(t *testing.T) {
	cfg := WGConfig{PrivateKey: randKeyB64(t), PeerPublicKey: randKeyB64(t)}
	s, err := uapiConfig(cfg, "127.0.0.1:51820")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(s, "persistent_keepalive_interval=25\n") {
		t.Fatalf("want default keepalive 25:\n%s", s)
	}
}
```

(`randKeyB64` already exists in `wgws_ready_test.go`.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd android/core && go test ./transport -run 'TestUapiConfig' -v`
Expected: compile error (`uapiConfig` takes one argument; no `Keepalive` field).

- [ ] **Step 3: Create `wg_device.go`**

```go
package transport

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"

	"tunnelbahn/core/wstunnel"
)

// WGConfig configures a userspace WireGuard device. Shared by the plain-UDP (WG) and
// WireGuard-over-wstunnel (WGWS) transports.
type WGConfig struct {
	PrivateKey       string // standard-base64 32-byte key
	PeerPublicKey    string // standard-base64 32-byte key
	PeerPresharedKey string // optional standard-base64 32-byte key
	LocalAddrs       []netip.Addr
	DNS              []netip.Addr
	MTU              int
	Keepalive        int // persistent keepalive seconds; 0 => 25
	Relay            *wstunnel.Relay // WGWS only; nil for plain WG
}

const defaultKeepalive = 25

// newWGDevice creates the netstack TUN and the wireguard-go device over bind, applies
// the uapi config with the given peer endpoint, and brings the device up. On any
// failure it closes what it created and returns the error. It performs no network I/O.
func newWGDevice(cfg WGConfig, bind conn.Bind, endpoint string) (*device.Device, *netstack.Net, error) {
	tunDev, tnet, err := netstack.CreateNetTUN(cfg.LocalAddrs, cfg.DNS, mtuOrDefault(cfg.MTU))
	if err != nil {
		return nil, nil, err
	}
	dev := device.NewDevice(tunDev, bind, device.NewLogger(device.LogLevelError, "wg "))
	uapi, err := uapiConfig(cfg, endpoint)
	if err != nil {
		dev.Close()
		return nil, nil, err
	}
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		return nil, nil, err
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, nil, err
	}
	return dev, tnet, nil
}

// handshakeAge reports how long ago the peer's last handshake completed, read from the
// device's uapi "last_handshake_time_sec" line. ok is false until the first handshake.
func handshakeAge(dev *device.Device, now time.Time) (time.Duration, bool) {
	uapi, err := dev.IpcGet()
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(uapi, "\n") {
		v, found := strings.CutPrefix(line, "last_handshake_time_sec=")
		if !found {
			continue
		}
		sec, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil || sec == 0 {
			return 0, false
		}
		return now.Sub(time.Unix(sec, 0)), true
	}
	return 0, false
}

// waitHandshake blocks until the peer completes its first handshake (proving the
// tunnel actually reaches the server), or ctx is done. dialErr, if non-nil, is polled
// so a carrier that failed to dial surfaces immediately instead of idling until the
// deadline.
func waitHandshake(ctx context.Context, dev *device.Device, dialErr func() error) error {
	t := time.NewTicker(150 * time.Millisecond)
	defer t.Stop()
	for {
		if _, ok := handshakeAge(dev, time.Now()); ok {
			return nil
		}
		if dialErr != nil {
			if err := dialErr(); err != nil {
				return err
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		}
	}
}

func mtuOrDefault(m int) int {
	if m <= 0 {
		return 1280
	}
	return m
}

func keepaliveOrDefault(k int) int {
	if k <= 0 {
		return defaultKeepalive
	}
	return k
}

// uapiConfig builds the wireguard-go IpcSet string. WG keys arrive standard-base64
// (the format the macOS profile stores) and must be converted to hex for uapi.
// endpoint must be a resolved ip:port; uapi does not accept hostnames.
func uapiConfig(cfg WGConfig, endpoint string) (string, error) {
	priv, err := keyHex(cfg.PrivateKey)
	if err != nil {
		return "", fmt.Errorf("private key: %w", err)
	}
	pub, err := keyHex(cfg.PeerPublicKey)
	if err != nil {
		return "", fmt.Errorf("peer public key: %w", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", priv)
	fmt.Fprintf(&b, "public_key=%s\n", pub)
	if cfg.PeerPresharedKey != "" {
		psk, err := keyHex(cfg.PeerPresharedKey)
		if err != nil {
			return "", fmt.Errorf("preshared key: %w", err)
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", psk)
	}
	fmt.Fprintf(&b, "endpoint=%s\n", endpoint)
	fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", keepaliveOrDefault(cfg.Keepalive))
	fmt.Fprintf(&b, "allowed_ip=0.0.0.0/0\n")
	fmt.Fprintf(&b, "allowed_ip=::/0\n")
	return b.String(), nil
}

func keyHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("want 32-byte key, got %d", len(raw))
	}
	return hex.EncodeToString(raw), nil
}
```

- [ ] **Step 4: Shrink `wgws.go`**

In `android/core/transport/wgws.go`:

1. Delete the `WGConfig` struct, `mtuOrDefault`, `uapiConfig`, `keyHex`, and `handshakeComplete`. Delete the now-unused imports (`encoding/base64`, `encoding/hex`; keep the ones still used).
2. Replace `NewWGWS` with:

```go
func NewWGWS(cfg WGConfig) (*WGWS, error) {
	inbound := make(chan []byte, 256)
	bind := newRelayBind(cfg.Relay.Send, inbound)
	// Endpoint is ignored by relayBind but must be syntactically valid.
	dev, tnet, err := newWGDevice(cfg, bind, "127.0.0.1:51820")
	if err != nil {
		cfg.Relay.Close()
		return nil, err
	}
	// Forward relay -> WG only after the device is up. Starting this before the
	// fallible IpcSet/Up steps meant an early construction failure left the goroutine
	// blocked on Recv() forever and the relay leaked (the relay dials lazily, so its
	// Recv channel never closes on its own). close(inbound) fires when the relay is
	// closed, which unblocks the bind's receive fn.
	go func() {
		defer close(inbound)
		for dg := range cfg.Relay.Recv() {
			select {
			case inbound <- dg:
			default: // drop if WG is not draining fast enough
			}
		}
	}()
	return &WGWS{dev: dev, tnet: tnet, relay: cfg.Relay}, nil
}
```

3. Replace the body of `WaitReady` (keep its doc comment) with:

```go
func (w *WGWS) WaitReady(ctx context.Context) error {
	return waitHandshake(ctx, w.dev, w.relay.DialErr)
}
```

- [ ] **Step 5: Run the whole transport package**

Run: `cd android/core && go vet ./... && go test ./transport -v 2>&1 | tail -30`
Expected: all PASS, including the untouched `TestRelayBind*` and `TestWGWSWaitReady*` tests, plus the two new `TestUapiConfig*` tests.

- [ ] **Step 6: Commit**

```bash
git add android/core/transport/wg_device.go android/core/transport/wg_device_test.go android/core/transport/wgws.go
git commit -m "refactor(core): extract shared WireGuard device helpers from wgws"
```

---

### Task 3: `udpBind`, a `conn.Bind` over one connected UDP socket

**Files:**
- Create: `android/core/transport/wg.go` (bind only in this task)
- Test: `android/core/transport/wg_test.go` (new)

**Interfaces:**
- Produces: `func newUDPBind(c net.Conn) *udpBind`; `*udpBind` implements `conn.Bind`. Closing the bind does **not** close the socket (wireguard-go cycles Close/Open on `Up`); the owning transport closes the socket.

- [ ] **Step 1: Write the failing tests**

Create `android/core/transport/wg_test.go`:

```go
package transport

import (
	"errors"
	"net"
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd android/core && go test ./transport -run 'TestUDPBind' -v`
Expected: compile error, `newUDPBind` undefined.

- [ ] **Step 3: Implement the bind**

Create `android/core/transport/wg.go`:

```go
package transport

import (
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

// udpBind is a conn.Bind over a single, already-connected UDP socket. The socket is
// dialed by the caller through the VpnService-protected dialer, so WireGuard's own
// packets never loop back into the tunnel. Because the socket is connected, the
// endpoint wireguard-go passes to Send is cosmetic and ignored.
//
// Close does not close the socket: wireguard-go's BindUpdate always runs Close() then
// Open() on the same bind (even on the first Up), and waits for the receive goroutines
// to exit in between. Close therefore only has to unblock a pending Read, which it does
// with a read deadline; Open clears that deadline and starts a fresh generation.
type udpBind struct {
	conn net.Conn

	mu     sync.Mutex
	closed chan struct{}
}

func newUDPBind(c net.Conn) *udpBind {
	return &udpBind{conn: c, closed: make(chan struct{})}
}

func (b *udpBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	select {
	case <-b.closed:
		b.closed = make(chan struct{})
	default:
	}
	closed := b.closed
	b.mu.Unlock()
	_ = b.conn.SetReadDeadline(time.Time{})

	receive := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		for {
			n, err := b.conn.Read(packets[0])
			if err != nil {
				select {
				case <-closed:
					return 0, net.ErrClosed
				default:
				}
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() {
					continue // stale deadline from a previous generation
				}
				return 0, err
			}
			sizes[0] = n
			eps[0] = relayEndpoint{}
			return 1, nil
		}
	}
	return []conn.ReceiveFunc{receive}, port, nil
}

func (b *udpBind) Close() error {
	b.mu.Lock()
	select {
	case <-b.closed:
	default:
		close(b.closed)
	}
	b.mu.Unlock()
	// Wake a receive fn blocked in Read so it can observe the closed generation.
	return b.conn.SetReadDeadline(time.Now())
}

func (b *udpBind) SetMark(uint32) error { return nil }

func (b *udpBind) Send(bufs [][]byte, _ conn.Endpoint) error {
	for _, buf := range bufs {
		if _, err := b.conn.Write(buf); err != nil {
			return err
		}
	}
	return nil
}

func (b *udpBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	if err != nil {
		return relayEndpoint{}, nil // endpoint is ignored; tolerate anything
	}
	return relayEndpoint{dst: ap}, nil
}

func (b *udpBind) BatchSize() int { return 1 }
```

`relayEndpoint` is the existing stub endpoint type in `wgws.go`; both binds ignore endpoints, so it is reused rather than duplicated.

- [ ] **Step 4: Run the tests**

Run: `cd android/core && go test ./transport -run 'TestUDPBind' -v -count=3`
Expected: all PASS three times (guards against a flaky deadline race).

- [ ] **Step 5: Commit**

```bash
git add android/core/transport/wg.go android/core/transport/wg_test.go
git commit -m "feat(core): udpBind, a conn.Bind over one protected UDP socket"
```

---

### Task 4: `WG` transport with handshake-age watchdog, wired into the session

**Files:**
- Modify: `android/core/transport/wg.go` (append transport + watchdog)
- Modify: `android/core/session.go:296-380` (`buildTransport`)
- Test: `android/core/transport/wg_test.go` (append)

**Interfaces:**
- Consumes: `newWGDevice`, `waitHandshake`, `handshakeAge`, `WGConfig.Keepalive` (Task 2); `newUDPBind` (Task 3); `cfg.WG.Endpoint`, `cfg.WG.Keepalive` (Task 1).
- Produces: `func NewWG(ctx context.Context, cfg WGConfig, endpoint string, dial DialFunc, onState func(bool)) (*WG, error)`; `*WG` implements `Transport`. Package constants `watchdogTick = 5 * time.Second`, `handshakeStale = 180 * time.Second`. Test hook `runWatchdog(stop <-chan struct{}, tick, stale time.Duration, age func() (time.Duration, bool), onState func(bool))`.

- [ ] **Step 1: Write the failing tests**

Append to `android/core/transport/wg_test.go` (add `"context"`, `"net/netip"`, `"strings"`, `"sync"` to its imports):

```go
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd android/core && go test ./transport -run 'TestWatchdog|TestNewWG|TestWGWaitReady' -v`
Expected: compile error, `runWatchdog` / `NewWG` undefined.

- [ ] **Step 3: Implement the transport and watchdog**

Append to `android/core/transport/wg.go` (add `"context"`, `"fmt"`, `"golang.zx2c4.com/wireguard/device"`, `"golang.zx2c4.com/wireguard/tun/netstack"` to its imports):

```go
const (
	// watchdogTick is how often the watchdog samples the peer's handshake age.
	watchdogTick = 5 * time.Second
	// handshakeStale is the handshake age past which the server is considered
	// unreachable. With a 25 s persistent keepalive wireguard-go rekeys at least every
	// 2 minutes while packets flow, so 3 minutes of silence is a dead peer, not a
	// quiet one.
	handshakeStale = 180 * time.Second
)

// WG is plain UDP WireGuard over one protected socket. Unlike WGWS it has no carrier
// connection whose liveness can be observed, so a watchdog on the handshake age plays
// that role: it reports degraded when handshakes stop and running when they resume.
type WG struct {
	dev  *device.Device
	tnet *netstack.Net
	conn net.Conn

	stop     chan struct{}
	stopOnce sync.Once
}

// NewWG dials endpoint (host:port; a hostname resolves through dial, i.e. outside the
// tunnel) and builds the device with the socket's resolved remote address as the uapi
// endpoint. onState receives false when handshakes go stale and true when they resume;
// it never fires before the first handshake, which WaitReady owns.
func NewWG(ctx context.Context, cfg WGConfig, endpoint string, dial DialFunc, onState func(bool)) (*WG, error) {
	c, err := dial(ctx, "udp", endpoint)
	if err != nil {
		return nil, fmt.Errorf("wg dial %s: %w", endpoint, err)
	}
	dev, tnet, err := newWGDevice(cfg, newUDPBind(c), c.RemoteAddr().String())
	if err != nil {
		c.Close()
		return nil, err
	}
	w := &WG{dev: dev, tnet: tnet, conn: c, stop: make(chan struct{})}
	go runWatchdog(w.stop, watchdogTick, handshakeStale,
		func() (time.Duration, bool) { return handshakeAge(dev, time.Now()) }, onState)
	return w, nil
}

// runWatchdog samples age every tick and calls onState on each transition between
// fresh (age <= stale) and stale. It starts in the "up" state and ignores samples
// taken before the first handshake, so it cannot fire during the connect phase.
func runWatchdog(stop <-chan struct{}, tick, stale time.Duration, age func() (time.Duration, bool), onState func(bool)) {
	t := time.NewTicker(tick)
	defer t.Stop()
	up := true
	for {
		select {
		case <-stop:
			return
		case <-t.C:
		}
		a, ok := age()
		if !ok {
			continue
		}
		fresh := a <= stale
		if fresh == up {
			continue
		}
		up = fresh
		if onState != nil {
			onState(fresh)
		}
	}
}

// WaitReady blocks until the first handshake or ctx is done. A UDP dial to an
// unreachable network already failed in NewWG, so there is no carrier error to
// short-circuit on here; a silent server runs to the caller's deadline.
func (w *WG) WaitReady(ctx context.Context) error {
	return waitHandshake(ctx, w.dev, nil)
}

func (w *WG) DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	return w.tnet.DialContextTCPAddrPort(ctx, dst)
}

func (w *WG) DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error) {
	return w.tnet.DialUDPAddrPort(netip.AddrPort{}, dst)
}

func (w *WG) Close() error {
	w.stopOnce.Do(func() { close(w.stop) })
	w.dev.Close()
	return w.conn.Close()
}
```

- [ ] **Step 4: Run the transport tests**

Run: `cd android/core && go test ./transport -v -count=2 2>&1 | tail -40`
Expected: all PASS twice.

- [ ] **Step 5: Wire `buildTransport`**

In `android/core/session.go`, inside `buildTransport`'s `switch cfg.Transport`, add before the `default:` case:

```go
	case "wg":
		Logf("connect: wg dial %s", cfg.WG.Endpoint)
		locals, err := parseAddrs(cfg.WG.LocalAddrs)
		if err != nil {
			return nil, fmt.Errorf("wg localAddrs: %w", err)
		}
		dns, err := parseAddrs(cfg.WG.DNS)
		if err != nil {
			return nil, fmt.Errorf("wg dns: %w", err)
		}
		return transport.NewWG(ctx, transport.WGConfig{
			PrivateKey:       cfg.WG.PrivateKey,
			PeerPublicKey:    cfg.WG.PeerPublicKey,
			PeerPresharedKey: cfg.WG.PeerPresharedKey,
			LocalAddrs:       locals,
			DNS:              dns,
			MTU:              cfg.WG.MTU,
			Keepalive:        cfg.WG.Keepalive,
		}, cfg.WG.Endpoint, transport.DialFunc(dial), func(connected bool) {
			// Same contract as the wgws carrier: the service treats a repeated
			// "running" after "degraded" as a reconnect.
			logCarrier("wg", connected)
			if sink == nil {
				return
			}
			if connected {
				sink.OnState("running")
			} else {
				sink.OnState("degraded")
			}
		})
```

- [ ] **Step 6: Build and run everything**

Run: `cd android/core && go vet ./... && go test ./... 2>&1 | tail -8`
Expected: `ok` for `core`, `core/transport`, `core/wstunnel`.

- [ ] **Step 7: Commit**

```bash
git add android/core/transport/wg.go android/core/transport/wg_test.go android/core/session.go
git commit -m "feat(core): plain UDP WireGuard transport with a handshake-age watchdog"
```

---

### Task 5: Kotlin profile model, core-config JSON, and QR import

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/profile/Profile.kt`
- Modify: `android/app/src/main/java/tunnelbahn/app/profile/QRImport.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/profile/QRImportTest.kt` (append)
- Test: `android/app/src/test/java/tunnelbahn/app/profile/ProfileCoreConfigTest.kt` (new)

**Interfaces:**
- Produces: `Transport.WG`; `Profile.wgEndpoint: String = ""`, `Profile.wgKeepalive: Int = 25`; `fun Profile.displayEndpoint(): String`; `toCoreConfigJson()` emits `"transport":"wg"` plus `"endpoint"`/`"keepalive"` in the `wg` block.

- [ ] **Step 1: Write the failing tests**

Append to `QRImportTest.kt`:

```kotlin
    @Test fun plain_wg_payload_maps_endpoint_and_keepalive() {
        val raw = """
            {"kind":"tunnelbahn.profile","name":"AWS","transport":"wg",
             "wg":{"privateKey":"pk","peerPublicKey":"peer","presharedKey":"",
                   "localAddrs":["10.9.0.2"],"dns":["1.1.1.1"],"mtu":1280,
                   "endpoint":"3.139.146.5:51820","keepalive":15}}
        """.trimIndent()
        val p = (parseImportedProfile(raw, id) as QRImportResult.Ok).profile
        assertEquals(Transport.WG, p.transport)
        assertEquals("3.139.146.5:51820", p.wgEndpoint)
        assertEquals(15, p.wgKeepalive)
        assertEquals("pk", p.wgPrivateKey)
        assertEquals("peer", p.wgPeerPublicKey)
        assertEquals(listOf("10.9.0.2"), p.wgLocalAddrs)
        assertEquals("", p.wsUrl)
    }

    @Test fun plain_wg_payload_defaults_keepalive_to_25() {
        val raw = """
            {"kind":"tunnelbahn.profile","name":"AWS","transport":"wg",
             "wg":{"privateKey":"pk","peerPublicKey":"peer","endpoint":"1.2.3.4:51820"}}
        """.trimIndent()
        val p = (parseImportedProfile(raw, id) as QRImportResult.Ok).profile
        assertEquals(25, p.wgKeepalive)
    }

    @Test fun plain_wg_payload_without_endpoint_is_rejected() {
        val raw = """
            {"kind":"tunnelbahn.profile","name":"AWS","transport":"wg",
             "wg":{"privateKey":"pk","peerPublicKey":"peer","endpoint":""}}
        """.trimIndent()
        assertTrue(parseImportedProfile(raw, id) is QRImportResult.Error)
    }
```

Create `ProfileCoreConfigTest.kt`:

```kotlin
package tunnelbahn.app.profile

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class ProfileCoreConfigTest {
    private fun wgProfile() = Profile(
        id = "p1", name = "AWS", transport = Transport.WG,
        wgPrivateKey = "pk", wgPeerPublicKey = "peer",
        wgLocalAddrs = listOf("10.9.0.2"), wgDns = listOf("1.1.1.1"),
        wgEndpoint = "3.139.146.5:51820", wgKeepalive = 15,
    )

    @Test fun plain_wg_emits_wg_transport_with_endpoint_and_keepalive() {
        val obj = Json.parseToJsonElement(wgProfile().toCoreConfigJson()).jsonObject
        assertEquals("wg", obj["transport"]!!.jsonPrimitive.content)
        val wg = obj["wg"]!!.jsonObject
        assertEquals("3.139.146.5:51820", wg["endpoint"]!!.jsonPrimitive.content)
        assertEquals("15", wg["keepalive"]!!.jsonPrimitive.content)
    }

    @Test fun wgws_still_emits_wgws_transport() {
        val obj = Json.parseToJsonElement(wgProfile().copy(transport = Transport.WGWS).toCoreConfigJson()).jsonObject
        assertEquals("wgws", obj["transport"]!!.jsonPrimitive.content)
    }

    @Test fun display_endpoint_follows_transport() {
        val p = wgProfile().copy(endpoint = "ssh:22", wsUrl = "wss://x/events")
        assertEquals("3.139.146.5:51820", p.displayEndpoint())
        assertEquals("ssh:22", p.copy(transport = Transport.SSH).displayEndpoint())
        assertEquals("wss://x/events", p.copy(transport = Transport.WGWS).displayEndpoint())
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd android && ./gradlew --offline :app:testDebugUnitTest --tests 'tunnelbahn.app.profile.*' 2>&1 | tail -20`
Expected: compilation FAILS (`Transport.WG`, `wgEndpoint` unresolved).

- [ ] **Step 3: Implement in `Profile.kt`**

Change the enum:

```kotlin
/** SSH flow forwarding; WireGuard over a wstunnel WebSocket; plain UDP WireGuard. */
enum class Transport { SSH, WGWS, WG }
```

Add two fields after `wsForwardPort` in `Profile`:

```kotlin
    // Plain UDP WireGuard (Transport.WG)
    val wgEndpoint: String = "",          // host:port of the WG peer
    val wgKeepalive: Int = 25,            // persistent keepalive seconds
```

Add after `appScopeSummary()`:

```kotlin
/** The server address to show for this profile, whichever transport it uses. */
fun Profile.displayEndpoint(): String = when (transport) {
    Transport.SSH -> endpoint
    Transport.WG -> wgEndpoint
    Transport.WGWS -> wsUrl
}
```

In `toCoreConfigJson()` replace the transport line:

```kotlin
        put(
            "transport",
            when (transport) {
                Transport.SSH -> "ssh"
                Transport.WGWS -> "wgws"
                Transport.WG -> "wg"
            },
        )
```

In `wgBlock()` add after `forwardPort`:

```kotlin
    put("endpoint", wgEndpoint)
    put("keepalive", wgKeepalive)
```

- [ ] **Step 4: Implement in `QRImport.kt`**

Extend `QRWg`:

```kotlin
@Serializable
private data class QRWg(
    val privateKey: String = "",
    val peerPublicKey: String = "",
    val presharedKey: String = "",
    val localAddrs: List<String> = emptyList(),
    val dns: List<String> = emptyList(),
    val mtu: Int = 1280,
    val wsURL: String = "",
    val forwardHost: String = "",
    val forwardPort: Int = 0,
    val endpoint: String = "",
    val keepalive: Int = 25,
)
```

Add a `"wg"` branch to the `when (payload.transport)` before `else`:

```kotlin
        "wg" -> {
            val w = payload.wg ?: return QRImportResult.Error("QR is missing WireGuard details.")
            if (w.endpoint.isBlank()) return QRImportResult.Error("QR is missing the WireGuard endpoint.")
            QRImportResult.Ok(
                Profile(
                    id = newId,
                    name = payload.name,
                    transport = Transport.WG,
                    wgPrivateKey = w.privateKey,
                    wgPeerPublicKey = w.peerPublicKey,
                    wgPresharedKey = w.presharedKey,
                    wgLocalAddrs = w.localAddrs,
                    wgDns = w.dns,
                    wgMtu = w.mtu,
                    wgEndpoint = w.endpoint,
                    wgKeepalive = w.keepalive,
                )
            )
        }
```

- [ ] **Step 5: Run the tests**

Run: `cd android && ./gradlew --offline :app:testDebugUnitTest --tests 'tunnelbahn.app.profile.*' 2>&1 | tail -20`
Expected: BUILD SUCCESSFUL, all profile tests pass. (Compilation will also flag any other exhaustive `when (transport)` in the app; there are none today, but fix any it reports.)

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/profile/Profile.kt android/app/src/main/java/tunnelbahn/app/profile/QRImport.kt android/app/src/test/java/tunnelbahn/app/profile/QRImportTest.kt android/app/src/test/java/tunnelbahn/app/profile/ProfileCoreConfigTest.kt
git commit -m "feat(android): plain WireGuard profile model and QR import"
```

---

### Task 6: Android editor and list UI

No unit tests exist for Compose screens in this project; verification is compile + a manual check on the phone (final task).

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/ProfileEditor.kt:117-135` (transport radios), `:236-266` (`WgFields`)
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/MainScreen.kt:216`

**Interfaces:**
- Consumes: `Transport.WG`, `Profile.wgEndpoint`, `Profile.displayEndpoint()` (Task 5).

- [ ] **Step 1: Replace the transport row in `ProfileEditor`**

```kotlin
            Text("Transport")
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(
                    selected = draft.transport == Transport.SSH,
                    onClick = { draft = draft.copy(transport = Transport.SSH) },
                )
                Text("SSH", Modifier.padding(end = 12.dp))
                RadioButton(
                    selected = draft.transport == Transport.WG,
                    onClick = { draft = draft.copy(transport = Transport.WG) },
                )
                Text("WireGuard", Modifier.padding(end = 12.dp))
                RadioButton(
                    selected = draft.transport == Transport.WGWS,
                    onClick = { draft = draft.copy(transport = Transport.WGWS) },
                )
                Text("WG over TCP")
            }

            if (draft.transport == Transport.SSH) {
                SshFields(draft) { draft = it }
            } else {
                WgFields(draft) { draft = it }
            }
```

- [ ] **Step 2: Make `WgFields` show the right address field**

Replace the first `OutlinedTextField` in `WgFields` with:

```kotlin
    if (draft.transport == Transport.WG) {
        OutlinedTextField(
            value = draft.wgEndpoint,
            onValueChange = { update(draft.copy(wgEndpoint = it)) },
            label = { Text("WireGuard endpoint (host:port)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
    } else {
        OutlinedTextField(
            value = draft.wsUrl,
            onValueChange = { update(draft.copy(wsUrl = it)) },
            label = { Text("wstunnel URL (wss://host/path/events)") },
            modifier = Modifier.fillMaxWidth(),
        )
    }
```

- [ ] **Step 3: Fix the list subtitle in `MainScreen.kt`**

Line 216 currently reads:

```kotlin
                "${profile.transport} · ${profile.endpoint.ifEmpty { profile.wsUrl }}",
```

Replace with:

```kotlin
                "${profile.transport} · ${profile.displayEndpoint()}",
```

and add `import tunnelbahn.app.profile.displayEndpoint` to that file's imports.

- [ ] **Step 4: Compile**

Run: `cd android && ./gradlew --offline :app:compileDebugKotlin 2>&1 | tail -15`
Expected: BUILD SUCCESSFUL, no warnings about non-exhaustive `when`.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/ProfileEditor.kt android/app/src/main/java/tunnelbahn/app/ui/MainScreen.kt
git commit -m "feat(android): WireGuard transport in the profile editor and list"
```

---

### Task 7: macOS QR encoder exports plain WireGuard, panel text wraps, spec note

**Files:**
- Modify: `TunnelBahn/Services/AndroidProfileQRCodec.swift:14-80`
- Modify: `TunnelBahn/Views/ProfilesView.swift:658-670` (error / too-large texts)
- Modify: `docs/superpowers/specs/2026-08-02-android-client-design.md:27-28`
- Test: `Tests/Unit/AndroidProfileQRCodecTests.swift`

**Interfaces:**
- Produces: JSON `"transport":"wg"` with `wg.endpoint` and `wg.keepalive`; `AndroidProfileQRError.noPeerEndpoint` replaces `.noAndroidTransport`.

- [ ] **Step 1: Update the tests**

In `Tests/Unit/AndroidProfileQRCodecTests.swift`, extend `makeWGProfile` with a keepalive parameter and an endpoint parameter:

```swift
    private func makeWGProfile(
        serverHost: String = "1.2.3.4", serverPort: UInt16 = 443, tls: Bool = true,
        pathPrefix: String = "tun", forwardHost: String = "127.0.0.1", forwardPort: UInt16 = 51840,
        wrapper hasWrapper: Bool = true,
        endpoint: String = "127.0.0.1:51840", keepalive: Int? = nil
    ) -> WireGuardProfile {
        let wrapper = hasWrapper ? WireGuardTCPWrapper(
            serverHost: serverHost, serverPort: serverPort, tls: tls, verifyCert: false,
            pathPrefix: pathPrefix, forwardHost: forwardHost, forwardPort: forwardPort
        ) : nil
        return WireGuardProfile(
            name: "wg-profile",
            interface: WireGuardInterface(privateKeyRef: "wg-ref", addresses: ["10.9.0.2/32"], dnsServers: ["1.1.1.1"], mtu: 1280),
            peers: [WireGuardPeer(publicKey: "peerpub", endpoint: endpoint, allowedIPs: ["0.0.0.0/0"], persistentKeepalive: keepalive)],
            tcpWrapper: wrapper
        )
    }
```

Replace `testPlainWireGuardWithoutWrapperThrows` with:

```swift
    func testPlainWireGuardEncodesAsWGWithEndpointAndKeepalive() throws {
        let profile = makeWGProfile(wrapper: false, endpoint: "3.139.146.5:51820", keepalive: 15)
        let json = try AndroidProfileQRCodec.encode(profile, secrets: fakeKeychain)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["transport"] as? String, "wg")
        let wg = obj["wg"] as! [String: Any]
        XCTAssertEqual(wg["endpoint"] as? String, "3.139.146.5:51820")
        XCTAssertEqual(wg["keepalive"] as? Int, 15)
        XCTAssertEqual(wg["privateKey"] as? String, "wgpriv")
        XCTAssertEqual(wg["peerPublicKey"] as? String, "peerpub")
        XCTAssertEqual(wg["localAddrs"] as? [String], ["10.9.0.2"])
        XCTAssertNil(wg["wsURL"])
        XCTAssertNil(wg["forwardHost"])
        XCTAssertNil(wg["forwardPort"])
    }

    func testPlainWireGuardDefaultsKeepaliveTo25() throws {
        let profile = makeWGProfile(wrapper: false)
        let json = try AndroidProfileQRCodec.encode(profile, secrets: fakeKeychain)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual((obj["wg"] as! [String: Any])["keepalive"] as? Int, 25)
    }

    func testWrapperEnabledStillEncodesAsWGWS() throws {
        let json = try AndroidProfileQRCodec.encode(makeWGProfile(wrapper: true), secrets: fakeKeychain)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["transport"] as? String, "wgws")
        XCTAssertNil((obj["wg"] as! [String: Any])["endpoint"])
    }

    func testPlainWireGuardWithEmptyEndpointThrows() {
        let profile = makeWGProfile(wrapper: false, endpoint: "  ")
        XCTAssertThrowsError(try AndroidProfileQRCodec.encode(profile, secrets: fakeKeychain)) { error in
            guard case AndroidProfileQRError.noPeerEndpoint = error else {
                return XCTFail("want noPeerEndpoint, got \(error)")
            }
        }
    }
```

- [ ] **Step 2: Implement the codec change**

In `TunnelBahn/Services/AndroidProfileQRCodec.swift`, replace the `WG` payload struct:

```swift
    struct WG: Encodable {
        let privateKey, peerPublicKey, presharedKey: String
        let localAddrs, dns: [String]
        let mtu: Int
        // "wgws" only. Optionals are omitted from the JSON when nil.
        let wsURL, forwardHost: String?
        let forwardPort: Int?
        // "wg" only.
        let endpoint: String?
        let keepalive: Int?
    }
```

Replace the error enum:

```swift
enum AndroidProfileQRError: LocalizedError {
    case noPeerEndpoint
    case missingSecret(String)

    var errorDescription: String? {
        switch self {
        case .noPeerEndpoint: return "This profile has no peer endpoint to export."
        case .missingSecret(let s): return "Missing key material: \(s)."
        }
    }
}
```

Replace the body of `encode` from `let payload` through the `else { throw ... }` with:

```swift
        let payload: AndroidProfileQRPayload
        if profile.transport == .ssh, let ssh = profile.ssh {
            let pem = try secrets.read(account: ssh.privateKeyRef)
            payload = AndroidProfileQRPayload(
                name: profile.name, transport: "ssh",
                ssh: .init(addr: "\(ssh.host):\(ssh.port)", user: ssh.username, privateKeyPEM: pem),
                wg: nil
            )
        } else if let peer = profile.peers.first {
            let priv = try secrets.read(account: profile.interface.privateKeyRef)
            let psk = try peer.presharedKeyRef.map { try secrets.read(account: $0) } ?? ""
            // Android's core parses these with netip.ParseAddr (bare IPs, no prefix), so
            // strip the CIDR suffix the macOS interface stores (e.g. "10.9.0.2/32").
            let localAddrs = profile.interface.addresses.map(Self.stripPrefix)
            let dns = profile.interface.dnsServers.map(Self.stripPrefix)
            let mtu = profile.interface.mtu ?? 1280
            if let w = profile.tcpWrapper, w.enabled {
                let scheme = w.tls ? "wss" : "ws"
                payload = AndroidProfileQRPayload(
                    name: profile.name, transport: "wgws", ssh: nil,
                    wg: .init(
                        privateKey: priv, peerPublicKey: peer.publicKey, presharedKey: psk,
                        localAddrs: localAddrs, dns: dns, mtu: mtu,
                        wsURL: "\(scheme)://\(w.serverHost):\(w.serverPort)/\(w.pathPrefix)/events",
                        forwardHost: w.forwardHost, forwardPort: Int(w.forwardPort),
                        endpoint: nil, keepalive: nil
                    )
                )
            } else {
                let endpoint = peer.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !endpoint.isEmpty else { throw AndroidProfileQRError.noPeerEndpoint }
                payload = AndroidProfileQRPayload(
                    name: profile.name, transport: "wg", ssh: nil,
                    wg: .init(
                        privateKey: priv, peerPublicKey: peer.publicKey, presharedKey: psk,
                        localAddrs: localAddrs, dns: dns, mtu: mtu,
                        wsURL: nil, forwardHost: nil, forwardPort: nil,
                        endpoint: endpoint, keepalive: peer.persistentKeepalive ?? 25
                    )
                )
            }
        } else {
            throw AndroidProfileQRError.noPeerEndpoint
        }
```

Update the doc comment above `encode` to: `/// Encodes [profile] as the compact JSON Android scans. SSH profiles map to "ssh"; a WG profile with an enabled TCP wrapper maps to "wgws"; any other WG profile maps to plain "wg" using the peer's endpoint. Reads key material through [secrets].`

- [ ] **Step 3: Make the panel's message texts wrap**

In `TunnelBahn/Views/ProfilesView.swift`, `showAndroidQRPanel`, change the two fallback texts:

```swift
            } else {
                content = AnyView(
                    Text("Profile is too large to encode as a QR code.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 240)
                        .foregroundStyle(.secondary)
                        .padding(16)
                )
            }
        } catch {
            content = AnyView(
                Text(error.localizedDescription)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240)
                    .foregroundStyle(.secondary)
                    .padding(16)
            )
        }
```

Grep for any other use of `noAndroidTransport` in the repo (`grep -rn noAndroidTransport TunnelBahn Tests`) and update it; today only the codec and its test use it.

- [ ] **Step 4: Add the spec note**

In `docs/superpowers/specs/2026-08-02-android-client-design.md`, directly after the paragraph ending "the WG transport always rides inside the wstunnel TLS/WebSocket layer.", add:

```markdown
> **Update 2026-09-16:** relaxed. Plain WireGuard is only sometimes blocked on the target network and is the fastest path when it gets through, so the app now also offers an unwrapped `wg` transport chosen per profile. See `2026-09-16-android-plain-wireguard-design.md`.
```

- [ ] **Step 5: Run the Swift tests (ask first)**

Tell the user the command and wait for approval, per the project rule that `xcodebuild` slows their machine:

```
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/AndroidProfileQRCodecTests 2>&1 | tail -30
```

Expected once run: `** TEST SUCCEEDED **` with the six codec tests passing. The unit-test target is `TunnelBahnUnitTests` per `project.yml`.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Services/AndroidProfileQRCodec.swift TunnelBahn/Views/ProfilesView.swift Tests/Unit/AndroidProfileQRCodecTests.swift docs/superpowers/specs/2026-08-02-android-client-design.md
git commit -m "feat(macos): export plain WireGuard profiles to Android as wg"
```

---

### Task 8: Rebuild the core AAR and verify on device

**Files:** none modified. Uses `android/build-core.sh` and the Gradle debug build.

- [ ] **Step 1: Rebuild the gomobile AAR**

Run: `cd android && ./build-core.sh 2>&1 | tail -10`
Expected: the AAR is regenerated without errors. This step needs the NDK and JDK the script documents; if it fails on a missing tool, report the exact error to the user instead of installing SDK components.

- [ ] **Step 2: Build the debug APK**

Run: `cd android && ./gradlew --offline :app:assembleDebug 2>&1 | tail -10`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Hand off the manual check to the user**

Report to the user, in this order, what to do on the phone:

1. Install the debug APK, open the macOS app, right-click the AWS profile, choose "Export to Android (QR)", and scan it. The profile should import with transport WG and the AWS endpoint shown in the list.
2. Connect. The UI should reach Connected and the exit-IP check should show the AWS address.
3. Stop WireGuard on the server (or block UDP to it) for four minutes. The UI should switch to Reconnecting after roughly three minutes, then back to Connected within a minute of restoring the server.
4. Open a new profile in the editor and confirm three transport radios appear and the WireGuard one shows an endpoint field.

Nothing to commit in this task.

---

## Self-review

**Spec coverage.**
- Config `wg` + endpoint/keepalive: Task 1. Extraction and `Keepalive`: Task 2. `udpBind`: Task 3. `NewWG`, watchdog, `WaitReady`, `session.go`: Task 4. Kotlin model, JSON, QR import: Task 5. Editor and list: Task 6. macOS codec, wrapper preference, `noPeerEndpoint`, panel truncation, spec note: Task 7. Manual verification: Task 8.
- The spec's `uapiConfig(cfg, endpoint, keepalive)` is implemented as `uapiConfig(cfg, endpoint)` reading `cfg.Keepalive`; same behaviour, one fewer argument. The spec's `newWGWithClock` hook is realised as the standalone `runWatchdog` function, which is simpler to test.

**Placeholders.** None: every step has its code or exact command.

**Type consistency.** `WGConfig.Keepalive` (Task 2) is read by `uapiConfig` (Task 2) and set in `session.go` (Task 4). `newUDPBind(net.Conn)` (Task 3) is called in `NewWG` (Task 4). `handshakeAge(dev, now)` returns `(time.Duration, bool)` matching the watchdog's `age func() (time.Duration, bool)`. Kotlin `wgEndpoint`/`wgKeepalive`/`displayEndpoint()` (Task 5) are used in Task 6. Swift `WG` init argument order (`wsURL, forwardHost, forwardPort, endpoint, keepalive`) matches the struct's declaration order in Task 7.

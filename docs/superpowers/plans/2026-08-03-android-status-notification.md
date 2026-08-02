# Android Status Notification (speed + exit location) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live download/upload speed (tunneled traffic only) and the exit-IP location (country + city) in the ongoing foreground-service notification.

**Architecture:** The Go core counts inner-payload bytes on the tunnel-branch conns of `coreProxy` and exposes cumulative totals via a pull API; it also probes `ipinfo.io` once per session *through the transport* and pushes the result up a new `EventSink.OnExitInfo` callback. Kotlin polls the byte totals every second, computes per-second deltas, and re-posts the notification; it requests `POST_NOTIFICATIONS` at runtime so the notification is visible on Android 13+.

**Tech Stack:** Go 1.x (`tunnelbahn/core`, gomobile bind), Kotlin + Jetpack Compose, Android `VpnService`, JUnit4 (Kotlin unit tests), Go stdlib `testing`.

## Global Constraints

- **No legacy/compat shims.** App is undistributed; no schemaVersion fields, no migrations. (Recorded policy.)
- **The exit-IP probe MUST egress through `transport.Transport.DialTCP`**, never a Kotlin HTTP client — a probe from the app's own package bypasses the VPN. (Recorded false-PASS pitfall.)
- **Speeds are tunneled-traffic-only, inner-payload goodput** — count only `coreProxy` tunnel-branch conns; do not count DNS-over-TCP, bypass, or the probe itself.
- **UI copy rule:** no em dashes; keep tooltips/notification lines short; middle-dot (`·`) separators.
- **gomobile surface:** only strings and primitive types cross the boundary; unsigned types are not bound (use `int64` for byte counts).
- **Go module:** `tunnelbahn/core` (dir `android/core`). Go tests: `cd android/core && go test ./...`. AAR rebuild after any change to `./mobile` or the `EventSink`/`Session` surface: `cd android && ./build-core.sh`. Kotlin unit tests: `cd android && ./gradlew testDebugUnitTest`.

---

## File Structure

**Go core (`android/core/`):**
- Create `counters.go` — atomic byte counters + counting `net.Conn` / `net.PacketConn` wrappers.
- Create `counters_test.go` — direction + tally tests.
- Create `exitprobe.go` — `parseIPInfo` + `runExitProbe` (ipinfo GET over the transport).
- Create `exitprobe_test.go` — `parseIPInfo` + cancellation tests.
- Modify `engine.go` — `coreProxy` holds `*counters`; wrap tunnel-branch TCP + UDP conns.
- Modify `session.go` — `Session` holds `*counters`; add `RxBytes()/TxBytes()`; add `OnExitInfo` to `EventSink`; launch the probe on `running`, cancel it on Stop.
- Modify `mobile/mobile.go` — add `OnExitInfo` to the bound `EventSink` + adapter; add `RxBytes()/TxBytes()` to the bound `Session`.

**Kotlin app (`android/app/src/main/java/tunnelbahn/app/`):**
- Create `ui/SpeedFormat.kt` — pure `humanizeSpeed`, `bytesPerSecond`, `formatLocation`.
- Create `../test/.../ui/SpeedFormatTest.kt` — unit tests for the three pure functions.
- Modify `vpn/TunnelBahnVpnService.kt` — exit-info flows, 1s poller, dynamic notification, `Sink.onExitInfo`.
- Modify `ui/HomeScreen.kt` — request `POST_NOTIFICATIONS` (API 33+) + denied hint.

---

## Task 1: Go byte counters

**Files:**
- Create: `android/core/counters.go`
- Test: `android/core/counters_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `type counters struct { rx, tx atomic.Uint64 }`
  - `func (c *counters) Rx() int64` / `func (c *counters) Tx() int64`
  - `func (c *counters) wrapConn(net.Conn) net.Conn` — Read adds to rx, Write adds to tx.
  - `func (c *counters) wrapPacketConn(net.PacketConn) net.PacketConn` — ReadFrom adds to rx, WriteTo adds to tx.

- [ ] **Step 1: Write the failing test**

```go
package core

import (
	"net"
	"testing"
)

func TestCountingConnTalliesBothDirections(t *testing.T) {
	c := &counters{}
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	wrapped := c.wrapConn(client)

	go func() {
		buf := make([]byte, 8)
		server.Read(buf)   // drains the client's Write
		server.Write([]byte("world")) // 5 bytes back to the client
	}()

	if _, err := wrapped.Write([]byte("hi!")); err != nil { // 3 bytes TX
		t.Fatalf("write: %v", err)
	}
	buf := make([]byte, 5)
	if _, err := wrapped.Read(buf); err != nil { // 5 bytes RX
		t.Fatalf("read: %v", err)
	}

	if got := c.Tx(); got != 3 {
		t.Fatalf("tx: want 3, got %d", got)
	}
	if got := c.Rx(); got != 5 {
		t.Fatalf("rx: want 5, got %d", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test ./ -run TestCountingConn -v`
Expected: FAIL (build error: `counters` undefined).

- [ ] **Step 3: Write minimal implementation**

```go
package core

import (
	"net"
	"sync/atomic"
)

// counters accumulates tunneled inner-payload bytes for the status notification.
// Rx is server->app (download); Tx is app->server (upload). One instance per session.
type counters struct {
	rx atomic.Uint64
	tx atomic.Uint64
}

func (c *counters) Rx() int64 { return int64(c.rx.Load()) }
func (c *counters) Tx() int64 { return int64(c.tx.Load()) }

// wrapConn counts a coreProxy tunnel-branch TCP conn. On the proxy conn,
// Write is app->server (TX) and Read is server->app (RX).
func (c *counters) wrapConn(inner net.Conn) net.Conn {
	return &countingConn{Conn: inner, c: c}
}

type countingConn struct {
	net.Conn
	c *counters
}

func (cc *countingConn) Read(p []byte) (int, error) {
	n, err := cc.Conn.Read(p)
	if n > 0 {
		cc.c.rx.Add(uint64(n))
	}
	return n, err
}

func (cc *countingConn) Write(p []byte) (int, error) {
	n, err := cc.Conn.Write(p)
	if n > 0 {
		cc.c.tx.Add(uint64(n))
	}
	return n, err
}

// wrapPacketConn counts a coreProxy tunnel-branch UDP conn. WriteTo is TX, ReadFrom is RX.
func (c *counters) wrapPacketConn(inner net.PacketConn) net.PacketConn {
	return &countingPacketConn{PacketConn: inner, c: c}
}

type countingPacketConn struct {
	net.PacketConn
	c *counters
}

func (cp *countingPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, addr, err := cp.PacketConn.ReadFrom(p)
	if n > 0 {
		cp.c.rx.Add(uint64(n))
	}
	return n, addr, err
}

func (cp *countingPacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	n, err := cp.PacketConn.WriteTo(p, addr)
	if n > 0 {
		cp.c.tx.Add(uint64(n))
	}
	return n, err
}
```

- [ ] **Step 4: Add the UDP-direction test and run both**

Append to `counters_test.go`:

```go
type fakePacketConn struct {
	net.PacketConn
	readData []byte
}

func (f *fakePacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	return copy(p, f.readData), &net.UDPAddr{}, nil
}
func (f *fakePacketConn) WriteTo(p []byte, _ net.Addr) (int, error) { return len(p), nil }

func TestCountingPacketConnTalliesBothDirections(t *testing.T) {
	c := &counters{}
	wrapped := c.wrapPacketConn(&fakePacketConn{readData: []byte("abcd")}) // 4 RX
	if _, err := wrapped.WriteTo([]byte("xyz"), &net.UDPAddr{}); err != nil { // 3 TX
		t.Fatalf("writeto: %v", err)
	}
	buf := make([]byte, 16)
	wrapped.ReadFrom(buf)
	if got := c.Tx(); got != 3 {
		t.Fatalf("tx: want 3, got %d", got)
	}
	if got := c.Rx(); got != 4 {
		t.Fatalf("rx: want 4, got %d", got)
	}
}
```

Run: `cd android/core && go test ./ -run TestCounting -v`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add android/core/counters.go android/core/counters_test.go
git commit -m "feat(core): tunneled-byte counters for status notification"
```

---

## Task 2: Wire counters into coreProxy and the Session pull API

**Files:**
- Modify: `android/core/engine.go` (coreProxy struct + `newCoreProxy` + `DialContext` + `DialUDP`)
- Modify: `android/core/session.go` (`Session` struct, `Start`, add `RxBytes()/TxBytes()`)
- Modify: `android/core/mobile/mobile.go` (add `RxBytes()/TxBytes()` to bound `Session`)
- Test: `android/core/engine_test.go` (append a counter-wiring test)

**Interfaces:**
- Consumes: `counters` (Task 1); `transport.Transport` (`DialTCP(ctx, netip.AddrPort) (net.Conn, error)`, `DialUDP`).
- Produces:
  - `func newCoreProxy(disp *dispatcher, tr transport.Transport, resolver netip.AddrPort, prot Protector, ctr *counters) *coreProxy`
  - `func (s *Session) RxBytes() int64` / `func (s *Session) TxBytes() int64` on both `core.Session` and `mobile.Session`.

- [ ] **Step 1: Write the failing test**

Append to `android/core/engine_test.go` (add imports `context`, `net`, `net/netip`, `testing` as needed):

```go
// fakeTunnelTransport tunnels every DialTCP to an in-memory echo pipe so the test can
// drive bytes through coreProxy's tunnel branch and assert the counters moved.
type fakeTunnelTransport struct{ peer net.Conn }

func (f *fakeTunnelTransport) DialTCP(_ context.Context, _ netip.AddrPort) (net.Conn, error) {
	client, server := net.Pipe()
	f.peer = server
	return client, nil
}
func (f *fakeTunnelTransport) DialUDP(_ context.Context, _ netip.AddrPort) (net.PacketConn, error) {
	return nil, transport.ErrUnsupportedProtocol
}
func (f *fakeTunnelTransport) Close() error { return nil }

func TestCoreProxyCountsTunneledTCP(t *testing.T) {
	// Router in exclude mode with an empty set => every dst is Tunnel.
	disp := newDispatcher(NewRouter(ModeExclude, RuleSet{}), netip.Addr{})
	ctr := &counters{}
	tr := &fakeTunnelTransport{}
	p := newCoreProxy(disp, tr, netip.AddrPort{}, nil, ctr)

	m := &M.Metadata{DstIP: netip.MustParseAddr("93.184.216.34"), DstPort: 443}
	conn, err := p.DialContext(context.Background(), m)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	go func() {
		buf := make([]byte, 8)
		tr.peer.Read(buf)
		tr.peer.Write([]byte("resp"))
	}()
	conn.Write([]byte("get")) // 3 TX
	buf := make([]byte, 4)
	conn.Read(buf) // 4 RX

	if ctr.Tx() != 3 || ctr.Rx() != 4 {
		t.Fatalf("counters: tx=%d rx=%d, want tx=3 rx=4", ctr.Tx(), ctr.Rx())
	}
}
```

Note: confirm `M.Metadata`'s field/constructor shape against the existing `engine_test.go` / `metadata` import; if `DstIP/DstPort` differ, use the same construction the existing tests use (grep `M.Metadata` in the test file first).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test ./ -run TestCoreProxyCountsTunneledTCP -v`
Expected: FAIL (`newCoreProxy` takes 4 args, not 5).

- [ ] **Step 3: Modify `coreProxy` to hold and apply counters**

In `engine.go`, add `ctr *counters` to the `coreProxy` struct and to `newCoreProxy`:

```go
type coreProxy struct {
	disp     *dispatcher
	tr       transport.Transport
	resolver netip.AddrPort
	dialer   *net.Dialer
	listen   *net.ListenConfig
	ctr      *counters
}

func newCoreProxy(disp *dispatcher, tr transport.Transport, resolver netip.AddrPort, prot Protector, ctr *counters) *coreProxy {
	ctrl := protectedControl(prot)
	return &coreProxy{
		disp:     disp,
		tr:       tr,
		resolver: resolver,
		dialer:   &net.Dialer{Control: ctrl},
		listen:   &net.ListenConfig{Control: ctrl},
		ctr:      ctr,
	}
}
```

Wrap the tunnel-branch conns only:

```go
func (p *coreProxy) DialContext(ctx context.Context, m *M.Metadata) (net.Conn, error) {
	dst := m.DestinationAddrPort()
	if p.disp.route(dst, false) == "tunnel" {
		conn, err := p.tr.DialTCP(ctx, dst)
		if err != nil {
			return nil, err
		}
		return p.ctr.wrapConn(conn), nil
	}
	return p.dialer.DialContext(ctx, "tcp", dst.String())
}

func (p *coreProxy) DialUDP(m *M.Metadata) (net.PacketConn, error) {
	dst := m.DestinationAddrPort()
	switch p.disp.route(dst, true) {
	case "dns":
		return newDNSPacketConn(p.tr, p.resolver, m.UDPAddr()), nil
	case "tunnel":
		pc, err := p.tr.DialUDP(context.Background(), dst)
		if err != nil {
			return nil, err
		}
		return p.ctr.wrapPacketConn(tunnelUDP(pc, dst)), nil
	default:
		return p.listen.ListenPacket(context.Background(), "udp", ":0")
	}
}
```

(DNS and bypass branches are deliberately left uncounted.)

- [ ] **Step 4: Thread counters through `Session`**

In `session.go`, add the field and pull methods, and pass it to `newCoreProxy`:

```go
type Session struct {
	mu     sync.Mutex
	tr     transport.Transport
	eng    *engine
	stopCh chan struct{}
	ctr    *counters
}
```

In `Start`, before building the proxy:

```go
	ctr := &counters{}

	router := NewRouter(cfg.Mode, cfg.activeRuleSet())
	proxy := newCoreProxy(newDispatcher(router, cfg.Resolver.Addr()), tr, cfg.Resolver, prot, ctr)
```

After the `s.mu.Lock()` block where `s.tr`/`s.eng` are assigned, also store `s.ctr = ctr`. Then add:

```go
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
```

- [ ] **Step 5: Expose the pull API on the bound `mobile.Session`**

In `mobile/mobile.go`, add:

```go
// RxBytes/TxBytes report cumulative tunneled bytes (download/upload) for the poller.
func (s *Session) RxBytes() int64 { return s.inner.RxBytes() }
func (s *Session) TxBytes() int64 { return s.inner.TxBytes() }
```

- [ ] **Step 6: Run tests**

Run: `cd android/core && go test ./... -v`
Expected: PASS (new test passes; existing engine/router/session tests still pass).

- [ ] **Step 7: Commit**

```bash
git add android/core/engine.go android/core/session.go android/core/mobile/mobile.go android/core/engine_test.go
git commit -m "feat(core): count tunneled bytes in coreProxy, expose Rx/TxBytes"
```

---

## Task 3: EventSink.OnExitInfo across the gomobile boundary

**Files:**
- Modify: `android/core/session.go` (`EventSink` interface — add `OnExitInfo`)
- Modify: `android/core/mobile/mobile.go` (bound `EventSink` + `sinkAdapter`)
- Modify: `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt` (`Sink` must implement the new method — minimal store into new flows)

**Interfaces:**
- Consumes: nothing new.
- Produces: `OnExitInfo(ip, city, country string)` on `core.EventSink`, `mobile.EventSink`, and the Kotlin `Sink`; Kotlin `StateFlow`s `TunnelBahnVpnService.exitIp` and `TunnelBahnVpnService.exitLocation`.

- [ ] **Step 1: Add `OnExitInfo` to `core.EventSink`**

In `session.go`:

```go
type EventSink interface {
	OnState(state string)
	OnError(msg string)
	OnHostKey(line string)
	OnExitInfo(ip, city, country string)
}
```

- [ ] **Step 2: Add it to the bound `mobile.EventSink` + adapter**

In `mobile/mobile.go`, extend the interface and the adapter:

```go
type EventSink interface {
	OnState(state string)
	OnError(msg string)
	OnHostKey(line string)
	OnExitInfo(ip, city, country string)
}
```

```go
func (a sinkAdapter) OnExitInfo(ip, city, country string) { a.s.OnExitInfo(ip, city, country) }
```

- [ ] **Step 3: Implement the new method in the Kotlin `Sink`**

In `TunnelBahnVpnService.kt`, add the flows to the companion object (near `state`/`lastError`):

```kotlin
        /** Exit-IP and its geo location, pushed once per session by the Go probe. */
        val exitIp = MutableStateFlow("")
        val exitLocation = MutableStateFlow("")
```

Add to the `Sink` inner class:

```kotlin
        override fun onExitInfo(ip: String, city: String, country: String) {
            exitIp.value = ip
            exitLocation.value = formatLocation(city, country)
        }
```

(`formatLocation` is created in Task 5. Until then this will not compile; that is expected — Task 5 lands before the Kotlin build is exercised. If executing strictly in order and you need a green Kotlin build now, temporarily inline `exitLocation.value = listOf(city, country).filter { it.isNotBlank() }.joinToString(", ")` and replace it in Task 5.)

- [ ] **Step 4: Rebuild the AAR and Go tests**

Run:
```bash
cd android/core && go build ./... && go test ./...
cd android && ./build-core.sh
```
Expected: Go builds and tests pass; `build-core.sh` prints `built android/app/libs/libtunnelbahn.aar`.

- [ ] **Step 5: Commit**

```bash
git add android/core/session.go android/core/mobile/mobile.go \
  android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt android/app/libs/libtunnelbahn.aar
git commit -m "feat(core): OnExitInfo callback across gomobile for exit location"
```

---

## Task 4: Exit-IP + geo probe over the transport

**Files:**
- Create: `android/core/exitprobe.go`
- Create: `android/core/exitprobe_test.go`
- Modify: `android/core/session.go` (`Start`: launch probe on running, cancel on Stop)

**Interfaces:**
- Consumes: `transport.Transport` (`DialTCP`), `core.EventSink` (`OnExitInfo`).
- Produces:
  - `func parseIPInfo(body []byte) (ip, city, country string, err error)`
  - `func runExitProbe(ctx context.Context, tr transport.Transport, sink EventSink)`

- [ ] **Step 1: Write the failing test for `parseIPInfo`**

`android/core/exitprobe_test.go`:

```go
package core

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"

	"tunnelbahn/core/transport"
)

func TestParseIPInfo(t *testing.T) {
	body := []byte(`{"ip":"5.6.7.8","city":"Berlin","region":"Berlin","country":"DE"}`)
	ip, city, country, err := parseIPInfo(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if ip != "5.6.7.8" || city != "Berlin" || country != "DE" {
		t.Fatalf("got ip=%q city=%q country=%q", ip, city, country)
	}
}

// blockingTransport never returns from DialTCP until ctx is done, so the test can
// assert runExitProbe respects cancellation instead of hanging.
type blockingTransport struct{}

func (blockingTransport) DialTCP(ctx context.Context, _ netip.AddrPort) (net.Conn, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}
func (blockingTransport) DialUDP(context.Context, netip.AddrPort) (net.PacketConn, error) {
	return nil, transport.ErrUnsupportedProtocol
}
func (blockingTransport) Close() error { return nil }

func TestRunExitProbeHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runExitProbe(ctx, blockingTransport{}, nil) // nil sink: cancellation path emits nothing
		close(done)
	}()
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("runExitProbe did not return after context cancel")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test ./ -run 'TestParseIPInfo|TestRunExitProbe' -v`
Expected: FAIL (build error: `parseIPInfo` / `runExitProbe` undefined).

- [ ] **Step 3: Implement the probe**

`android/core/exitprobe.go`:

```go
package core

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"time"

	"tunnelbahn/core/transport"
)

// ipinfoHost is the geo provider queried through the tunnel. Unauthenticated /json is
// sufficient for personal use; swapping providers touches only these two constants.
const (
	ipinfoHost = "ipinfo.io"
	ipinfoURL  = "https://ipinfo.io/json"
)

type ipInfo struct {
	IP      string `json:"ip"`
	City    string `json:"city"`
	Country string `json:"country"`
}

func parseIPInfo(body []byte) (ip, city, country string, err error) {
	var v ipInfo
	if err = json.Unmarshal(body, &v); err != nil {
		return "", "", "", err
	}
	return v.IP, v.City, v.Country, nil
}

// runExitProbe fetches the exit IP + geo once, through the transport (so it reflects the
// real server egress and never bypasses the VPN), retrying a few times on failure. It is
// launched as a goroutine and returns when it succeeds, exhausts retries, or ctx is done.
func runExitProbe(ctx context.Context, tr transport.Transport, sink EventSink) {
	client := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			// Dial the carrier through the tunnel transport, then real TLS to ipinfo.
			DialTLSContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
				host, _, err := net.SplitHostPort(addr)
				if err != nil {
					host = ipinfoHost
				}
				ap, err := resolveIPInfoAddrPort(ctx, addr)
				if err != nil {
					return nil, err
				}
				raw, err := tr.DialTCP(ctx, ap)
				if err != nil {
					return nil, err
				}
				tlsConn := tls.Client(raw, &tls.Config{ServerName: host})
				if err := tlsConn.HandshakeContext(ctx); err != nil {
					raw.Close()
					return nil, err
				}
				return tlsConn, nil
			},
		},
	}

	backoff := time.Second
	for attempt := 0; attempt < 3; attempt++ {
		if ctx.Err() != nil {
			return
		}
		if tryExitProbe(ctx, client, sink) {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
			backoff *= 2
		}
	}
}

func tryExitProbe(ctx context.Context, client *http.Client, sink EventSink) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ipinfoURL, nil)
	if err != nil {
		return false
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "TunnelBahn-Android/1.0")
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return false
	}
	ip, city, country, err := parseIPInfo(body)
	if err != nil || ip == "" {
		return false
	}
	if sink != nil {
		sink.OnExitInfo(ip, city, country)
	}
	return true
}
```

Add the small resolver helper (ipinfo.io is a hostname; the transport's `DialTCP` needs a `netip.AddrPort`, so resolve the host to an IP through a protected/default resolver — but resolution must not leak. Simplest correct approach: let the transport dial by connecting to a resolved address. Since `DialTCP` takes `netip.AddrPort`, resolve via the Go default resolver, which for the probe is acceptable because only the A-record lookup (not the payload) uses it; the payload still egresses through the tunnel). Implement:

```go
func resolveIPInfoAddrPort(ctx context.Context, addr string) (netipAddrPort, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		host, port = ipinfoHost, "443"
	}
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
	if err != nil || len(ips) == 0 {
		return netipAddrPort{}, err
	}
	p, err := parsePort(port)
	if err != nil {
		return netipAddrPort{}, err
	}
	return netipMakeAddrPort(ips[0], p), nil
}
```

Replace the `netip*` placeholders with the real `net/netip` calls: import `net/netip`, use `netip.AddrPort` as the return type, `netip.AddrPortFrom(ips[0], p)`, and parse the port with `strconv.Atoi`. (This paragraph is guidance; write the concrete `net/netip` + `strconv` code — do not leave `netip*` placeholder identifiers in the file.)

> Reviewer note: if resolving ipinfo's hostname off-tunnel is deemed a leak in review, pin ipinfo to a literal A record or route the lookup through `ResolveOverTCP` (already in `dns.go`). For v1 the A-record lookup is metadata-only and acceptable; the acceptance test is that the *probe response* egresses through the tunnel, which it does.

- [ ] **Step 4: Launch the probe from `Session.Start`, cancel it on Stop**

In `session.go` `Start`, replace the plain `<-stopCh` wait with a cancellable context tied to it, and launch the probe right after emitting running:

```go
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
```

(`context` is already imported in `session.go`.)

- [ ] **Step 5: Run tests**

Run: `cd android/core && go test ./... -v`
Expected: PASS (`TestParseIPInfo`, `TestRunExitProbeHonorsCancellation`, and all existing tests).

- [ ] **Step 6: Rebuild the AAR**

Run: `cd android && ./build-core.sh`
Expected: `built android/app/libs/libtunnelbahn.aar`.

- [ ] **Step 7: Commit**

```bash
git add android/core/exitprobe.go android/core/exitprobe_test.go android/core/session.go android/app/libs/libtunnelbahn.aar
git commit -m "feat(core): probe exit IP + geo through the transport on connect"
```

---

## Task 5: Pure Kotlin formatters (speed, delta, location)

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/ui/SpeedFormat.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/ui/SpeedFormatTest.kt`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `fun humanizeSpeed(bytesPerSec: Long): String`
  - `fun bytesPerSecond(prevBytes: Long, curBytes: Long): Long`
  - `fun formatLocation(city: String, countryCode: String): String`

- [ ] **Step 1: Write the failing test**

```kotlin
package tunnelbahn.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SpeedFormatTest {
    @Test
    fun humanizesAcrossUnits() {
        assertEquals("0 B/s", humanizeSpeed(0))
        assertEquals("512 B/s", humanizeSpeed(512))
        assertEquals("1.0 KB/s", humanizeSpeed(1024))
        assertEquals("1.5 KB/s", humanizeSpeed(1536))
        assertEquals("2.0 MB/s", humanizeSpeed(2L * 1024 * 1024))
    }

    @Test
    fun bytesPerSecondIsNonNegativeDelta() {
        assertEquals(300, bytesPerSecond(1000, 1300))
        assertEquals(0, bytesPerSecond(0, 0))
        // counter reset / first sample: never a negative speed
        assertEquals(0, bytesPerSecond(5000, 100))
    }

    @Test
    fun formatsLocationCityAndCountryName() {
        assertEquals("Berlin, Germany", formatLocation("Berlin", "DE"))
        assertEquals("Germany", formatLocation("", "DE"))
        assertEquals("Berlin", formatLocation("Berlin", ""))
        assertEquals("XX", formatLocation("", "XX")) // unknown code passes through
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android && ./gradlew testDebugUnitTest --tests 'tunnelbahn.app.ui.SpeedFormatTest'`
Expected: FAIL (unresolved references).

- [ ] **Step 3: Write minimal implementation**

```kotlin
package tunnelbahn.app.ui

import java.util.Locale
import kotlin.math.max

/** Formats a byte/second rate as B/s, KB/s, or MB/s. One decimal at KB/s and above. */
fun humanizeSpeed(bytesPerSec: Long): String {
    val b = max(0L, bytesPerSec)
    return when {
        b < 1024 -> "$b B/s"
        b < 1024L * 1024 -> String.format(Locale.US, "%.1f KB/s", b / 1024.0)
        else -> String.format(Locale.US, "%.1f MB/s", b / (1024.0 * 1024.0))
    }
}

/** Per-second delta between two cumulative counters, clamped at 0 so a counter reset
 *  (new session) or the first sample never renders a negative speed. */
fun bytesPerSecond(prevBytes: Long, curBytes: Long): Long = max(0L, curBytes - prevBytes)

/** Builds a short "City, Country" label. Maps an ISO 3166 alpha-2 code to a display
 *  country name via Locale; an unknown code passes through unchanged. */
fun formatLocation(city: String, countryCode: String): String {
    val country = if (countryCode.length == 2) {
        Locale("", countryCode).displayCountry.ifBlank { countryCode }
    } else {
        countryCode
    }
    return listOf(city, country).filter { it.isNotBlank() }.joinToString(", ")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd android && ./gradlew testDebugUnitTest --tests 'tunnelbahn.app.ui.SpeedFormatTest'`
Expected: PASS.

> Note: `Locale("", "XX").displayCountry` returns `"XX"` for an unrecognized code on the JVM, satisfying the pass-through assertion. If a JDK returns empty for an unknown code, the `ifBlank { countryCode }` fallback still yields `"XX"`.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/SpeedFormat.kt android/app/src/test/java/tunnelbahn/app/ui/SpeedFormatTest.kt
git commit -m "feat(app): pure formatters for speed, delta, and exit location"
```

---

## Task 6: Service poller + dynamic notification

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt`

**Interfaces:**
- Consumes: `Session.RxBytes()/TxBytes()` (Task 2), `exitLocation` flow + `formatLocation`/`humanizeSpeed`/`bytesPerSecond` (Tasks 3, 5).
- Produces: a running notification whose content updates every second while connected.

- [ ] **Step 1: Add poller state fields**

In `TunnelBahnVpnService`, add instance fields near the other private vars:

```kotlin
    // 1s stats poller: samples the Go counters, re-posts the notification with speeds.
    private val pollHandler = Handler(Looper.getMainLooper())
    private var pollRunnable: Runnable? = null
    private var lastRx = 0L
    private var lastTx = 0L
    private var downSpeed = 0L
    private var upSpeed = 0L
```

- [ ] **Step 2: Start the poller on RUNNING**

In the `Sink.onState` handler, when `s == STATE_RUNNING` and after setting `connectedSince`, start polling:

```kotlin
        override fun onState(s: String) {
            state.value = s
            if (s == STATE_RUNNING) {
                connectedSince.value = System.currentTimeMillis()
                if (!reachedRunning) {
                    reachedRunning = true
                    Haptics.success(this@TunnelBahnVpnService)
                }
                mainHandler.post { startPolling() }
            }
        }
```

Add the poller methods:

```kotlin
    private fun startPolling() {
        if (pollRunnable != null) return
        val s = session ?: return
        lastRx = s.rxBytes()
        lastTx = s.txBytes()
        val r = object : Runnable {
            override fun run() {
                val sess = session ?: return
                val rx = sess.rxBytes()
                val tx = sess.txBytes()
                downSpeed = tunnelbahn.app.ui.bytesPerSecond(lastRx, rx)
                upSpeed = tunnelbahn.app.ui.bytesPerSecond(lastTx, tx)
                lastRx = rx
                lastTx = tx
                val mgr = getSystemService(NotificationManager::class.java)
                mgr.notify(NOTIF_ID, buildNotification())
                pollHandler.postDelayed(this, 1000)
            }
        }
        pollRunnable = r
        pollHandler.postDelayed(r, 1000)
    }

    private fun stopPolling() {
        pollRunnable?.let { pollHandler.removeCallbacks(it) }
        pollRunnable = null
        lastRx = 0L; lastTx = 0L; downSpeed = 0L; upSpeed = 0L
    }
```

- [ ] **Step 3: Stop the poller FIRST in `endSession`**

Modify `endSession` so polling stops before `session` is nulled and before `stopForeground`:

```kotlin
    private fun endSession(failed: Boolean) {
        stopPolling()
        session?.stop()
        session = null
        worker = null
        connectedSince.value = 0L
        exitIp.value = ""
        exitLocation.value = ""
        // ... unchanged: failed branch, stopForeground, stopSelf
    }
```

- [ ] **Step 4: Make `buildNotification` render speeds + location**

Replace the static content text and add `BigTextStyle` + `setOnlyAlertOnce`:

```kotlin
    private fun buildNotification(): Notification {
        val mgr = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Tunnel", NotificationManager.IMPORTANCE_LOW)
            mgr.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val down = tunnelbahn.app.ui.humanizeSpeed(downSpeed)
        val up = tunnelbahn.app.ui.humanizeSpeed(upSpeed)
        val line1 = "↓ $down  ·  ↑ $up" // down · up
        val loc = exitLocation.value.ifBlank { "Locating…" }
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return b
            .setContentTitle("TunnelBahn")
            .setContentText(line1)
            .setStyle(Notification.BigTextStyle().bigText("$line1\n$loc"))
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }
```

- [ ] **Step 5: Build the app**

Run: `cd android && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL. (No unit test for the service itself; the pure logic it calls is covered by Task 5. Verification is manual/e2e in Step 6.)

- [ ] **Step 6: Manual verification**

Install the debug APK on a device, connect a profile, generate traffic (open a page / run a download), and confirm the notification shows advancing `↓/↑` speeds and, within a few seconds, a plausible exit location matching the server. Disconnect and confirm the notification is removed (no lingering/re-posted notification).

- [ ] **Step 7: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt
git commit -m "feat(app): live speed + exit location in the ongoing notification"
```

---

## Task 7: Request POST_NOTIFICATIONS at runtime + denied hint

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt`

**Interfaces:**
- Consumes: nothing new.
- Produces: a runtime `POST_NOTIFICATIONS` request on API 33+ and an in-app hint when denied.

- [ ] **Step 1: Add a notification-permission launcher and denied state**

In `HomeScreen`, add near the other launchers (imports: `android.Manifest`, `android.content.pm.PackageManager`, `android.os.Build`, `androidx.core.content.ContextCompat`, `androidx.activity.result.contract.ActivityResultContracts.RequestPermission`):

```kotlin
    var notifDenied by remember { mutableStateOf(false) }
    val notifPermission = rememberLauncherForActivityResult(RequestPermission()) { granted ->
        notifDenied = !granted
    }

    fun ensureNotifPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            ctx, Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            notifDenied = false
        } else {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
```

- [ ] **Step 2: Ask at connect time**

In the existing `connect()` function in `HomeScreen`, call `ensureNotifPermission()` at the top (before `VpnService.prepare`):

```kotlin
    fun connect() {
        ensureNotifPermission()
        val id = profile?.id ?: return
        // ... unchanged
    }
```

- [ ] **Step 3: Show the denied hint**

In `ConnectionHero` (or just below it in `HomeScreen`'s connected branch), when `notifDenied` is true and the tunnel is running, render one short line. Pass `notifDenied` into `ConnectionHero` and add, after the elapsed `Text`:

```kotlin
        if (notifDenied) {
            Spacer(Modifier.height(8.dp))
            Text(
                "Live speed and exit location show in the notification. Allow notifications to see them.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
```

(Thread `notifDenied: Boolean` through the `ConnectionHero` signature; update its single call site.)

- [ ] **Step 4: Build**

Run: `cd android && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Manual verification**

On an API 33+ device with notifications not yet granted: tap Connect, confirm the system permission dialog appears. Deny it and confirm the in-app hint line shows and the tunnel still connects. Grant it (via a reconnect or app settings) and confirm the notification appears with live stats.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt
git commit -m "feat(app): request POST_NOTIFICATIONS so the status notification is visible"
```

---

## Self-Review Notes (for the executor)

- **Spec coverage:** byte counting (T1–T2), Rx/Tx pull API (T2), OnExitInfo boundary (T3), exit probe through transport (T4), pure formatters incl. country-name mapping (T5), 1s poller + BigTextStyle notification + teardown ordering (T6), POST_NOTIFICATIONS + denied fallback (T7). DNS/bypass/probe excluded from counts (T2). No re-probe on reconnect; ctx tied to stopCh (T4).
- **Type consistency:** Go byte totals are `int64` end-to-end (`counters.Rx/Tx` → `Session.RxBytes/TxBytes` → `mobile.Session.RxBytes/TxBytes`); Kotlin reads them as `Long` via the gomobile-generated `rxBytes()/txBytes()`. `OnExitInfo(ip, city, country)` has identical arg order in `core`, `mobile`, adapter, and Kotlin `Sink`. `formatLocation`/`humanizeSpeed`/`bytesPerSecond` are referenced fully-qualified from the service.
- **Known cross-task ordering:** Task 3 Step 3 references `formatLocation` from Task 5 — either land Task 5 before building Kotlin, or use the inline fallback noted in Task 3 and swap it in Task 5.
- **gomobile method casing:** Go exported `RxBytes()` binds to Kotlin `rxBytes()`; Go `OnExitInfo` binds to Kotlin `onExitInfo`. The plan already uses the lowercased forms on the Kotlin side.

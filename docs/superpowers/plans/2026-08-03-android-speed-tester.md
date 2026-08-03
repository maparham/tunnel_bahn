# Android Speed Tester Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full-parity speed tester to the Android app (download, upload, latency, jitter, live sparklines, Tunnel-vs-Direct comparison) on a dedicated screen, with the measurement engine in the Go core so the tunnel path is measured over the real transport.

**Architecture:** The measurement engine lives in the Go core (`android/core`). It runs the Cloudflare speed test over a supplied dialer: the **Tunnel** path dials through the live `transport.Transport` (like `exitprobe.go`), the **Direct** path dials with a plain `net.Dialer` (which bypasses the tun because the app disallows itself in every routing mode). Progress streams to Kotlin through a gomobile `SpeedTestSink`. A Kotlin `SpeedTestController` drives runs, exposes a `StateFlow`, and a Compose `SpeedTestScreen` renders two cards + a comparison strip.

**Tech Stack:** Go 1.26 (`tunnelbahn/core`, gomobile bind), Go stdlib `net/http`/`crypto/tls`, Kotlin + Jetpack Compose (Material3), Android `VpnService`, coroutines/`StateFlow`, JUnit4 (Kotlin) + Go `testing`.

## Global Constraints

- **No-legacy-code policy:** the app is undistributed; never add compat shims, schemaVersion fields, or migrations.
- **gomobile boundary:** only `string`, `int`, `int64`, `float64`, `bool`, `error`, and interfaces whose methods use those types may cross into Kotlin. No slices or structs are passed across. Go exported `Foo()` binds to Kotlin `foo()`; struct types are bound as classes; package-level constructors like `NewDirectSpeedTest()` bind as static `Mobile.newDirectSpeedTest()`.
- **App traffic always bypasses its own tunnel** (`vpn/PerAppRules.kt` disallows `tunnelbahn.app` in every mode). Therefore Direct needs no `protect()`, and the Tunnel path is only reachable inside the Go core over the transport.
- **UI copy:** no em dashes; tooltips one or two short sentences; use the questionmark+tooltip idiom, never inline footnotes.
- **Never use Sonnet** for any subagent; use haiku or opus/fable.
- **AAR is committed:** after Go changes, rebuild with `android/build-core.sh` and commit the regenerated `android/app/libs/libtunnelbahn.aar` (and `libtunnelbahn-sources.jar`).
- **Endpoints/constants (verbatim from macOS `Shared/SpeedTestEngine.swift`):** latency `https://speed.cloudflare.com/__down?bytes=0`; download `.../__down?bytes=50000000`; upload `.../__up` (POST). `latencyAttempts=9`, discard first, need `>=5` successes; `downloadStreams=4`, `uploadStreams=2`; sample every `0.25s`; window `16s` if median latency `>=400ms` else `8s`; upload ladder `[256 KiB, 1 MiB, 4 MiB, 16 MiB]`; Mbps `= bytes*8/seconds/1e6`; upload credits a body only on a clean 2xx completion.

---

## Task 1: Go pure math (median, jitter, Mbps)

**Files:**
- Create: `android/core/speedtest_math.go`
- Test: `android/core/speedtest_math_test.go`

**Interfaces:**
- Produces: `func median(values []float64) (float64, bool)`, `func jitter(values []float64) (float64, bool)`, `func throughputMbps(bytes int64, seconds float64) float64` (package `core`, unexported — used by the engine in Task 3).

- [ ] **Step 1: Write the failing test**

`android/core/speedtest_math_test.go`:
```go
package core

import (
	"math"
	"testing"
)

func approx(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestMedian(t *testing.T) {
	if _, ok := median(nil); ok {
		t.Fatal("empty should return ok=false")
	}
	if m, _ := median([]float64{3, 1, 2}); m != 2 {
		t.Fatalf("odd median = %v, want 2", m)
	}
	if m, _ := median([]float64{4, 1, 2, 3}); m != 2.5 {
		t.Fatalf("even median = %v, want 2.5", m)
	}
}

func TestJitter(t *testing.T) {
	// median = 2; deviations = {1,0,1}; mean = 2/3
	j, ok := jitter([]float64{1, 2, 3})
	if !ok || !approx(j, 2.0/3.0) {
		t.Fatalf("jitter = %v ok=%v, want 0.666...", j, ok)
	}
}

func TestThroughputMbps(t *testing.T) {
	if throughputMbps(1_000_000, 0) != 0 {
		t.Fatal("non-positive window must be 0")
	}
	// 1_000_000 bytes * 8 / 1s / 1e6 = 8 Mbps
	if got := throughputMbps(1_000_000, 1); !approx(got, 8) {
		t.Fatalf("mbps = %v, want 8", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test ./ -run 'TestMedian|TestJitter|TestThroughputMbps' -v`
Expected: FAIL (undefined: median/jitter/throughputMbps).

- [ ] **Step 3: Write minimal implementation**

`android/core/speedtest_math.go`:
```go
package core

import "sort"

// median returns the standard median; even counts average the middle pair.
// ok is false for empty input.
func median(values []float64) (float64, bool) {
	if len(values) == 0 {
		return 0, false
	}
	s := append([]float64(nil), values...)
	sort.Float64s(s)
	mid := len(s) / 2
	if len(s)%2 == 0 {
		return (s[mid-1] + s[mid]) / 2, true
	}
	return s[mid], true
}

// jitter is the mean absolute deviation from the median. ok is false for empty input.
func jitter(values []float64) (float64, bool) {
	m, ok := median(values)
	if !ok {
		return 0, false
	}
	var sum float64
	for _, v := range values {
		d := v - m
		if d < 0 {
			d = -d
		}
		sum += d
	}
	return sum / float64(len(values)), true
}

// throughputMbps is megabits per second from a byte count over a wall-clock window.
// Zero for a non-positive window.
func throughputMbps(bytes int64, seconds float64) float64 {
	if seconds <= 0 {
		return 0
	}
	return float64(bytes) * 8 / seconds / 1_000_000
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd android/core && go test ./ -run 'TestMedian|TestJitter|TestThroughputMbps' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/core/speedtest_math.go android/core/speedtest_math_test.go
git commit -m "feat(core): pure speed-test math (median, jitter, Mbps)"
```

---

## Task 2: Go upload ladder + adaptive window helpers

**Files:**
- Create: `android/core/speedtest.go` (constants + helpers only in this task)
- Test: `android/core/speedtest_test.go`

**Interfaces:**
- Produces: `stInitialUploadBytes() int`, `stNextUploadBytes(after int) int`, `stWindow(medianMs float64) time.Duration`, and the `st*` constants used by the engine in Task 3.

- [ ] **Step 1: Write the failing test**

`android/core/speedtest_test.go`:
```go
package core

import (
	"testing"
	"time"
)

func TestUploadLadder(t *testing.T) {
	if stInitialUploadBytes() != 256*1024 {
		t.Fatalf("initial = %d", stInitialUploadBytes())
	}
	if stNextUploadBytes(256*1024) != 1024*1024 {
		t.Fatal("256K -> 1M")
	}
	if stNextUploadBytes(4*1024*1024) != 16*1024*1024 {
		t.Fatal("4M -> 16M")
	}
	if stNextUploadBytes(16*1024*1024) != 16*1024*1024 {
		t.Fatal("cap stays at 16M")
	}
	if stNextUploadBytes(99*1024*1024) != 16*1024*1024 {
		t.Fatal("above cap stays at 16M")
	}
}

func TestWindow(t *testing.T) {
	if stWindow(399) != 8*time.Second {
		t.Fatal("below threshold -> 8s")
	}
	if stWindow(400) != 16*time.Second {
		t.Fatal("at threshold -> 16s")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test ./ -run 'TestUploadLadder|TestWindow' -v`
Expected: FAIL (undefined helpers).

- [ ] **Step 3: Write minimal implementation**

`android/core/speedtest.go` (only the header + helpers for now; the engine is added in Task 3):
```go
package core

import "time"

const (
	stLatencyURL  = "https://speed.cloudflare.com/__down?bytes=0"
	stDownloadURL = "https://speed.cloudflare.com/__down?bytes=50000000"
	stUploadURL   = "https://speed.cloudflare.com/__up"
	stHost        = "speed.cloudflare.com"

	stLatencyAttempts   = 9 // first discarded as warmup
	stMinLatencySuccess = 5
	stDownloadStreams   = 4
	stUploadStreams     = 2
	stSampleInterval    = 250 * time.Millisecond
)

// stUploadLadder: bodies start small so slow paths complete several per window, and
// grow so fast paths are not request-rate bound; the cap bounds the prebuilt buffer.
var stUploadLadder = []int{256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024}

func stInitialUploadBytes() int { return stUploadLadder[0] }

// stNextUploadBytes returns the next rung above completed, staying at the cap once reached.
func stNextUploadBytes(after int) int {
	for _, s := range stUploadLadder {
		if s > after {
			return s
		}
	}
	return stUploadLadder[len(stUploadLadder)-1]
}

// stWindow: high-RTT paths spend seconds in TCP slow start, dragging the whole-window
// average down; a longer window dilutes the ramp.
func stWindow(medianMs float64) time.Duration {
	if medianMs >= 400 {
		return 16 * time.Second
	}
	return 8 * time.Second
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd android/core && go test ./ -run 'TestUploadLadder|TestWindow' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/core/speedtest.go android/core/speedtest_test.go
git commit -m "feat(core): speed-test upload ladder and adaptive window helpers"
```

---

## Task 3: Go measurement engine + Session/Direct entry points

**Files:**
- Modify: `android/core/speedtest.go` (add the engine, dialers, `DirectSpeedTest`)
- Modify: `android/core/session.go` (add `RunTunnelSpeedTest`, `CancelSpeedTest`, `stCancel`/`stMu` fields)
- Test: `android/core/speedtest_test.go` (add an httptest-backed accounting test)

**Interfaces:**
- Consumes: `median`/`jitter`/`throughputMbps` (Task 1); `st*` constants/helpers (Task 2); `transport.Transport.DialTCP(ctx, netip.AddrPort)` (existing).
- Produces:
  - `type SpeedTestSink interface { OnPhase(name string); OnLatencySummary(medianMs, jitterMs float64); OnSample(phase string, offsetSeconds float64, bytes int64); OnResult(downloadMbps, uploadMbps, medianLatencyMs, jitterMs float64); OnError(msg string) }`
  - `func (s *Session) RunTunnelSpeedTest(sink SpeedTestSink) error`
  - `func (s *Session) CancelSpeedTest()`
  - `type DirectSpeedTest struct{...}`, `func NewDirectSpeedTest() *DirectSpeedTest`, `func (d *DirectSpeedTest) Run(sink SpeedTestSink) error`, `func (d *DirectSpeedTest) Cancel()`
  - `func runSpeedTest(ctx context.Context, dial dialTLSFunc, sink SpeedTestSink) error` (used by both entry points; tested directly).

- [ ] **Step 1: Write the failing test**

Add to `android/core/speedtest_test.go`:
```go
import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
)

// stubSink records the final result and any error for assertions.
type stubSink struct {
	mu     sync.Mutex
	result *[4]float64
	errMsg string
	phases []string
}

func (s *stubSink) OnPhase(n string) { s.mu.Lock(); s.phases = append(s.phases, n); s.mu.Unlock() }
func (s *stubSink) OnLatencySummary(m, j float64) {}
func (s *stubSink) OnSample(phase string, off float64, b int64) {}
func (s *stubSink) OnResult(d, u, m, j float64) {
	s.mu.Lock(); s.result = &[4]float64{d, u, m, j}; s.mu.Unlock()
}
func (s *stubSink) OnError(msg string) { s.mu.Lock(); s.errMsg = msg; s.mu.Unlock() }

// newLocalCloudflare fakes the three Cloudflare endpoints over TLS so runSpeedTest can be
// exercised end to end without the network.
func newLocalCloudflare() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/__down", func(w http.ResponseWriter, r *http.Request) {
		// bytes=0 -> latency ping; bytes=N -> stream N zero bytes.
		n := 0
		if v := r.URL.Query().Get("bytes"); v != "" {
			// small body keeps the test fast; the engine streams whatever arrives.
			if v == "50000000" {
				n = 1 << 20 // 1 MiB per request is plenty for accounting
			}
		}
		w.WriteHeader(200)
		if n > 0 {
			w.Write(make([]byte, n))
		}
	})
	mux.HandleFunc("/__up", func(w http.ResponseWriter, r *http.Request) {
		io_CopyDiscard(r.Body)
		w.WriteHeader(200)
	})
	return httptest.NewTLSServer(mux)
}

func TestRunSpeedTestAccounting(t *testing.T) {
	srv := newLocalCloudflare()
	defer srv.Close()

	// Point the engine's URLs at the local server for this test.
	restore := overrideSpeedTestURLs(srv.URL)
	defer restore()

	// dialTLS that trusts the test server's cert and ignores the real host.
	dial := func(ctx context.Context, addr string) (net.Conn, error) {
		return tls.Dial("tcp", srv.Listener.Addr().String(),
			&tls.Config{InsecureSkipVerify: true})
	}

	sink := &stubSink{}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	if err := runSpeedTest(ctx, dial, sink); err != nil {
		t.Fatalf("runSpeedTest: %v", err)
	}
	if sink.result == nil {
		t.Fatal("no result emitted")
	}
	if sink.result[0] <= 0 || sink.result[1] <= 0 {
		t.Fatalf("download/upload must be > 0, got %v", sink.result)
	}
}
```

Note: this test requires two small test-only seams. Add them in Step 3:
- `io_CopyDiscard(io.Reader)` helper (or inline `io.Copy(io.Discard, r)`).
- `overrideSpeedTestURLs(base string) (restore func())` that swaps the package URL vars to `base+"/__down..."` etc. To allow this, the engine must read the endpoints from package **vars** (not consts) so tests can point them locally. Change `stLatencyURL/stDownloadURL/stUploadURL` from `const` to `var` in `speedtest.go`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test ./ -run TestRunSpeedTestAccounting -v`
Expected: FAIL (undefined: `runSpeedTest`, `overrideSpeedTestURLs`, etc.).

- [ ] **Step 3: Write the engine**

First, change the three URL consts to vars in `speedtest.go`:
```go
// URLs are vars (not consts) so tests can point them at a local server.
var (
	stLatencyURL  = "https://speed.cloudflare.com/__down?bytes=0"
	stDownloadURL = "https://speed.cloudflare.com/__down?bytes=50000000"
	stUploadURL   = "https://speed.cloudflare.com/__up"
)

// overrideSpeedTestURLs points the endpoints at base for tests; call restore to undo.
func overrideSpeedTestURLs(base string) func() {
	l, d, u := stLatencyURL, stDownloadURL, stUploadURL
	stLatencyURL = base + "/__down?bytes=0"
	stDownloadURL = base + "/__down?bytes=50000000"
	stUploadURL = base + "/__up"
	return func() { stLatencyURL, stDownloadURL, stUploadURL = l, d, u }
}

func io_CopyDiscard(r io.Reader) { _, _ = io.Copy(io.Discard, r) }
```
Remove the old `const ( ... stLatencyURL ... )` entries so they are not declared twice (keep `stHost` and the numeric consts as `const`).

Then add the engine to `speedtest.go`:
```go
import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"tunnelbahn/core/transport"
)

// SpeedTestSink streams progress to the Android layer. Methods take only gomobile-safe types.
type SpeedTestSink interface {
	OnPhase(name string)
	OnLatencySummary(medianMs, jitterMs float64)
	OnSample(phase string, offsetSeconds float64, bytes int64)
	OnResult(downloadMbps, uploadMbps, medianLatencyMs, jitterMs float64)
	OnError(msg string)
}

// dialTLSFunc returns a ready TLS connection to addr ("host:port").
type dialTLSFunc func(ctx context.Context, addr string) (net.Conn, error)

// tunnelDialTLS dials Cloudflare through the transport, mirroring exitprobe.go: resolve
// the A-record with the default resolver (metadata only), dial via the transport, then TLS.
func tunnelDialTLS(tr transport.Transport) dialTLSFunc {
	return func(ctx context.Context, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			host, port = stHost, "443"
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
		if err != nil {
			return nil, err
		}
		if len(ips) == 0 {
			return nil, fmt.Errorf("no A record for %s", host)
		}
		p, err := strconv.Atoi(port)
		if err != nil {
			return nil, err
		}
		raw, err := tr.DialTCP(ctx, netip.AddrPortFrom(ips[0], uint16(p)))
		if err != nil {
			return nil, err
		}
		tlsConn := tls.Client(raw, &tls.Config{ServerName: host})
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			raw.Close()
			return nil, err
		}
		return tlsConn, nil
	}
}

// directDialTLS dials with a plain dialer; the app is disallowed from its own tun, so this
// egresses directly (no protect needed).
func directDialTLS() dialTLSFunc {
	d := &net.Dialer{Timeout: 15 * time.Second}
	return func(ctx context.Context, addr string) (net.Conn, error) {
		raw, err := d.DialContext(ctx, "tcp", addr)
		if err != nil {
			return nil, err
		}
		host, _, err := net.SplitHostPort(addr)
		if err != nil {
			host = stHost
		}
		tlsConn := tls.Client(raw, &tls.Config{ServerName: host})
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			raw.Close()
			return nil, err
		}
		return tlsConn, nil
	}
}

func newSpeedTestClient(dial dialTLSFunc) *http.Client {
	return &http.Client{
		// No overall timeout: transfer requests run for the whole window, bounded by ctx.
		Transport: &http.Transport{
			DialTLSContext:     func(ctx context.Context, _, addr string) (net.Conn, error) { return dial(ctx, addr) },
			DisableCompression: true,
		},
	}
}

// runSpeedTest runs latency -> download -> upload over dial, streaming progress to sink.
// A returned error is delivered via sink.OnError EXCEPT on cancellation (mirrors macOS's
// silent `catch is CancellationError`), so an auto-cancel's own message is not clobbered.
func runSpeedTest(ctx context.Context, dial dialTLSFunc, sink SpeedTestSink) error {
	client := newSpeedTestClient(dial)
	defer client.CloseIdleConnections()

	// reportErr surfaces a phase error unless it is a cancellation.
	reportErr := func(err error) error {
		if !errors.Is(err, context.Canceled) {
			sink.OnError(err.Error())
		}
		return err
	}

	sink.OnPhase("latency")
	med, jit, err := measureLatency(ctx, client, sink)
	if err != nil {
		return reportErr(err)
	}
	sink.OnLatencySummary(med, jit)
	window := stWindow(med)

	sink.OnPhase("download")
	dl, err := measureTransfer(ctx, client, "download", window, sink)
	if err != nil {
		return reportErr(err)
	}

	sink.OnPhase("upload")
	ul, err := measureTransfer(ctx, client, "upload", window, sink)
	if err != nil {
		return reportErr(err)
	}

	sink.OnResult(dl, ul, med, jit)
	return nil
}
```

Add `"errors"` to the import block at the top of `speedtest.go` (alongside `context`).

```go

func measureLatency(ctx context.Context, client *http.Client, sink SpeedTestSink) (float64, float64, error) {
	var samples []float64
	var lastErr error
	for attempt := 1; attempt <= stLatencyAttempts; attempt++ {
		if ctx.Err() != nil {
			return 0, 0, ctx.Err()
		}
		rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		t0 := time.Now()
		req, _ := http.NewRequestWithContext(rctx, http.MethodGet, stLatencyURL, nil)
		resp, err := client.Do(req)
		if err != nil {
			cancel()
			if ctx.Err() != nil {
				return 0, 0, ctx.Err()
			}
			lastErr = err
			continue
		}
		io_CopyDiscard(resp.Body)
		resp.Body.Close()
		cancel()
		ms := float64(time.Since(t0).Microseconds()) / 1000.0
		if attempt > 1 { // discard first as TLS/connection warmup
			samples = append(samples, ms)
			sink.OnSample("latency", 0, int64(ms)) // during "latency", bytes carries round-trip ms
		}
	}
	if len(samples) < stMinLatencySuccess {
		if lastErr != nil {
			return 0, 0, lastErr
		}
		return 0, 0, fmt.Errorf("latency probes failed")
	}
	m, _ := median(samples)
	j, _ := jitter(samples)
	return m, j, nil
}

// measureTransfer runs parallel streams for the window, sampling credited bytes every
// 0.25s. Streams restart on completion to stay saturated. Upload credits a body only on a
// clean 2xx completion. Returns the whole-window average Mbps.
func measureTransfer(ctx context.Context, client *http.Client, phase string, window time.Duration, sink SpeedTestSink) (float64, error) {
	var counted atomic.Int64
	var badStatus atomic.Int32 // first non-2xx status; 0 = none

	wctx, cancel := context.WithTimeout(ctx, window)
	defer cancel()

	var body []byte
	streams := stDownloadStreams
	if phase == "upload" {
		streams = stUploadStreams
		body = make([]byte, stUploadLadder[len(stUploadLadder)-1])
		_, _ = rand.Read(body) // incompressible so transparent compression cannot inflate the rate
	}

	start := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < streams; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			completed := -1
			for wctx.Err() == nil {
				if phase == "download" {
					if bad := doDownload(wctx, client, &counted); bad != 0 {
						badStatus.CompareAndSwap(0, int32(bad))
						return
					}
				} else {
					size := stInitialUploadBytes()
					if completed >= 0 {
						size = stNextUploadBytes(completed)
					}
					ok, bad := doUpload(wctx, client, body[:size])
					if bad != 0 {
						badStatus.CompareAndSwap(0, int32(bad))
						return
					}
					if ok {
						counted.Add(int64(size))
						completed = size
					}
				}
			}
		}()
	}

	sampleDone := make(chan struct{})
	go func() {
		defer close(sampleDone)
		t := time.NewTicker(stSampleInterval)
		defer t.Stop()
		for {
			select {
			case <-wctx.Done():
				return
			case <-t.C:
				sink.OnSample(phase, time.Since(start).Seconds(), counted.Load())
			}
		}
	}()

	wg.Wait()
	<-sampleDone
	elapsed := time.Since(start).Seconds()

	if bad := badStatus.Load(); bad != 0 {
		return 0, fmt.Errorf("server rejected the request (HTTP %d)", bad)
	}
	if ctx.Err() != nil { // external cancel, not the window deadline
		return 0, ctx.Err()
	}
	total := counted.Load()
	if total <= 0 {
		if phase == "download" {
			return 0, fmt.Errorf("no data received")
		}
		return 0, fmt.Errorf("no upload completed within the measurement window")
	}
	return throughputMbps(total, elapsed), nil
}

// doDownload streams one response body into counted. Returns a non-zero HTTP status on a
// non-2xx response, else 0. Transport/cancel errors return 0 (the stream just restarts).
func doDownload(ctx context.Context, client *http.Client, counted *atomic.Int64) int {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, stDownloadURL, nil)
	resp, err := client.Do(req)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		io_CopyDiscard(resp.Body)
		return resp.StatusCode
	}
	buf := make([]byte, 64*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			counted.Add(int64(n))
		}
		if err != nil {
			return 0
		}
	}
}

// doUpload POSTs body and reports whether it completed cleanly (2xx). Returns a non-zero
// status on a non-2xx response.
func doUpload(ctx context.Context, client *http.Client, body []byte) (bool, int) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, stUploadURL, bytes.NewReader(body))
	req.ContentLength = int64(len(body))
	resp, err := client.Do(req)
	if err != nil {
		return false, 0
	}
	defer resp.Body.Close()
	io_CopyDiscard(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return false, resp.StatusCode
	}
	return true, 0
}

// DirectSpeedTest runs the engine over a plain (bypass) dialer, independent of any session.
type DirectSpeedTest struct {
	mu     sync.Mutex
	cancel context.CancelFunc
}

func NewDirectSpeedTest() *DirectSpeedTest { return &DirectSpeedTest{} }

func (d *DirectSpeedTest) Run(sink SpeedTestSink) error {
	ctx, cancel := context.WithCancel(context.Background())
	d.mu.Lock()
	d.cancel = cancel
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		d.cancel = nil
		d.mu.Unlock()
		cancel()
	}()
	return runSpeedTest(ctx, directDialTLS(), sink)
}

func (d *DirectSpeedTest) Cancel() {
	d.mu.Lock()
	c := d.cancel
	d.mu.Unlock()
	if c != nil {
		c()
	}
}
```

Then add the Session entry points in `android/core/session.go`. Add two fields to the `Session` struct:
```go
	stMu     sync.Mutex
	stCancel context.CancelFunc
```
And the methods:
```go
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
```
`session.go` already imports `context`, `fmt`, `sync`, `net`, `netip` — no new imports needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android/core && go build ./... && go test ./ -run 'TestRunSpeedTestAccounting|TestUploadLadder|TestWindow|TestMedian|TestJitter|TestThroughputMbps' -v`
Expected: PASS. If `TestRunSpeedTestAccounting` is flaky under load, it is time-bounded by the 8s window; keep the 40s ctx timeout.

- [ ] **Step 5: Commit**

```bash
git add android/core/speedtest.go android/core/speedtest_test.go android/core/session.go
git commit -m "feat(core): speed-test engine over tunnel and direct dialers"
```

---

## Task 4: gomobile surface + AAR rebuild

**Files:**
- Modify: `android/core/mobile/mobile.go`
- Modify (regenerated binary): `android/app/libs/libtunnelbahn.aar`, `android/app/libs/libtunnelbahn-sources.jar`

**Interfaces:**
- Consumes: `core.SpeedTestSink`, `core.Session.RunTunnelSpeedTest/CancelSpeedTest`, `core.DirectSpeedTest` (Task 3).
- Produces (Kotlin-visible via `tunnelbahn.mobile`):
  - `interface SpeedTestSink { fun onPhase(name); fun onLatencySummary(medianMs, jitterMs); fun onSample(phase, offsetSeconds, bytes); fun onResult(down, up, latency, jitter); fun onError(msg) }`
  - `Session.runSpeedTest(sink): Unit` (throws on error), `Session.cancelSpeedTest()`
  - `class DirectSpeedTest`, `Mobile.newDirectSpeedTest(): DirectSpeedTest`, `DirectSpeedTest.run(sink)`, `DirectSpeedTest.cancel()`

- [ ] **Step 1: Add the gomobile surface**

Add to `android/core/mobile/mobile.go`:
```go
// SpeedTestSink receives speed-test progress. Implemented in Kotlin.
type SpeedTestSink interface {
	OnPhase(name string)
	OnLatencySummary(medianMs, jitterMs float64)
	OnSample(phase string, offsetSeconds float64, bytes int64)
	OnResult(downloadMbps, uploadMbps, medianLatencyMs, jitterMs float64)
	OnError(msg string)
}

type speedTestSinkAdapter struct{ s SpeedTestSink }

func (a speedTestSinkAdapter) OnPhase(n string)                    { a.s.OnPhase(n) }
func (a speedTestSinkAdapter) OnLatencySummary(m, j float64)       { a.s.OnLatencySummary(m, j) }
func (a speedTestSinkAdapter) OnSample(p string, o float64, b int64) { a.s.OnSample(p, o, b) }
func (a speedTestSinkAdapter) OnResult(d, u, m, j float64)         { a.s.OnResult(d, u, m, j) }
func (a speedTestSinkAdapter) OnError(msg string)                  { a.s.OnError(msg) }

// RunSpeedTest runs the tunnel-path speed test. Blocking; call off the main thread.
func (s *Session) RunSpeedTest(sink SpeedTestSink) error {
	return s.inner.RunTunnelSpeedTest(speedTestSinkAdapter{sink})
}

// CancelSpeedTest cancels an in-flight tunnel speed test.
func (s *Session) CancelSpeedTest() { s.inner.CancelSpeedTest() }

// DirectSpeedTest runs the direct-path speed test, independent of a session.
type DirectSpeedTest struct{ inner *core.DirectSpeedTest }

func NewDirectSpeedTest() *DirectSpeedTest { return &DirectSpeedTest{inner: core.NewDirectSpeedTest()} }

// Run runs the direct-path speed test. Blocking; call off the main thread.
func (d *DirectSpeedTest) Run(sink SpeedTestSink) error {
	return d.inner.Run(speedTestSinkAdapter{sink})
}

func (d *DirectSpeedTest) Cancel() { d.inner.Cancel() }
```

- [ ] **Step 2: Vet the Go module**

Run: `cd android/core && go build ./... && go vet ./...`
Expected: no errors.

- [ ] **Step 3: Rebuild the AAR**

Run: `cd android && ./build-core.sh`
Expected: prints `built android/app/libs/libtunnelbahn.aar` and lists `classes.jar`/`arm64-v8a`. Requires `ANDROID_NDK_HOME`/`ANDROID_HOME` and a JDK (the script resolves the Android Studio JBR). If the environment lacks an NDK, stop and report — the AAR cannot be regenerated without it.

- [ ] **Step 4: Confirm the new classes are bound**

Run: `cd android && unzip -p app/libs/libtunnelbahn-sources.jar 'tunnelbahn/mobile/DirectSpeedTest.java' | head -5`
Expected: the generated `DirectSpeedTest` Java proxy exists (confirms `SpeedTestSink`/`DirectSpeedTest`/`RunSpeedTest` are on the bound surface).

- [ ] **Step 5: Commit**

```bash
git add android/core/mobile/mobile.go android/app/libs/libtunnelbahn.aar android/app/libs/libtunnelbahn-sources.jar
git commit -m "feat(core): expose speed test across gomobile (Session + DirectSpeedTest)"
```

---

## Task 5: Expose the running Session to Kotlin callers

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt`

**Interfaces:**
- Produces: `TunnelBahnVpnService.activeSession: tunnelbahn.mobile.Session?` (companion, `@Volatile`), set to the live session in `startTunnel` and cleared in `endSession`.

- [ ] **Step 1: Add the companion accessor**

In the `companion object` of `TunnelBahnVpnService.kt`, add (near the other `MutableStateFlow`s):
```kotlin
        /** The live gomobile Session while running, for in-app callers (speed test).
         *  Null when not connected. Volatile: written by the service thread, read by the UI. */
        @Volatile
        var activeSession: tunnelbahn.mobile.Session? = null
```
Add the import at the top if not already present: `import tunnelbahn.mobile.Session` (or reference it fully-qualified as above).

- [ ] **Step 2: Set it when the session starts**

In `startTunnel(...)`, immediately after `val s = Mobile.newSession(); session = s`, add:
```kotlin
        activeSession = s
```

- [ ] **Step 3: Clear it on teardown**

In `endSession(...)` (the method that latches STATE_ERROR/DISCONNECTED and tears down), set `activeSession = null` before/after clearing `session`. Find the existing `session = null` (or equivalent teardown) line and add adjacent:
```kotlin
        activeSession = null
```
If `endSession` does not currently null `session`, add both there so a stopped tunnel never leaves a stale `activeSession`.

- [ ] **Step 4: Build**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt
git commit -m "feat(app): expose the live gomobile Session for in-app speed tests"
```

---

## Task 6: Kotlin speed-test models

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestModels.kt`

**Interfaces:**
- Produces:
  - `enum class SpeedTestPath { Tunnel, Direct }`
  - `enum class SpeedTestPhase { Idle, Latency, Download, Upload }`
  - `data class ThroughputSample(val offsetSeconds: Double, val mbps: Double)`
  - `data class SpeedTestResult(val path, val downloadMbps, val uploadMbps, val medianLatencyMs, val jitterMs, val finishedAtMs: Long, val downloadSamples: List<ThroughputSample>, val uploadSamples: List<ThroughputSample>)`
  - `data class LiveTransfer(val mbps: Double, val samples: List<ThroughputSample>)`
  - `data class SpeedTestUiState(val runningPath: SpeedTestPath?, val phase: SpeedTestPhase, val latencyReadout: String?, val latencyMs: Double?, val jitterMs: Double?, val download: LiveTransfer?, val upload: LiveTransfer?, val tunnelResult: SpeedTestResult?, val directResult: SpeedTestResult?, val errorMessage: String?)` with `companion object { val Idle = SpeedTestUiState(null, SpeedTestPhase.Idle, null, null, null, null, null, null, null, null) }` and `val isRunning get() = phase != SpeedTestPhase.Idle`

- [ ] **Step 1: Create the file**

`android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestModels.kt`:
```kotlin
package tunnelbahn.app.speedtest

/** Which path a run measured. */
enum class SpeedTestPath { Tunnel, Direct }

/** Current phase of a run. */
enum class SpeedTestPhase { Idle, Latency, Download, Upload }

/** One point of the throughput-over-time curve (per-interval instantaneous rate). */
data class ThroughputSample(val offsetSeconds: Double, val mbps: Double)

/** A finished run. In-memory only; the latest per path is kept for the session. */
data class SpeedTestResult(
    val path: SpeedTestPath,
    val downloadMbps: Double,
    val uploadMbps: Double,
    val medianLatencyMs: Double,
    val jitterMs: Double,
    val finishedAtMs: Long,
    val downloadSamples: List<ThroughputSample>,
    val uploadSamples: List<ThroughputSample>,
)

/** Live transfer state during a run: whole-window average so far + the sparkline series. */
data class LiveTransfer(val mbps: Double, val samples: List<ThroughputSample>)

/** All speed-test UI state, published as a single immutable snapshot. */
data class SpeedTestUiState(
    val runningPath: SpeedTestPath?,
    val phase: SpeedTestPhase,
    val latencyReadout: String?,
    val latencyMs: Double?,
    val jitterMs: Double?,
    val download: LiveTransfer?,
    val upload: LiveTransfer?,
    val tunnelResult: SpeedTestResult?,
    val directResult: SpeedTestResult?,
    val errorMessage: String?,
) {
    val isRunning get() = phase != SpeedTestPhase.Idle

    companion object {
        val Idle = SpeedTestUiState(
            runningPath = null,
            phase = SpeedTestPhase.Idle,
            latencyReadout = null,
            latencyMs = null,
            jitterMs = null,
            download = null,
            upload = null,
            tunnelResult = null,
            directResult = null,
            errorMessage = null,
        )
    }
}
```

- [ ] **Step 2: Build**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestModels.kt
git commit -m "feat(app): speed-test UI models"
```

---

## Task 7: Kotlin display math (series + deltas)

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestMath.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/speedtest/SpeedTestMathTest.kt`

**Interfaces:**
- Consumes: `ThroughputSample` (Task 6).
- Produces:
  - `fun throughputMbps(bytes: Long, seconds: Double): Double`
  - `fun throughputSeries(cumulative: List<Pair<Double, Long>>): List<ThroughputSample>` (each pair = (offsetSeconds, cumulativeBytes))
  - `fun deltaPercent(tunnel: Double, direct: Double): Double?`
  - `enum class DeltaSense { Better, Worse, Neutral }`
  - `fun deltaSense(delta: Double, lowerIsBetter: Boolean, neutralBand: Double): DeltaSense`

- [ ] **Step 1: Write the failing test**

`android/app/src/test/java/tunnelbahn/app/speedtest/SpeedTestMathTest.kt`:
```kotlin
package tunnelbahn.app.speedtest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SpeedTestMathTest {
    @Test fun throughputSeriesComputesPerIntervalRates() {
        // (0.5s, 1_000_000B) then (1.0s, 2_000_000B): each interval is 0.5s and 1_000_000B.
        // 1_000_000*8/0.5/1e6 = 16 Mbps per interval.
        val s = throughputSeries(listOf(0.5 to 1_000_000L, 1.0 to 2_000_000L))
        assertEquals(2, s.size)
        assertEquals(16.0, s[0].mbps, 1e-9)
        assertEquals(1.0, s[1].offsetSeconds, 1e-9)
        assertEquals(16.0, s[1].mbps, 1e-9)
    }

    @Test fun throughputSeriesSkipsNonAdvancingTime() {
        val s = throughputSeries(listOf(0.5 to 1_000_000L, 0.5 to 3_000_000L))
        assertEquals(1, s.size) // second point does not advance time, skipped
    }

    @Test fun deltaPercentNullOnZeroBaseline() {
        assertNull(deltaPercent(tunnel = 10.0, direct = 0.0))
        assertEquals(50.0, deltaPercent(tunnel = 15.0, direct = 10.0)!!, 1e-9)
    }

    @Test fun deltaSenseClassifies() {
        assertEquals(DeltaSense.Neutral, deltaSense(2.0, lowerIsBetter = false, neutralBand = 3.0))
        assertEquals(DeltaSense.Better, deltaSense(5.0, lowerIsBetter = false, neutralBand = 3.0))
        assertEquals(DeltaSense.Worse, deltaSense(5.0, lowerIsBetter = true, neutralBand = 3.0))
        assertEquals(DeltaSense.Better, deltaSense(-5.0, lowerIsBetter = true, neutralBand = 3.0))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'tunnelbahn.app.speedtest.SpeedTestMathTest'`
Expected: FAIL (unresolved references).

- [ ] **Step 3: Write the implementation**

`android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestMath.kt`:
```kotlin
package tunnelbahn.app.speedtest

import kotlin.math.abs

/** Megabits per second from a byte count over a wall-clock window. Zero for a non-positive window. */
fun throughputMbps(bytes: Long, seconds: Double): Double =
    if (seconds <= 0) 0.0 else bytes * 8.0 / seconds / 1_000_000.0

/**
 * Converts cumulative (offsetSeconds, bytes) snapshots into per-interval instantaneous rates.
 * The first interval is measured from (0, 0). Snapshots that do not advance time are skipped.
 */
fun throughputSeries(cumulative: List<Pair<Double, Long>>): List<ThroughputSample> {
    val out = ArrayList<ThroughputSample>(cumulative.size)
    var lastTime = 0.0
    var lastBytes = 0L
    for ((offset, bytes) in cumulative) {
        val dt = offset - lastTime
        if (dt <= 0) continue
        out.add(ThroughputSample(offset, throughputMbps(bytes - lastBytes, dt)))
        lastTime = offset
        lastBytes = bytes
    }
    return out
}

/** Signed percentage change of tunnel relative to the direct baseline; null when baseline is 0. */
fun deltaPercent(tunnel: Double, direct: Double): Double? =
    if (direct == 0.0) null else (tunnel - direct) / direct * 100.0

enum class DeltaSense { Better, Worse, Neutral }

/** Classifies a signed delta for display; magnitudes at or below neutralBand are noise. */
fun deltaSense(delta: Double, lowerIsBetter: Boolean, neutralBand: Double): DeltaSense {
    if (abs(delta) <= neutralBand) return DeltaSense.Neutral
    val improved = if (lowerIsBetter) delta < 0 else delta > 0
    return if (improved) DeltaSense.Better else DeltaSense.Worse
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'tunnelbahn.app.speedtest.SpeedTestMathTest'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestMath.kt android/app/src/test/java/tunnelbahn/app/speedtest/SpeedTestMathTest.kt
git commit -m "feat(app): speed-test display math (series + comparison deltas)"
```

---

## Task 8: Kotlin controller (SpeedTestSink + run/cancel + StateFlow)

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestController.kt`

**Interfaces:**
- Consumes: models (Task 6), `throughputSeries` (Task 7), `TunnelBahnVpnService.activeSession`/`state`/`STATE_RUNNING` (Task 5), gomobile `SpeedTestSink`/`Session.runSpeedTest`/`cancelSpeedTest`/`DirectSpeedTest` (Task 4).
- Produces: `object SpeedTestController` with `val state: StateFlow<SpeedTestUiState>`, `fun canRun(path: SpeedTestPath): Boolean`, `fun run(path: SpeedTestPath)`, `fun cancel()`.

Rationale for `object` (singleton): matches the app's existing pattern of process-global state on the service companion, so a run survives screen recomposition/navigation exactly like `TunnelBahnVpnService.state`.

- [ ] **Step 1: Create the controller**

`android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestController.kt`:
```kotlin
package tunnelbahn.app.speedtest

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import tunnelbahn.app.vpn.TunnelBahnVpnService
import tunnelbahn.mobile.DirectSpeedTest
import tunnelbahn.mobile.SpeedTestSink

/**
 * Drives speed-test runs and publishes UI state. Process-global (like the VPN state flow)
 * so a run survives navigation. The measurement runs in the Go core; this class implements
 * the gomobile [SpeedTestSink] and maps events onto [SpeedTestUiState].
 */
object SpeedTestController {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _state = MutableStateFlow(SpeedTestUiState.Idle)
    val state: StateFlow<SpeedTestUiState> = _state.asStateFlow()

    private var runJob: Job? = null
    private var watchJob: Job? = null
    // The gomobile handles captured at run start, so cancel() targets THIS run's objects even
    // after the service nulls its companion field on drop.
    private var tunnelSession: tunnelbahn.mobile.Session? = null
    private var directRun: DirectSpeedTest? = null
    // Monotonic run id; Sink callbacks for a stale run (after finish/cancel) are ignored.
    @Volatile private var generation = 0
    // Cumulative (offset, bytes) points for the transfer phase currently running.
    private val cumulative = ArrayList<Pair<Double, Long>>()

    fun canRun(path: SpeedTestPath): Boolean {
        if (_state.value.isRunning) return false
        return when (path) {
            SpeedTestPath.Tunnel ->
                TunnelBahnVpnService.state.value == TunnelBahnVpnService.STATE_RUNNING &&
                    TunnelBahnVpnService.activeSession != null
            SpeedTestPath.Direct -> true
        }
    }

    fun run(path: SpeedTestPath) {
        if (!canRun(path)) return
        // Capture the live session NOW; the companion field is nulled on a drop, but this run
        // still needs a handle to cancel through.
        val session = TunnelBahnVpnService.activeSession
        if (path == SpeedTestPath.Tunnel && session == null) return
        tunnelSession = session
        val gen = ++generation
        // Set running state synchronously so a second run() cannot pass canRun().
        cumulative.clear()
        _state.update {
            it.copy(
                runningPath = path,
                phase = SpeedTestPhase.Latency,
                latencyReadout = null,
                latencyMs = null,
                jitterMs = null,
                download = null,
                upload = null,
                errorMessage = null,
            )
        }
        val sink = Sink(path, gen)
        runJob = scope.launch(Dispatchers.IO) {
            try {
                when (path) {
                    SpeedTestPath.Tunnel -> session!!.runSpeedTest(sink)
                    SpeedTestPath.Direct -> DirectSpeedTest().also { directRun = it }.run(sink)
                }
            } catch (e: Throwable) {
                // A cancel surfaces here too; onError already set a message when relevant.
                if (gen == generation && _state.value.errorMessage == null) {
                    _state.update { it.copy(errorMessage = e.message) }
                }
            } finally {
                finish(gen)
            }
        }

        // Auto-cancel a tunnel run if the VPN leaves RUNNING mid-run. Scoped to this run and
        // cancelled in finish(), so it does not leak across runs.
        if (path == SpeedTestPath.Tunnel) {
            watchJob = scope.launch {
                TunnelBahnVpnService.state.collect { s ->
                    if (gen == generation && _state.value.runningPath == SpeedTestPath.Tunnel &&
                        s != TunnelBahnVpnService.STATE_RUNNING
                    ) {
                        _state.update { it.copy(errorMessage = "Test cancelled: tunnel dropped") }
                        cancel()
                    }
                }
            }
        }
    }

    fun cancel() {
        // Cancel the Go run first (it unblocks the parked JNI call), then the coroutines.
        tunnelSession?.cancelSpeedTest()
        directRun?.cancel()
        watchJob?.cancel()
        runJob?.cancel()
    }

    private fun finish(gen: Int) {
        if (gen != generation) return
        watchJob?.cancel()
        directRun = null
        tunnelSession = null
        _state.update {
            it.copy(runningPath = null, phase = SpeedTestPhase.Idle, download = null, upload = null, latencyReadout = null)
        }
    }

    /**
     * gomobile sink: callbacks arrive on a Go-owned thread; StateFlow.update is thread-safe.
     * Every callback is guarded by [gen] so a late event from a cancelled/finished run cannot
     * resurrect UI or write a stale result (mirrors macOS's `phase == .idle` guard in apply).
     */
    private inner class Sink(private val path: SpeedTestPath, private val gen: Int) : SpeedTestSink {
        override fun onPhase(name: String) {
            if (gen != generation) return
            cumulative.clear()
            val phase = when (name) {
                "latency" -> SpeedTestPhase.Latency
                "download" -> SpeedTestPhase.Download
                "upload" -> SpeedTestPhase.Upload
                else -> return
            }
            _state.update { it.copy(phase = phase) }
        }

        override fun onLatencySummary(medianMs: Double, jitterMs: Double) {
            if (gen != generation) return
            _state.update { it.copy(latencyMs = medianMs, jitterMs = jitterMs) }
        }

        override fun onSample(phase: String, offsetSeconds: Double, bytes: Long) {
            if (gen != generation) return
            if (phase == "latency") {
                // During latency, bytes carries the round-trip milliseconds (see engine).
                _state.update { it.copy(latencyReadout = "$bytes ms") }
                return
            }
            cumulative.add(offsetSeconds to bytes)
            val series = throughputSeries(cumulative.toList())
            val transfer = LiveTransfer(
                mbps = throughputMbps(bytes, offsetSeconds),
                samples = series,
            )
            _state.update {
                when (phase) {
                    "download" -> it.copy(download = transfer)
                    "upload" -> it.copy(upload = transfer)
                    else -> it
                }
            }
        }

        override fun onResult(downloadMbps: Double, uploadMbps: Double, medianLatencyMs: Double, jitterMs: Double) {
            if (gen != generation) return
            val result = SpeedTestResult(
                path = path,
                downloadMbps = downloadMbps,
                uploadMbps = uploadMbps,
                medianLatencyMs = medianLatencyMs,
                jitterMs = jitterMs,
                finishedAtMs = System.currentTimeMillis(),
                downloadSamples = _state.value.download?.samples ?: emptyList(),
                uploadSamples = _state.value.upload?.samples ?: emptyList(),
            )
            _state.update {
                when (path) {
                    SpeedTestPath.Tunnel -> it.copy(tunnelResult = result)
                    SpeedTestPath.Direct -> it.copy(directResult = result)
                }
            }
        }

        override fun onError(msg: String) {
            if (gen != generation) return
            // Do not overwrite an auto-cancel message already set by the watcher.
            _state.update { if (it.errorMessage != null) it else it.copy(errorMessage = "Speed test failed: $msg") }
        }
    }
}
```

Why cancellation is Go-driven: the Kotlin coroutine running the Tunnel test is parked inside the blocking JNI call `session.runSpeedTest(sink)` and cannot be interrupted by `runJob.cancel()` alone. `cancel()` therefore calls `session.cancelSpeedTest()` on the captured session ref first — that cancels the Go context, unblocks the native call, and the coroutine then completes. The captured ref matters because `TunnelBahnVpnService.activeSession` is nulled the moment the tunnel drops (Task 5), so a companion-field lookup at cancel time would be null. Task 3 also ties the Go run's context to the session `stopCh`, so even a drop that races ahead of the watcher still ends the run promptly.

The `watchJob` collector is scoped to the run and cancelled in `finish()`, so it does not leak across runs. The `generation` counter guards every `Sink` callback and `finish()` so a late event from a cancelled run cannot resurrect the UI or write a stale result.

- [ ] **Step 2: Build**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL. (This requires Task 4's AAR to expose `SpeedTestSink`/`DirectSpeedTest`/`runSpeedTest`.)

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/speedtest/SpeedTestController.kt
git commit -m "feat(app): speed-test controller bridging the Go engine to UI state"
```

---

## Task 9: Compose speed-test screen

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/ui/SpeedTestScreen.kt`

**Interfaces:**
- Consumes: `SpeedTestController` (Task 8), models (Task 6), `deltaPercent`/`deltaSense`/`DeltaSense` (Task 7).
- Produces: `@Composable fun SpeedTestScreen(onBack: () -> Unit)`.

- [ ] **Step 1: Create the screen**

`android/app/src/main/java/tunnelbahn/app/ui/SpeedTestScreen.kt`:
```kotlin
package tunnelbahn.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import tunnelbahn.app.speedtest.DeltaSense
import tunnelbahn.app.speedtest.LiveTransfer
import tunnelbahn.app.speedtest.SpeedTestController
import tunnelbahn.app.speedtest.SpeedTestPath
import tunnelbahn.app.speedtest.SpeedTestPhase
import tunnelbahn.app.speedtest.SpeedTestResult
import tunnelbahn.app.speedtest.SpeedTestUiState
import tunnelbahn.app.speedtest.ThroughputSample
import tunnelbahn.app.speedtest.deltaPercent
import tunnelbahn.app.speedtest.deltaSense
import java.util.Locale

private val DownloadColor = Color(0xFF2E7DF6)
private val UploadColor = Color(0xFF2FA84F)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SpeedTestScreen(onBack: () -> Unit) {
    val ui by SpeedTestController.state.collectAsStateWithLifecycle()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Speed Test") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { pad ->
        Column(
            Modifier.padding(pad).padding(16.dp).fillMaxWidth().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            PathCard(ui, SpeedTestPath.Tunnel)
            PathCard(ui, SpeedTestPath.Direct)
            ComparisonStrip(ui.tunnelResult, ui.directResult)
            ui.errorMessage?.let {
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
            }
        }
    }
}

@Composable
private fun PathCard(ui: SpeedTestUiState, path: SpeedTestPath) {
    val title = if (path == SpeedTestPath.Tunnel) "Tunnel" else "Direct"
    val result = if (path == SpeedTestPath.Tunnel) ui.tunnelResult else ui.directResult
    val isThisRunning = ui.runningPath == path
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(title, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                if (isThisRunning) {
                    OutlinedButton(onClick = { SpeedTestController.cancel() }) { Text("Cancel") }
                } else {
                    Button(
                        onClick = { SpeedTestController.run(path) },
                        enabled = SpeedTestController.canRun(path),
                    ) { Text("Run") }
                }
            }

            val downloadMbps = when {
                isThisRunning -> ui.download?.mbps
                else -> result?.downloadMbps
            }
            val uploadMbps = when {
                isThisRunning -> ui.upload?.mbps
                else -> result?.uploadMbps
            }
            val downloadSamples = if (isThisRunning) ui.download?.samples else result?.downloadSamples
            val uploadSamples = if (isThisRunning) ui.upload?.samples else result?.uploadSamples

            MetricRow("Download", "↓", DownloadColor, downloadMbps, downloadSamples)
            MetricRow("Upload", "↑", UploadColor, uploadMbps, uploadSamples)

            val latency = if (isThisRunning) ui.latencyMs else result?.medianLatencyMs
            val jitter = if (isThisRunning) ui.jitterMs else result?.jitterMs
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                Text("Latency ${fmt0(latency)} ms", fontSize = 13.sp)
                Text("Jitter ${fmt1(jitter)} ms", fontSize = 13.sp)
            }

            if (isThisRunning) {
                Text(phaseLabel(ui.phase, ui.latencyReadout), fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun MetricRow(
    label: String, arrow: String, color: Color, mbps: Double?, samples: List<ThroughputSample>?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(arrow, color = color, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            Text(
                if (mbps == null) "--" else String.format(Locale.US, "%.1f Mbps", mbps),
                fontSize = 22.sp, fontWeight = FontWeight.Bold, color = color,
            )
        }
        Sparkline(samples ?: emptyList(), color, Modifier.fillMaxWidth().height(40.dp))
    }
}

/** Area + line sparkline of a throughput series, drawn on a Canvas (no chart library). */
@Composable
private fun Sparkline(samples: List<ThroughputSample>, color: Color, modifier: Modifier) {
    Canvas(modifier) {
        if (samples.size < 2) return@Canvas
        val maxMbps = (samples.maxOf { it.mbps }).coerceAtLeast(1e-6)
        val n = samples.size
        val stepX = size.width / (n - 1)
        fun x(i: Int) = stepX * i
        fun y(v: Double) = size.height - (v / maxMbps).toFloat() * size.height

        val line = Path().apply {
            moveTo(x(0), y(samples[0].mbps))
            for (i in 1 until n) lineTo(x(i), y(samples[i].mbps))
        }
        val area = Path().apply {
            addPath(line)
            lineTo(x(n - 1), size.height)
            lineTo(x(0), size.height)
            close()
        }
        drawPath(area, color.copy(alpha = 0.15f))
        drawPath(line, color, style = Stroke(width = 2.5f))
    }
}

@Composable
private fun ComparisonStrip(tunnel: SpeedTestResult?, direct: SpeedTestResult?) {
    if (tunnel == null || direct == null) return
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Tunnel vs Direct", fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            DeltaRow("Download", deltaPercent(tunnel.downloadMbps, direct.downloadMbps), true, false)
            DeltaRow("Upload", deltaPercent(tunnel.uploadMbps, direct.uploadMbps), true, false)
            DeltaRow("Latency", tunnel.medianLatencyMs - direct.medianLatencyMs, false, true)
            DeltaRow("Jitter", tunnel.jitterMs - direct.jitterMs, false, true)
        }
    }
}

@Composable
private fun DeltaRow(label: String, delta: Double?, isPercent: Boolean, lowerIsBetter: Boolean) {
    val band = if (isPercent) 3.0 else 2.0
    val sense = if (delta == null) DeltaSense.Neutral else deltaSense(delta, lowerIsBetter, band)
    val color = when (sense) {
        DeltaSense.Better -> UploadColor
        DeltaSense.Worse -> MaterialTheme.colorScheme.error
        DeltaSense.Neutral -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val text = when {
        delta == null -> "--"
        isPercent -> String.format(Locale.US, "%+.0f%%", delta)
        else -> String.format(Locale.US, "%+.1f ms", delta)
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, fontSize = 13.sp)
        Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = color)
    }
}

private fun phaseLabel(phase: SpeedTestPhase, latencyReadout: String?): String = when (phase) {
    SpeedTestPhase.Latency -> "Measuring latency ${latencyReadout ?: ""}".trim()
    SpeedTestPhase.Download -> "Measuring download"
    SpeedTestPhase.Upload -> "Measuring upload"
    SpeedTestPhase.Idle -> ""
}

private fun fmt0(v: Double?) = if (v == null) "--" else String.format(Locale.US, "%.0f", v)
private fun fmt1(v: Double?) = if (v == null) "--" else String.format(Locale.US, "%.1f", v)
```

- [ ] **Step 2: Build**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/SpeedTestScreen.kt
git commit -m "feat(app): speed-test screen with cards, sparklines, comparison strip"
```

---

## Task 10: Navigation + Home entry point

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/AppRoot.kt`
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt`

**Interfaces:**
- Consumes: `SpeedTestScreen` (Task 9).
- Produces: `Screen.SpeedTest` route; a gauge action on the Home `TopAppBar` that navigates to it.

- [ ] **Step 1: Add the route**

In `AppRoot.kt`, add to the sealed interface:
```kotlin
    data object SpeedTest : Screen
```
Add a parameter to `HomeScreen(...)` for navigation and a branch in the `when`:
```kotlin
        is Screen.Home -> HomeScreen(
            onProfiles = { screen = Screen.Profiles },
            onAddProfile = { screen = Screen.Edit(null, returnTo = Screen.Home) },
            onEditProfile = { id -> screen = Screen.Edit(id, returnTo = Screen.Home) },
            onSpeedTest = { screen = Screen.SpeedTest },
        )
        // ... existing branches ...
        is Screen.SpeedTest -> SpeedTestScreen(onBack = { screen = Screen.Home })
```
The existing `BackHandler` already returns non-Home screens to Home via the `else` branch, so `SpeedTest` is covered.

- [ ] **Step 2: Add the Home entry point**

In `HomeScreen.kt`, add the parameter to the signature:
```kotlin
fun HomeScreen(
    onProfiles: () -> Unit,
    onAddProfile: () -> Unit,
    onEditProfile: (String) -> Unit,
    onSpeedTest: () -> Unit,
) {
```
Add a gauge action to the `TopAppBar` `actions` block (before or after the Profiles `IconButton`), using an available Material icon:
```kotlin
                    IconButton(onClick = onSpeedTest) {
                        Icon(Icons.Default.Speed, contentDescription = "Speed test")
                    }
```
Add the import: `import androidx.compose.material.icons.filled.Speed` (from `material-icons-extended`, already a dependency per `build.gradle.kts`).

- [ ] **Step 3: Build**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/AppRoot.kt android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt
git commit -m "feat(app): navigate to the speed test from Home"
```

---

## Task 11: Full build + end-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Full unit test + assemble**

Run:
```bash
cd android/core && go test ./... && cd ../.. \
  && cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug
```
Expected: Go tests pass; Kotlin unit tests pass; APK assembles.

- [ ] **Step 2: Install and drive on a device/emulator**

Run: `cd android && ./gradlew :app:installDebug`
Then, with a device attached:
1. Open the app, tap the gauge icon -> Speed Test screen appears.
2. With the VPN **disconnected**, tap **Run** on the Direct card. Confirm latency -> download -> upload progress, non-zero Mbps, sparklines, and a final result. The Tunnel card's Run is disabled.
3. Go back, connect a working profile, return to Speed Test.
4. Tap **Run** on the Tunnel card; confirm a full run and result.
5. Tap **Run** on the Direct card; confirm the comparison strip appears with signed deltas.

- [ ] **Step 3: Verify path attribution**

The Direct and Tunnel numbers must differ in a way consistent with the link (Tunnel typically higher latency). Cross-check the tunnel path is real using the exit IP the core already reports (`TunnelBahnVpnService.exitIp`/`exitLocation`): it reflects the VPN egress, confirming tunnel traffic leaves via the server, not the ISP. Do **not** use `HeadlessDriver`'s probe for this (its own traffic bypasses the VPN, per the android-e2e notes).

- [ ] **Step 4: Mid-run auto-cancel**

Start a Tunnel run, then disconnect the VPN from the notification/Home. Confirm the run stops and shows "Test cancelled: tunnel dropped" rather than hanging or reporting bogus numbers.

- [ ] **Step 5: Commit any fixes found during verification**

Commit with a message describing the fix. If everything passes with no changes, no commit is needed for this task.

---

## Self-Review

**1. Spec coverage:**
- Cloudflare endpoints/constants/methodology -> Tasks 1-3 (verbatim in Global Constraints + engine).
- Latency median/jitter, adaptive window, 4/2 streams, restart-on-finish, 0.25s sampling, upload completed-body accounting + ladder -> Task 3.
- Tunnel-over-transport vs Direct-plain-dialer -> Task 3 (`tunnelDialTLS`/`directDialTLS`), exposed in Task 4.
- gomobile surface -> Task 4. Live Session exposure -> Task 5.
- Models -> Task 6. Display math (series/deltas) -> Task 7. Controller + auto-cancel + canRun -> Task 8.
- Two cards + sparklines + comparison strip + phase indicator -> Task 9. Dedicated screen + Home entry -> Tasks 9-10.
- In-memory-only results -> Task 6/8 (no persistence). Tests -> Tasks 1,2,3,7,11.

**2. Placeholder scan:** No TBD/TODO; every code step has concrete code; verification steps have concrete commands and expected results.

**3. Type consistency:**
- `SpeedTestSink` method set is identical across `core` (Task 3), `mobile` (Task 4), and the Kotlin `Sink` (Task 8): `onPhase`, `onLatencySummary`, `onSample(phase, offsetSeconds, bytes)`, `onResult(down, up, latency, jitter)`, `onError`.
- `SpeedTestPath { Tunnel, Direct }`, `SpeedTestPhase { Idle, Latency, Download, Upload }` used consistently in Tasks 6/8/9.
- `throughputSeries(List<Pair<Double, Long>>)` defined in Task 7, called in Task 8 with `(offsetSeconds to bytes)` pairs.
- `TunnelBahnVpnService.activeSession` produced in Task 5, consumed in Task 8; `STATE_RUNNING` is the existing constant.
- gomobile lowercasing: Go `RunSpeedTest`/`CancelSpeedTest`/`Run`/`Cancel`/`OnSample` bind to Kotlin `runSpeedTest`/`cancelSpeedTest`/`run`/`cancel`/`onSample` (used as such in Task 8).

**Notes for the implementer:**
- Task 3's `TestRunSpeedTestAccounting` needs the endpoint URLs to be package `var`s (done in Task 3 Step 3) and `overrideSpeedTestURLs`. Keep numeric constants and `stHost` as `const`.
- Task 4 requires an Android NDK to rebuild the AAR; if unavailable, that task blocks the Kotlin tasks that reference the new bound symbols.

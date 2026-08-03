# Android Speed Tester — Design

Date: 2026-08-03
Branch: android-client

## Goal

Bring the macOS speed-tester feature to the Android app at full parity: measure
download, upload, latency, and jitter over both the **Tunnel** and **Direct**
network paths, with live sparklines and a Tunnel-vs-Direct comparison strip, on a
dedicated screen. Measurement methodology and math mirror the macOS
implementation exactly (Cloudflare public speed-test endpoints).

## Reference: macOS implementation

- Engine: `Shared/SpeedTestEngine.swift`, math: `Shared/SpeedTestMath.swift`.
- Endpoints (Cloudflare):
  - Latency: `https://speed.cloudflare.com/__down?bytes=0`
  - Download: `https://speed.cloudflare.com/__down?bytes=50000000` (50 MB; ≥100 MB returns 403)
  - Upload: `https://speed.cloudflare.com/__up` (POST)
- Run order: latency → download → upload.
- Latency: 9 sequential requests, discard first (TLS warmup), need ≥5 successes;
  ping = median, jitter = mean absolute deviation from the median.
- Adaptive transfer window: 16 s if median latency ≥ 400 ms, else 8 s.
- Parallel streams: download = 4, upload = 2. Streams that finish before the
  window ends restart immediately to keep the pipe saturated.
- Upload: one incompressible random buffer; POST prefixes of it; bytes credited
  **only when a POST completes cleanly** (server acknowledged the whole body).
  Body sizes climb a ladder 256 KiB → 1 MiB → 4 MiB → 16 MiB.
- Sampling: snapshot cumulative bytes every 0.25 s → sparkline series.
- Mbps = `bytes * 8 / seconds / 1_000_000` over elapsed wall clock.
- Guards: cache disabled, per-phase request timeouts, non-2xx aborts the phase
  with the HTTP error rather than a bogus rate.
- UI (`SpeedTestView.swift`): two cards (Tunnel / Direct), each with Download/Upload
  hero numbers + sparkline + latency/jitter footer + "tested … ago"; a comparison
  strip with signed %/ms deltas (neutral bands 3 % throughput, 2 ms timing).

## Android architecture

### Why the engine lives in the Go core (corrected from first draft)

The measurement engine runs **inside the Go core** (`android/core`), not in Kotlin.
This is forced by how Android VPNs work, and it is verified against this repo's own
code:

- `vpn/PerAppRules.kt` keeps the app's **own** package (`tunnelbahn.app`) out of the
  tun in every routing mode ("our own package is always kept out of the tun so the
  carrier socket never loops back"). So an ordinary in-app socket **always bypasses
  the tunnel** — it is already the *Direct* path.
- `VpnService.protect()` can only *remove* a socket from the VPN; there is no API to
  *force* an app socket into the tunnel. So the *Tunnel* path is unreachable from any
  Kotlin/app socket, in every mode.
- The Go core already reaches the internet **through the transport** in
  `core/exitprobe.go`, using `transport.Transport.DialTCP(ctx, netip.AddrPort)` then
  `tls.Client(...)`. A speed test built the same way measures the true tunnel path,
  independent of per-app routing mode. This is the correct analog of the macOS
  `SpeedTestHelper` (a process forced into the tunnel via an `NEAppRule`).

Therefore: **Tunnel** = dial Cloudflare over the live `transport.Transport`;
**Direct** = dial Cloudflare with a plain `net.Dialer` (which bypasses the tun
because the app is disallowed — `protect()` is not needed at all). One Go engine,
two dialers, exactly mirroring the macOS "same engine, in-process vs helper" split.

### File layout

Go core (`android/core/`):

| File | Role |
|---|---|
| `speedtest.go` | The engine: latency → download → upload over a supplied dialer; parallel streams; adaptive window; 0.25 s sampling; emits progress via a `SpeedTestSink`. Plus `Session.RunTunnelSpeedTest` (uses `s.tr`) and a session-independent `DirectSpeedTest` (plain dialer). |
| `speedtest_math.go` | Pure math: `median`, `jitter`, `throughputMbps`. Unit-tested in Go. |
| `speedtest_test.go` / `speedtest_math_test.go` | Go unit tests for the math and for stream/ladder accounting. |
| `mobile/mobile.go` (modify) | gomobile surface: `SpeedTestSink` interface; `Session.RunSpeedTest(sink)`/`CancelSpeedTest()`; bound `DirectSpeedTest{ Run(sink); Cancel() }`. |

Android app (`android/app/src/main/java/tunnelbahn/app/`):

| File | Role (macOS analog) |
|---|---|
| `speedtest/SpeedTestModels.kt` | `SpeedTestResult`, `ThroughputSample`, `SpeedTestPath { Tunnel, Direct }`, `SpeedTestPhase`, `SpeedTestUiState`, `LiveRunData` (`SpeedTestResult.swift` + `SpeedTestService.LiveRunData`). |
| `speedtest/SpeedTestMath.kt` | Display-side math only: `throughputSeries` (per-interval rates for sparklines), `deltaPercent`, `deltaSense` (comparison strip). Ported from `SpeedTestMath.swift`; unit-tested. Latency median/jitter are computed in Go, not here. |
| `speedtest/SpeedTestController.kt` | Implements the Kotlin `SpeedTestSink`, runs the Go engine on `Dispatchers.IO`, exposes `StateFlow<SpeedTestUiState>`, handles cancel + auto-cancel on VPN path change (analog of `SpeedTestService`). |
| `ui/SpeedTestScreen.kt` | Compose screen: two path cards + comparison strip + sparklines + phase indicator (`SpeedTestView.swift`). |

Wiring: expose the running `Session` to Kotlin callers via a companion accessor on
`TunnelBahnVpnService` (`@Volatile var activeSession`, set in `startTunnel`, cleared
in `endSession`) so the controller can call `RunSpeedTest` on the live transport.
Add `Screen.SpeedTest` to `ui/AppRoot.kt`; entry point is a gauge icon on the
`TopAppBar`/`ConnectionHero` in `ui/HomeScreen.kt`. Reuse `ui/SpeedFormat.kt`
formatting and the hand-drawn Canvas idiom from `StatusRing` for sparklines (no
chart library). Rebuild the AAR with `android/build-core.sh` after Go changes and
commit the regenerated `libtunnelbahn.aar` (repo convention).

## Measurement engine details (Go)

Constants ported verbatim from macOS (`SpeedTestEngine.swift`):

- `latencyAttempts = 9`, `minLatencySuccesses = 5` (discard first sample as warmup).
- `downloadStreams = 4`, `uploadStreams = 2`.
- `sampleIntervalSeconds = 0.25`.
- Adaptive window: `>= 400 ms` median → `16 s`, else `8 s`.
- Endpoints: latency `https://speed.cloudflare.com/__down?bytes=0`, download
  `.../__down?bytes=50000000`, upload `.../__up` (POST).
- Upload ladder `[256 KiB, 1 MiB, 4 MiB, 16 MiB]`; `nextUploadBodyBytes(after:)` climbs.
- Per-request timeout 15 s; latency request timeout 5 s.

Implementation:

- One `*http.Client` per phase, built from a dialer:
  - **Tunnel:** `http.Transport.DialTLSContext` resolves the host A-record with the
    default resolver (metadata only), dials `tr.DialTCP(ctx, addrPort)`, then
    `tls.Client(raw, &tls.Config{ServerName: "speed.cloudflare.com"})` and handshakes
    — identical to `exitprobe.go`.
  - **Direct:** a default `http.Client` (or plain `net.Dialer`), which bypasses the
    tun because the app is disallowed from it.
- Latency: 9 sequential GETs to `__down?bytes=0`, discard the first; require
  `>= 5` successes; `median` and `jitter` (mean absolute deviation) via
  `speedtest_math.go`. Emit `OnLatencySummary(medianMs, jitterMs)`.
- Download: 4 goroutines, each loops: GET `__down?bytes=50000000`, `io.Copy` the body
  into a counting sink (`atomic.Int64`) until the window `ctx` fires; a stream that
  finishes early loops again (keeps the pipe saturated).
- Upload: 2 goroutines, each loops: POST `__up` with a prefix of a prebuilt
  incompressible buffer at the current ladder size; credit the body size **only on a
  clean 2xx completion** (server acknowledged the whole body — matches macOS
  `completedBodies`, avoids counting local/tunnel buffer fill). Climb the ladder per
  completed body.
- Sampler goroutine: every 0.25 s snapshots the atomic counter and calls
  `OnSample(phase, offsetSeconds, bytes)`; the offset+bytes let Kotlin build the
  live sparkline series.
- A non-2xx response aborts the phase and surfaces the HTTP status via `OnError`
  rather than reporting a bogus rate.
- Final per-phase Mbps = `totalBytes * 8 / elapsedSeconds / 1e6`; emit
  `OnResult(downloadMbps, uploadMbps, medianLatencyMs, jitterMs)`.

### gomobile surface

```
// in package mobile (bound to Kotlin)
type SpeedTestSink interface {
    OnPhase(name string)                                  // "latency" | "download" | "upload"
    OnLatencySummary(medianMs, jitterMs float64)
    OnSample(phase string, offsetSeconds float64, bytes int64)
    OnResult(downloadMbps, uploadMbps, medianLatencyMs, jitterMs float64)
    OnError(msg string)
}
func (s *Session) RunSpeedTest(sink SpeedTestSink) error  // Tunnel; blocking; call off-thread
func (s *Session) CancelSpeedTest()
type DirectSpeedTest struct{ /* holds a cancel */ }
func NewDirectSpeedTest() *DirectSpeedTest
func (d *DirectSpeedTest) Run(sink SpeedTestSink) error   // Direct; blocking; call off-thread
func (d *DirectSpeedTest) Cancel()
```

gomobile constraints respected: only `string`, `int64`, `float64`, `bool`, `error`,
and interfaces of such methods cross the boundary (no slices/structs passed across).
Method names bind lowercased in Kotlin (`runSpeedTest`, `onSample`, …).

### Lifecycle

- `SpeedTestController.run(path)` sets phase state synchronously, then launches the
  blocking Go call on `Dispatchers.IO`. Tunnel uses
  `TunnelBahnVpnService.activeSession?.runSpeedTest(sink)`; Direct uses a fresh
  `DirectSpeedTest().run(sink)`.
- Cancel calls `cancelSpeedTest()` / `DirectSpeedTest.cancel()`, which cancels the
  Go engine's context; the blocking call returns and the coroutine completes.
- Auto-cancel: the controller collects `TunnelBahnVpnService.state`; if a Tunnel run
  is in flight and state leaves `STATE_RUNNING`, cancel it (analog of the macOS
  Combine sink on `$stats`). A Direct run is unaffected by path changes.
- `canRun`: Tunnel needs `state == STATE_RUNNING && activeSession != null`; Direct is
  always eligible.
- Results are in-memory for the session, one per path.

## UI

`SpeedTestScreen`:

- Two Material3 cards, side by side on wide layouts, stacked on narrow — **Tunnel**
  and **Direct**. Each card:
  - Download (↓, blue) and Upload (↑, green) hero `%.1f Mbps` numbers.
  - A Canvas sparkline per metric (area fill + line + dashed average rule) of the
    throughput series.
  - Latency/jitter footer: Latency `%.0f ms` (median), Jitter `%.1f ms`, plus a
    relative "tested … ago" stamp on finished cards.
  - A Run button; while running, a phase indicator (Latency → Download → Upload)
    with spinner/checkmark, live-ticking readouts, and a Cancel button.
  - Tunnel Run disabled unless VPN connected.
- **Comparison strip** below the cards, shown once both results exist: signed
  percentage deltas for Download/Upload and signed ms deltas for Latency/Jitter,
  color-coded green/red/neutral (neutral bands: 3 % throughput, 2 ms timing).

## Testing

- Go unit tests: `speedtest_math_test.go` (median, jitter, Mbps) and
  `speedtest_test.go` (upload ladder progression `nextUploadBodyBytes`, adaptive
  window selection, completed-body accounting). Run with `go test ./...` in
  `android/core`.
- Kotlin unit tests: `speedtest/SpeedTestMathTest.kt` for `throughputSeries`,
  `deltaPercent`, `deltaSense`, extending the existing
  `app/src/test/java/tunnelbahn/app/` suite (alongside `SpeedFormatTest.kt`).
- Manual/e2e verification: run a Direct test with VPN off, then connect and run
  both Tunnel and Direct. Tunnel numbers must reflect the transport path and Direct
  the ISP path (they differ). Because `HeadlessDriver`'s own probe bypasses the VPN,
  do not rely on it to confirm the tunnel path; confirm via the exit-IP the Go core
  already reports (`OnExitInfo`) matching the Tunnel run, per the android-e2e notes.

## Non-goals

- No persistence of results to disk (in-memory per session, matching macOS).
- No new Kotlin networking library; all HTTP is done in the Go core (stdlib
  `net/http`), reusing the `exitprobe.go` transport-dial pattern.

## Compatibility

Per the repo no-legacy-code policy: no compat shims, no schema version fields, no
migrations. This is net-new UI and code.

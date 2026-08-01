# Speed Test Helper Process — Design

Date: 2026-08-01
Status: Approved pending user review
Extends: docs/superpowers/specs/2026-08-01-speed-test-design.md

## Purpose

In per-app (app-tunnel) mode, make both speed test cards (Tunnel and Direct) runnable at any time without reconnecting. A small helper executable ships inside the app bundle with its own signing identity; an NEAppRule always routes the helper through the tunnel, so the Tunnel card's transfers run in the helper while the Direct card's transfers keep running in the host app (which is no longer included in the per-app rules).

## Decisions settled in brainstorming

1. **Transport**: plain subprocess (`Process` + pipes), not XPC. The app has hardened runtime but is not sandboxed, so launching a child process needs no entitlement changes. The helper streams NDJSON progress on stdout; the host terminates the process to cancel.
2. **`includeHostAppInPerAppRulesForProbe`**: deleted (setting, AppSettings key, all call sites; no migration, app is undistributed). The connectivity probe moves into the helper, which is always tunneled, so probe fidelity improves and the host app is never included in per-app rules.
3. **Engine sharing**: the measurement engine is extracted from `SpeedTestService` into shared source files compiled into both the app and helper targets (same source-sharing pattern as the existing targets), not a SwiftPM package.
4. **Concurrency**: one run at a time. Starting a run disables the other card's Run button until it finishes.

## Helper target

- New `SpeedTestHelper` command-line tool target in `project.yml`:
  - `PRODUCT_BUNDLE_IDENTIFIER` / signing identifier `com.tunnelbahn.mac.speedtesthelper`, team 92G3VZAPVG, hardened runtime, automatic signing. No entitlements.
  - Embedded into the app at `Contents/MacOS/` (embed dependency with executables destination, code signed on copy).
  - Sources: helper `main.swift` plus the shared engine and probe sources listed by path (as the unit-test target already does).
- After editing `project.yml`, run `xcodegen generate`.

## Helper CLI and NDJSON protocol

Two modes selected by the first argument:

- `run`: executes the full speed test (latency, download, upload) via the shared engine and streams one JSON object per line on stdout:
  - `{"event":"phase","phase":"latency"|"download"|"upload"}`
  - `{"event":"sample","readout":"312 Mbps","offsetSeconds":…,"bytes":…}` (transfer phases; latency samples carry `"readout":"24 ms"`)
  - `{"event":"result", …full result payload: downloadMbps, uploadMbps, medianLatencyMs, jitterMs, downloadSamples, uploadSamples}` then exit 0
  - `{"event":"error","message":"…"}` then nonzero exit
- `probe --mode warmup|recheck`: runs the existing `TunnelConnectivityProbe` logic in-process (google204 attempts; ipify and DNS diagnostics for warmup) and prints a single JSON result line (`{"ok":true}` or `{"ok":false,"message":"…"}`).

The helper logs through `AppLog` with the same `com.tunnelbahn.mac` subsystem, so probe and speed test lines still appear in the in-app log capture. Cancellation is process termination; the helper needs no cancel protocol.

Behavior carried over unchanged into the shared engine: 50 MB per download request (Cloudflare returns HTTP 403 at 100 MB or more), any non-2xx response fails the run loudly, finished streams restart to keep the window saturated, cumulative bytes sampled every 250 ms.

## Host-side client

New service `SpeedTestHelperClient`:

- Locates the helper binary inside the app bundle; a missing binary fails the run with a clear error.
- Launches it with `Process`, parses NDJSON lines into typed events, surfaces them to `SpeedTestService`.
- Maps failure modes to run errors: nonzero exit without a `result` event, malformed lines, premature EOF.
- Terminates the process on cancel and on app quit.
- Also wraps `probe` invocations for `VPNManager` (returns the parsed probe result).

## Engine extraction

`ByteCountingSessionDelegate`, latency measurement, and the transfer-window logic move out of `SpeedTestService` into a non-MainActor `SpeedTestEngine` shared by both targets. The engine emits progress events (phase transitions, live readouts, cumulative byte samples) via an `AsyncStream` or callback; it has no UI or published state.

- `SpeedTestService` stays `@MainActor` and keeps UI state (phase, live readout, results, error/status notes). Direct runs consume the engine in-process; Tunnel runs consume `SpeedTestHelperClient` events. Both feed the same published properties.
- `SpeedTestMath`, `SpeedTestResult`, and `ThroughputSample` are reused as-is by the engine and the NDJSON payloads.

## VPNManager changes

- `makeHostAppNEAppRule` becomes `makeSpeedTestHelperNEAppRule`: signing identifier `com.tunnelbahn.mac.speedtesthelper`, designated requirement read from the embedded helper binary via `NEAppRuleBuilder.designatedRequirementString(forAppAtPath:)`, with the same generic-anchor fallback.
- In every app-tunnel branch (including destination-split), the helper rule is always appended; the `includeHostAppInPerAppRulesForProbe` gate disappears.
- `TunnelProbePhase` simplifies to `fullTunnel` / `appTunnel` (the host-included/excluded distinction no longer exists).
- Warmup and periodic probes run through the helper in all modes. In full tunnel the helper is tunneled like everything else, so probe behavior is uniform. The existing probe skip conditions are unchanged: no probe for destination-split connections or profiles without a default route.
- Host path classification: `stats.hostAppInternetPathIsTunnel` is true only when the tunnel has the default route and the connection is full-tunnel. In app-tunnel mode the host is always direct.

## Classification and UI

Cards map to fixed mechanisms: the Tunnel card always runs via the helper; the Direct card always runs in the host app.

Enablement:

- **Tunnel**: connected, tunnel has the default route, and the profile is not destination-split. (LAN-only and destination-split profiles cannot reach Cloudflare through the tunnel, so the card stays disabled with an explanatory tooltip.)
- **Direct**: the host's own path is direct: disconnected, or connected in app-tunnel mode.
- In app-tunnel mode both cards are enabled; full-tunnel mode keeps today's behavior (Tunnel only while connected, Direct requires disconnect).
- One run at a time: starting a run disables the other card's Run button until the run finishes.
- Any VPN state or path-classification change mid-run auto-cancels the run with "Test cancelled: traffic path changed".
- Tooltips updated to the new rules via the question-mark `.instantTooltip` idiom, one or two short sentences, no em dashes.

Result labeling is unchanged: tunnel results carry the connected profile name.

## Testing

- Existing `SpeedTestMath` unit tests are unchanged.
- New unit tests: NDJSON event encode/decode round-trip, and helper-client line parsing fed with canned stdout (result, error, malformed, premature EOF).
- The engine extraction is verified by the existing manual flows plus a build of both targets; end-to-end helper behavior (rule matching, tunneled transfers) is verified manually through app-tunnel and full-tunnel connections.
- Build: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build`; tests via `TunnelBahnUnitTests`.

## Non-goals

- No XPC service, no persistent helper daemon; the helper runs only for the duration of a test or probe.
- No concurrent tunnel+direct runs.
- No changes to full-tunnel routing behavior or to the measurement methodology.

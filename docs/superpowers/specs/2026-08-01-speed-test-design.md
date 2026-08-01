# In-App Speed Test — Design

Date: 2026-08-01
Status: Approved pending user review

## Purpose

A full-suite speed test (download, upload, latency, jitter) runnable from inside TunnelBahn, measuring the path the app's own traffic takes. Results are kept in two slots — Tunnel and Direct — shown side by side so the user can quantify tunnel overhead.

## Scope

- New dedicated **Speed Test** tab in `ContentView`'s tab enum, between Monitoring and Logs, SF Symbol `gauge.with.needle`, rendering `SpeedTestView.swift`.
- New service `TunnelBahn/Services/SpeedTestService.swift`, owned by `AppState` so a run survives tab switches and view teardown.
- Pure measurement math in a testable helper with unit tests in `Tests/`.
- No persistence: results are in-memory, latest run per slot, cleared on quit.

## Measurement engine

`SpeedTestService` is a `@MainActor` observable class with `run()` and `cancel()`. A run executes three phases sequentially against Cloudflare's speed-test endpoints, using a dedicated ephemeral `URLSession` (no cache, no cookies) so caching cannot inflate numbers.

1. **Latency**: 8 sequential `GET https://speed.cloudflare.com/__down?bytes=0` requests. Report median latency (ms) and jitter as mean absolute deviation from the median (ms). The first request is discarded as connection warmup.
2. **Download**: 4 parallel `GET __down?bytes=50000000` streams for a measurement window (Cloudflare rejects requests of 100 MB or more with HTTP 403). The 50 MB is a per-request size, not a per-window total: a stream that finishes before the window ends is immediately restarted so the connection stays saturated for the full window. Received bytes are counted via `URLSession` data-task delegate callbacks; at window end, outstanding tasks are cancelled. Throughput = total bytes in window / elapsed. The window is 8 s, extended to 16 s when median latency is 400 ms or more, so TCP slow-start ramp does not dominate the average on high-RTT paths.
3. **Upload**: 2 parallel `POST __up` streams of pre-generated random data for the same window. Upload credits a request's full body size only when the request completes cleanly: completion means the server consumed the whole body, so it is server acknowledgment. Counting `didSendBodyData` instead would measure how fast bytes enter local socket or tunnel buffers, which over the app's own userspace relay inflates rates by orders of magnitude. Body sizes climb a ladder (256 KB, 1 MB, 4 MB, 16 MB) as requests complete, so slow paths complete several small bodies per window while fast paths reach large bodies and are not request-rate bound; a request still in flight at window end earns no credit. Throughput = credited bytes in window / elapsed.

During download and upload, cumulative byte counts are sampled every ~250 ms. Each sample yields an instantaneous Mbps value; the full series is stored with the result for plotting.

### Result model

Per run: download Mbps, upload Mbps, median latency ms, jitter ms, timestamp, path label (tunnel or direct, plus profile name when tunneled), and the two throughput sample series (download, upload).

### Errors and cancellation

- Any phase failure aborts the run; the view shows a one-line inline error ("Speed test failed: <reason>"). The slot keeps its previous result.
- User cancel resets to idle; previous results are untouched.
- If the tunnel connects, disconnects, or reasserts mid-run (traffic path changes), the run auto-cancels with the note "Test cancelled: traffic path changed". No partial result is stored.

## Path classification

Every run is valid; there is no gating. Before starting, the service classifies the app's current traffic path deterministically from existing `VPNManager` state (the same inputs as the `probePhase` computation in `VPNManager.swift`):

- **Tunnel**: connected, and the phase would be `.fullTunnel` or `.appTunnelHostIncluded`, and the profile is not destination-split.
- **Direct**: disconnected; or connected in app-tunnel mode with the host app excluded; or destination-split (internet traffic bypasses the tunnel).

The finished result is stored into the matching slot. Rerunning on the same path replaces only that slot, so a Direct baseline survives connect/disconnect cycles within the session.

## UI (`SpeedTestView`)

- **Per-card Run buttons**: each card (Tunnel, Direct) carries its own Run button, enabled only while the app's current traffic path matches that card; the path is deterministic, so exactly one button is enabled at a time. The disabled card's question-mark tooltip explains how to enable it ("Connect a tunnel to enable this test." / "Disconnect the tunnel to test the direct path. A full tunnel cannot be bypassed."); the enabled card's tooltip explains what is measured. Cancel replaces Run on the card whose test is running (per UI convention: tooltip, one or two short sentences, no em dashes).
- **While running**: the active card shows the phase label (Latency, Download, Upload) with live readout (running ms or Mbps) and a progress indicator in its body.
- **Results**: two side-by-side cards, Tunnel and Direct. Each shows Download, Upload, Latency, Jitter, "tested <relative time>", and two compact Swift Charts line/area sparklines (~60 pt tall) of the download and upload throughput series. An empty card shows placeholder text explaining how to fill it (connect or disconnect first, phrased per which slot is empty).
- **Delta row**: when both slots are filled, secondary text summarizes tunnel overhead: throughput as signed percentages, latency and jitter as signed ms.

## Testing

- Unit tests cover the pure math: median/jitter from latency samples, throughput from byte counts and timestamps, per-interval sample series derivation, and delta-row computation.
- The network layer is thin (URL construction, delegate byte counting, windowing) and verified manually through tunnel and direct paths.

## Non-goals

- No persistent history or history charts.
- No server selection or custom endpoints (Cloudflare anycast only).
- No forcing traffic onto a specific interface; the test always measures the app's natural traffic path.

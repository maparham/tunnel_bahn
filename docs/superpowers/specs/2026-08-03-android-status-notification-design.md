# TunnelBahn for Android — Status Notification (speed + exit location) — Design

Date: 2026-08-03
Status: Approved

## Problem

The Android client shows connection state and an elapsed-time counter on the Home
screen, but gives the user no live sense of the tunnel's throughput or where its exit
egresses. We want a compact status surface showing **download speed, upload speed, and
the exit-IP location** while connected.

The user chose the **ongoing foreground-service notification** as the sole surface (the
literal Android status bar / shade), not a new in-app screen. This keeps the info glanceable
without opening the app, and reuses the notification the `VpnService` already posts.

## Goal / Acceptance

- While connected, the ongoing notification shows:
  - **Download and upload speed** of tunneled traffic, updated ~once per second.
  - **Exit-IP location** as country + city (with the raw exit IP available), or
    `Locating…` until the probe returns.
- The speed numbers reflect **tunneled traffic only** — bytes that actually traverse the
  SSH/WGWS transport. Bypass-classified flows (exclude mode / split tunnel) are not counted.
- The exit-IP/geo lookup is performed **through the tunnel transport**, so it reflects the
  real server egress and never bypasses the VPN (see the false-PASS pitfall below).
- `POST_NOTIFICATIONS` is requested at runtime so the notification is actually visible on
  Android 13+.
- No server changes. No new profile fields required (ipinfo endpoint is a build-time
  constant for v1).

## Non-goals (v1)

- **A second in-app stats screen.** The notification is the surface. A one-line in-app hint
  appears only when the notification permission is denied.
- **Historical graphs / totals / per-app breakdown.** Instantaneous speed + one location
  line only.
- **Re-probing the exit IP on every reconnect.** The exit IP is the server's and is stable
  per profile; probe once per session.
- **A configurable geo provider or an API token.** `ipinfo.io/json` unauthenticated is
  sufficient for personal/sideload use. Swapping providers later touches one Go constant.
- **Wire-level accounting.** Speeds are inner-payload goodput, not on-the-wire bytes.

## Key constraint: the exit probe must egress through the transport

Recorded pitfall (`android-e2e-driver-false-pass`): a probe issued from the app's **own
package** bypasses the VPN when that package is disallowed from the tunnel, so a Kotlin
`HttpURLConnection` to an ip-echo service does **not** measure the tunnel egress. The exit-IP
probe therefore runs **inside the Go core**, dialing through `transport.Transport.DialTCP`,
which is authoritative for what the server actually egresses.

## Architecture

Same strict boundary as the base design: Go core owns all packet movement and the network
probe; Kotlin owns OS integration, polling, and rendering. Two additions cross the gomobile
seam — a pull API for byte counts, and a push callback for the exit info.

```
┌─ Kotlin / Android ─────────────────────────────────────────┐
│  TunnelBahnVpnService                                       │
│    • 1s poller: reads Session.RxBytes()/TxBytes(),          │
│      computes per-second deltas, re-posts notification      │
│    • OnExitInfo(ip,city,country) → StateFlows + notif line  │
│    • requests POST_NOTIFICATIONS (API 33+) via MainActivity │
└───────────────┬─────────────────────────────────────────────┘
                │ gomobile
                │  pull:  RxBytes():Long, TxBytes():Long
                │  push:  EventSink.OnExitInfo(ip,city,country)
┌───────────────▼─ Go core ───────────────────────────────────┐
│  coreProxy (engine.go)                                       │
│    • wraps tunnel-branch conns in a counting conn:           │
│        Write→TX (upload), Read→RX (download), atomic adds    │
│    • counters live on Session; probe & DNS bypass the count  │
│  exitProbe (new): on first "running", GET ipinfo.io/json     │
│    through tr.DialTCP; ctx tied to stopCh; report OnExitInfo │
└──────────────────────────────────────────────────────────────┘
```

## Byte counting (Go core)

**Tap point:** `coreProxy`, tunnel branches only.

- In `coreProxy.DialContext`, when `route == "tunnel"`, wrap the `net.Conn` returned by
  `p.tr.DialTCP(ctx, dst)` in a counting `net.Conn`.
- In `coreProxy.DialUDP`, the `"tunnel"` case wraps the `net.PacketConn` returned by
  `p.tr.DialUDP` (count `WriteTo` bytes as TX, `ReadFrom` bytes as RX).
- The `"dns"` and `"bypass"` branches are **not** wrapped, so DNS-over-TCP and direct
  bypass traffic do not inflate the numbers. The exit probe calls `tr.DialTCP` directly,
  outside `coreProxy`, so it is excluded too.

**Direction (verified against tun2socks relay semantics):** tun2socks copies app→proxyConn
(this is upload to the server) and proxyConn→app (download from the server). On the wrapped
proxy conn, therefore, `Write` = **TX/upload** and `Read` = **RX/download**.

**Counters:** two `atomic.Uint64` (rx, tx) owned by the `Session` and shared into the
`coreProxy` (e.g. a small `*counters` struct passed to `newCoreProxy`). Reset per session
(a fresh `Session`/proxy is built on each `Start`).

**gomobile surface:**

```go
// mobile.Session (delegates to core.Session)
func (s *Session) RxBytes() int64
func (s *Session) TxBytes() int64
```

Pull model: Go stays tickerless; Kotlin polls and computes deltas. `int64` because gomobile
does not bind unsigned types; cumulative byte counts fit comfortably for a session.

## Exit-IP + geo probe (Go core)

- Triggered once, on the first transition to `running` (the point where `Session.Start`
  currently calls `sink.OnState("running")`).
- One goroutine:
  1. Dial `ipinfo.io:443` via `tr.DialTCP(ctx, …)` (through the tunnel).
  2. `tls.Client` over that conn with `ServerName: "ipinfo.io"` and **real** cert
     verification (this is a public host with a valid cert, unlike the WG carrier).
  3. HTTP/1.1 `GET /json` with `Host: ipinfo.io`, `Accept: application/json`, a UA header.
  4. Parse `{ "ip", "city", "region", "country" }`.
  5. `sink.OnExitInfo(ip, city, country)`.
- **Context tied to `stopCh`:** Stop cancels an in-flight request so the probe never
  outlives the session or pins the transport during teardown.
- **Retries:** a small bounded retry (e.g. up to 3 attempts with backoff) on failure, then
  give up silently — the notification keeps showing `Locating…`. **No re-probe on reconnect.**
- ipinfo endpoint/host is a Go constant for v1.

**core.EventSink / mobile.EventSink gain:**

```go
OnExitInfo(ip, city, country string)
```

with the corresponding `sinkAdapter` delegate in `mobile/mobile.go`.

## Kotlin side

**Service state (new `StateFlow`s on the companion):**

- `exitIp: StateFlow<String>`, `exitLocation: StateFlow<String>` (e.g. `"Berlin, Germany"`),
  set from `OnExitInfo`. Country code is mapped to a full name / left as-is; keep the string
  short for the notification.
- Optionally `downSpeed`/`upSpeed` flows if any future in-app view wants them; the
  notification path can read local poller state directly.

**Poller lifecycle:**

- Started when the `Sink.onState` sees `running`; a `Handler(Looper.getMainLooper())`
  `postDelayed` loop at 1s.
- Each tick: read `session.RxBytes()/TxBytes()`, subtract the previous sample to get
  bytes/sec, rebuild and `NotificationManager.notify(NOTIF_ID, …)`. The **first** tick has no
  previous sample → report `0`, not a garbage delta.
- **Stopped in `endSession` BEFORE nulling `session` and BEFORE `stopForeground(REMOVE)`**,
  so a late `notify()` cannot re-post a notification after teardown and `session?.RxBytes()`
  cannot race the null.

**Notification content:**

- Content title: `TunnelBahn`.
- Content text: `↓ 1.2 MB/s  ·  ↑ 240 KB/s` (humanized).
- Second line via `Notification.BigTextStyle`: the location (`Berlin, Germany`) or
  `Locating…` until the probe returns, so a long city name is not truncated.
- `setOnlyAlertOnce(true)` (no sound/vibration on each update), middle-dot separator, **no
  em dash** (UI rule).

**Speed formatting:** a pure `humanizeSpeed(bytesPerSec: Long): String` → `B/s`, `KB/s`,
`MB/s` with one decimal above 1 KB/s. Unit-tested.

## POST_NOTIFICATIONS (the gate)

`targetSdk = 35`; the permission is declared but never requested at runtime today. Because
the notification is the only status surface, the app must request `POST_NOTIFICATIONS` on
API 33+:

- A `RequestPermission` launcher fired from `MainActivity` / Home, at app start or at first
  connect.
- **Denied fallback:** a single in-app line on the connection screen noting that live speed
  and exit location are shown in the notification and require notification permission (with a
  shortcut to app settings). This is a minimal hint, not a second full stats surface.

## Data flow

```
tunneled TCP/UDP flow
  → coreProxy tunnel branch → counting conn (atomic rx/tx adds)
  → transport → server

first "running"
  → exitProbe goroutine → tr.DialTCP(ipinfo.io:443) → TLS → GET /json
  → OnExitInfo(ip, city, country) → Kotlin StateFlows

every 1s while running
  → poller reads Session.RxBytes()/TxBytes() → delta → humanize
  → rebuild notification (speeds + location) → notify(NOTIF_ID)

Stop / teardown
  → stopCh cancels probe ctx
  → endSession stops poller, then nulls session, then stopForeground(REMOVE)
```

## Error handling

- **Probe failure** (unreachable ipinfo, TLS error, malformed JSON): retry a few times, then
  leave the location as `Locating…`; never crash, never block the tunnel.
- **Poller read after teardown:** structurally prevented by stopping the poller before
  nulling `session`.
- **Notification permission denied:** the tunnel still runs; the in-app hint tells the user
  why the live line is absent.
- **Counter overflow:** not a concern for a session's cumulative `int64` byte total.

## Testing

- **Go unit:** counting-conn wrapper tallies both directions correctly (TX on write, RX on
  read); a `WriteTo`/`ReadFrom` variant for the UDP path. ipinfo JSON response parses into
  ip/city/country.
- **Go unit:** probe honors context cancellation (Stop mid-flight returns promptly).
- **Kotlin unit:** `humanizeSpeed` boundaries (B/KB/MB, rounding) and the per-second delta
  computation (first sample → 0; monotonic counters → non-negative deltas).
- **On-device e2e:** connect, confirm the notification shows advancing speeds under load and
  a plausible exit location matching the server; deny POST_NOTIFICATIONS and confirm the
  in-app hint appears and the tunnel still works.

## Open questions

None blocking. Provider choice (ipinfo) and permission-denied UX are settled above; both are
one-file changes if revisited.

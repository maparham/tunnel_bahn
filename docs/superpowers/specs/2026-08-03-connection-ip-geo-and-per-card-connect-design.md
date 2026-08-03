# Connection view: origin/exit IP + geo, and per-card Connect

Date: 2026-08-03
Branch: android-client

## Goal

Two related changes to the Android connection surface:

1. **Show the original (pre-VPN) and exit IP with geo location on the connection view.**
   Today the exit IP/geo is computed but surfaced only in the ongoing notification; the
   origin IP is not computed at all. The user wants a before/after picture on-screen.
2. **Give each profile card a Connect button, drop "Set active", and make the
   last-connected profile the active one automatically.**

Both reshape the connection/profile surface, so they ship as one spec and one plan.

## Background (current state)

- **Exit probe already exists.** `core/exitprobe.go` `runExitProbe` fetches exit IP + geo
  once per session *through the transport* (so it reflects the real server egress and never
  bypasses the VPN), and pushes it via `EventSink.OnExitInfo(ip, city, country)`.
  `TunnelBahnVpnService.Sink.onExitInfo` writes the `exitIp` / `exitLocation`
  `MutableStateFlow`s. Those flows feed **only the notification** (`buildNotification`),
  not the connection view.
- **`EventSink` has a single implementor** (the service's inner `Sink`), so extending it is
  low-risk; `HeadlessDriver` does not implement it.
- **Origin IP is not computed anywhere.**
- **`formatLocation(city, countryCode)`** (`ui/SpeedFormat.kt`) already renders
  "City, Country" from a 2-letter country code; reuse it for both origin and exit.
- **Selection model:** `ProfileStore.selectedId()` (prefs `SELECTED_KEY`, falling back to
  first profile) is the "active" profile Home acts on. `ProfilesScreen.ProfileRow` shows a
  "Set active" button (`setSelectedId` + `onBack`) and highlights the active card.
- **`onStartCommand`** builds a tun and a new Go `Session` on every start intent. It does
  **not** guard against an already-running session, so a naive second start would leave two
  live sessions racing on teardown. This must be handled for profile switching.

Key invariant from prior work: the app's own sockets bypass its own VPN in every routing
mode. Therefore a plain direct socket returns the device's real carrier IP whether the
tunnel is up or down. The origin IP is identical in both states.

## Design

### Feature A: origin + exit IP/geo on the connection view

**Origin probe lives in Go, session-independent.** Because origin must show while
disconnected (no `Session`, no `Protector` exists then) and the value is identical
connected vs. disconnected, the origin probe is a standalone call, not launched from inside
the session goroutine.

- **New `core/originprobe.go`:** `ProbeOrigin(ctx) (ip, city, country string, err error)`.
  Plain `http.Client` with a default `DialContext` (no Protector, no transport) GET to
  `https://ipinfo.io/json`, 15s timeout, reusing `parseIPInfo`. No tunnel dependency.
  - The ipinfo host/URL constants and `parseIPInfo` already live in `exitprobe.go`; keep
    them shared (do not duplicate). No provider or parsing logic is added.
- **New `mobile` export:** `Mobile.ProbeOrigin()` returning the three strings (gomobile can
  return multiple strings + error). Blocking; callers run it off the main thread.
- **Kotlin state:** add `originIp` / `originLocation` `MutableStateFlow`s in
  `TunnelBahnVpnService` companion, mirroring `exitIp` / `exitLocation`.
- **Trigger:** a small helper runs `Mobile.ProbeOrigin()` on a background thread and writes
  the origin flows. It is kicked when the connection view is composed (Home
  `LaunchedEffect`), refreshed if origin is currently blank. The value persists across
  connect (it does not change), so no re-fetch on connect is required. Exit flows continue
  to populate via `onExitInfo` unchanged.

**UI (in `ConnectionHero`, below the profile/transport summary):**
- Collect `originIp`, `originLocation`, `exitIp`, `exitLocation` with lifecycle.
- **Disconnected / connecting:** a single row: `Your IP  <ip>  ·  <location>`.
  If origin not yet fetched, show `Your IP  Locating…`.
- **Running:** two labeled rows:
  - `You   <originIp>   <originLocation>`
  - `Exit  <exitIp>     <exitLocation>`  (Exit shows `Locating…` until the probe returns)
- Rendered as plain typographic rows (label in `onSurfaceVariant`, value in `onSurface`,
  monospace/tabular for the IP) inside the hero column — not a separate card — to match the
  screen's existing flat hierarchy. Fixed vertical slot so connect does not jump the layout.
- Remove the notification-only framing note ("Live speed and exit location show in the
  notification…") since the info now lives on-screen; keep the notification itself.

### Feature B: per-card Connect, remove "Set active", last-connected = active

- **`ProfileRow` gains a Connect button.** Connect = `store.setSelectedId(id)` +
  `startVpn(ctx, id)`. This one action makes the last-connected profile the active one,
  satisfying the requirement without a separate "active" concept.
- **Remove the "Set active" button** and its `onSetActive` param. Keep the active-card
  highlight (CheckCircle + `secondaryContainer`); it now denotes the last-connected /
  currently-acted-on profile.
- **Running card shows Disconnect.** `ProfilesScreen` observes `TunnelBahnVpnService.state`
  and `selectedId`. The card whose id == `selectedId` while state is RUNNING/CONNECTING
  shows **Disconnect** (`stopVpn`) in place of Connect; other cards show **Connect**.
- **Switching is serialized in the service.** `onStartCommand` is made switch-safe: if a
  session is already active when a start intent arrives for a (different) profile, it stops
  the current session and defers the new connect until teardown finishes, via a
  `pendingProfileId` handed off from the worker's teardown path. Net guarantee: never two
  live sessions; tapping Connect on card B while A runs ends A and connects B, and B becomes
  active. Tapping Connect on the already-active running card is a no-op (or is presented as
  Disconnect, so it does not arise).
- `HomeScreen`'s existing act-on-`selectedId` behavior is unchanged; it now naturally
  reflects last-connected.

## Components and boundaries

- `core/originprobe.go` — origin fetch; depends only on `net/http` + shared ipinfo
  constants/`parseIPInfo`. Testable with `httptest`.
- `mobile.ProbeOrigin` — thin gomobile shim; no logic.
- `TunnelBahnVpnService` — owns origin/exit flows and the switch-safe start handoff.
- `ui/HomeScreen.ConnectionHero` — renders origin/exit rows; pure presentation over flows.
- `ui/MainScreen.ProfileRow` — Connect/Disconnect button; no store logic beyond
  `setSelectedId` + start/stop intents.

## Error handling

- Origin probe failure/timeout: leave `originIp` blank; UI keeps showing `Locating…`
  (or the last known value). No error surfaced to the user; origin is informational.
- Exit probe already retries 3x and gives up silently; unchanged. Exit row stays
  `Locating…` if it never returns.
- Switch handoff: if teardown of the old session fails or times out, the pending connect
  still fires; the OS-level tun replacement in `establish()` supersedes the old tun. The
  guarantee is "no two live Go sessions", enforced by starting the new session only from the
  teardown path.

## Testing

- **Go:** `originprobe_test.go` — happy path against an `httptest` server returning ipinfo
  JSON (assert ip/city/country), plus a non-200 / malformed-body / timeout case returning an
  error. `parseIPInfo` coverage already exists and is reused.
- **Kotlin:** a focused test that a Connect intent for profile B while A is "running" results
  in exactly one active session ending with B (logic-level around the pending-connect
  handoff; instrumented if a pure unit seam is not available).
- **Manual:** connect a profile, confirm the connection view shows You (real IP/geo) and
  Exit (server IP/geo); disconnect and confirm the single origin row remains; from Profiles,
  Connect on a second profile while the first runs and confirm a clean switch with the second
  becoming active.

## Out of scope / YAGNI

- No new geo provider, no flags/emoji, no per-session origin re-fetch, no origin caching to
  disk. No "current IP when disconnected" beyond the single on-demand probe. No copy-to-
  clipboard on the IPs (can add later if wanted).

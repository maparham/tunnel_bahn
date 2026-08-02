# Android UI/UX Rework Design

**Date:** 2026-08-02
**Status:** Proposed
**Context:** First on-device use of the Android client surfaced four pieces of feedback: (1) no-app selection should mean full tunnel, (2) the app picker needs search, (3) the UI/UX is primitive, (4) an SSH profile appears duplicated. Plus a follow-up: haptic feedback on connect success and on connect failure.

## Goal

Rework the Android client's UI/UX around a connection-centric home screen and a single, unambiguous split-tunneling model, add app-list search, and give tactile feedback on connect/fail. Fix the e2e driver so it stops polluting real profiles.

## Diagnosis of the reported bugs

- **"Duplicated SSH profile" (point 4)** is leftover e2e state, not a save bug. `HeadlessDriver` seeds throwaway profiles into the real `ProfileStore`; each run added a distinct-id row. The index is a `Set`, so re-saving one id cannot duplicate. Fix = clean the device + stop the driver polluting (below).
- **"Not a full tunnel" (point 1)** is the same leftover state: the last successful seed was `appMode=INCLUDE, packages=[tunnelbahn.app]` (tunnel only the app itself). Connecting that profile tunnels almost nothing. A freshly-created profile already routes `0.0.0.0/0` and tunnels all apps. The real fix is UX clarity, not the default.

## Design

### 1. Split-tunneling model (replaces the two-axis confusion)

Replace `AppMode { INCLUDE, EXCLUDE }` with a single tri-state `AppScope`:

```kotlin
enum class AppScope { FULL, ONLY_SELECTED, EXCEPT_SELECTED }
```

- `FULL` (default): tunnel every app. This is the explicit "full tunnel VPN."
- `ONLY_SELECTED`: tunnel only `packages`.
- `EXCEPT_SELECTED`: tunnel every app except `packages`.

`packages` stays. The editor shows the three-way selector; the "Choose apps" button appears only when scope is not `FULL`. Per-destination CIDR rules (`routingMode`/`includeCIDRs`/`excludeCIDRs`, unchanged) move into a collapsed **Advanced** section — they are orthogonal (they filter destinations within tunneled apps' traffic) and default to route-everything.

`toCoreConfigJson()` is unaffected: per-app filtering happens at the `VpnService` layer, not in the Go core, so the core JSON (`mode`, CIDRs, ssh/wg blocks) does not change. Only `TunnelBahnVpnService.applyPerApp` changes:

- `FULL` -> disallow own package only (all other apps tunneled).
- `ONLY_SELECTED` -> `addAllowedApplication` for each package (own app naturally excluded -> no carrier loop).
- `EXCEPT_SELECTED` -> `addDisallowedApplication` for each package + disallow own.

No-legacy policy: the app is undistributed, so `AppMode` is removed outright with no migration.

### 2. Connection-centric home screen

Navigation becomes three screens (still no nav library; extend the `Screen` sealed type):

- `Home` — hero connect/disconnect control, active profile name + transport, live state, elapsed time, and a one-line routing summary ("Full tunnel" / "3 apps" / "All except 2 apps"). A "Profiles" affordance opens the list.
- `Profiles` — the list (today's `MainScreen`), for add/edit/delete/select.
- `Editor` — today's editor with the new routing selector + searchable picker + Advanced CIDR.

A persisted `selectedProfileId` (in plain prefs via `ProfileStore`) records which profile Home acts on; defaults to the first profile, updated when the user connects or picks one. Home's connect button starts `TunnelBahnVpnService` with that id.

**Elapsed time + state:** `TunnelBahnVpnService` already exposes a `state` StateFlow. Add `connectedSince: MutableStateFlow<Long>` (epoch millis, 0 when not running), set when state -> RUNNING, cleared on teardown. Home renders `now - connectedSince` on a 1s tick.

### 3. Searchable app picker (+ icons)

`AppPickerScreen`: add a search `OutlinedTextField` at the top that filters the already-loaded `apps` by label or package (case-insensitive). Add each app's launcher icon (loaded lazily per row via `pm.getApplicationIcon`, remembered by package). Drop the picker's own INCLUDE/EXCLUDE radio — scope now lives in the editor; the picker is pure multi-select. Note: only launcher apps are listed (unchanged); background-only packages remain out of scope.

### 4. Haptic feedback on connect / fail

Add `VIBRATE` permission (normal, no runtime prompt). A small `Haptics` helper wraps the `Vibrator`/`VibratorManager` service with two distinct patterns:

- **Success** (reached RUNNING): one firm ~120ms pulse.
- **Failure** (failed to connect): a triple short-buzz pattern so it feels clearly different.

Both are fired **from the service**, not from a UI observer. The service `state` is a conflated `MutableStateFlow`, and on a failed connect the Go core returns and teardown sets DISCONNECTED almost immediately, so an ERROR value would be overwritten before any collector resumes. Instead: success buzzes in `Sink.onState` at the RUNNING edge; failure is defined as ending a session that never reached RUNNING and was not a user stop (`reachedRunning`/`userStopping` flags), and buzzes there. The service also **latches** STATE_ERROR on that path (teardown does not clobber it to DISCONNECTED), so the Home "Failed to connect" label survives until the next connect clears it. Firing from the service also means feedback is not missed when Home is not composed.

### 5. E2e driver hygiene

`HeadlessDriver` deletes its seeded profile from `ProfileStore` after the probe completes (in the `finally`/finish path). The service has already loaded the profile into memory by then, so deletion is safe. This stops each e2e run from leaving a row behind. Existing leftover rows on the connected device are removed manually (after showing the user what is there).

## Constraints (carried from project memory)

- No em dashes in UI strings; tooltips one or two short sentences; questionmark + tooltip idiom, never inline footnotes.
- No legacy/compat/migration code (undistributed app).
- Keys never in plain profile JSON (unchanged; secrets stay in `EncryptedSharedPreferences`).

## Files touched

- `profile/Profile.kt` — `AppMode` -> `AppScope`; field rename `appMode` -> `appScope`.
- `vpn/TunnelBahnVpnService.kt` — `applyPerApp` tri-state; `connectedSince` flow.
- `profile/ProfileStore.kt` — `selectedProfileId` get/set.
- `ui/AppRoot.kt` — add `Home`/`Profiles` screens to nav.
- `ui/HomeScreen.kt` (new) — hero connect UI + elapsed + haptics.
- `ui/MainScreen.kt` — becomes the Profiles list (polished cards).
- `ui/ProfileEditor.kt` — tri-state routing selector + Advanced CIDR section.
- `ui/AppPickerScreen.kt` — search + icons, drop mode radio.
- `ui/Haptics.kt` (new) — success/failure vibration helper.
- `AndroidManifest.xml` — `VIBRATE` permission.
- `debug/HeadlessDriver.kt` — delete seeded profile after run.

## Testing

- Unit/Robolectric: `AppScope` mapping in `applyPerApp` (FULL/ONLY/EXCEPT produce the expected allow/disallow calls) via a fake Builder or logic extraction; app-filter search predicate; `selectedProfileId` round-trip.
- On-device (when phone reconnected): clean leftover profiles; create a fresh Full-tunnel profile and confirm all-app egress; verify search filters; confirm success buzz on connect and failure buzz on a deliberately bad profile; confirm driver no longer leaves rows.

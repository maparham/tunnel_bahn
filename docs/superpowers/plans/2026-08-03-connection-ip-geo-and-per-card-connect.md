# Connection IP/Geo Display + Per-Card Connect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the original (pre-VPN) and exit IP + geo on the Android connection view, and replace the profile "Set active" button with a per-card Connect/Disconnect so the last-connected profile is automatically the active one.

**Architecture:** A new session-independent Go origin probe (`core.ProbeOrigin`) reuses the existing ipinfo parsing and is bound to Kotlin via `mobile.ProbeOrigin`. Kotlin holds `originIp`/`originLocation` flows (mirroring the existing `exitIp`/`exitLocation`), renders both on `ConnectionHero`, and the profile list gains a Connect/Disconnect button whose action makes last-connected = active. Profile switching is serialized in the VpnService via a pending-connect handoff so there are never two live sessions.

**Tech Stack:** Go (gomobile/gobind), Kotlin + Jetpack Compose (Material3), Android VpnService.

## Global Constraints

- **No legacy code:** app is undistributed. Never add compat shims, schemaVersion fields, or migrations. (memory: no-legacy-code-policy)
- **No em dashes in UI strings.** Keep any tooltip to one or two short sentences. (memory: no-em-dashes-short-tooltips)
- **Origin/exit geo logic lives in Go**, reusing `parseIPInfo`; do not duplicate the provider or JSON parsing in Kotlin.
- **gomobile binding limits:** a bound Go func returns at most two values and the second must be `error`. Multi-string results MUST be wrapped in a struct with exported string fields.
- **gomobile field naming:** name struct fields `Ip`, `City`, `Country` (not `IP`) so the generated Java getters are `getIp()/getCity()/getCountry()` and Kotlin sees clean `.ip/.city/.country` properties.
- **Java package prefix is `tunnelbahn`** (from `build-core.sh -javapkg`), so bound types are `tunnelbahn.mobile.Mobile`, `tunnelbahn.mobile.OriginInfo`.
- **Rebuild the AAR** with `android/build-core.sh` after any Go change under `android/core` before the Kotlin side can see it.
- **Country rendering** uses the existing `formatLocation(city, countryCode)` in `ui/SpeedFormat.kt`; reuse for both origin and exit.
- **Test convention (follow existing repo pattern):** pure Go and pure Kotlin helpers are unit-tested (TDD). Compose UI and VpnService lifecycle are not unit-tested in this repo; verify those by build + manual/instrumented checks. Do not invent brittle network-dependent tests for the service.

---

## File Structure

- **Create** `android/core/originprobe.go` — `ProbeOrigin(ctx) (ip, city, country string, err error)`, direct HTTP, reuses `parseIPInfo`/`ipinfoURL`.
- **Create** `android/core/originprobe_test.go` — httptest coverage.
- **Modify** `android/core/mobile/mobile.go` — add `OriginInfo` struct + `ProbeOrigin()` binding.
- **Modify** `android/app/.../vpn/TunnelBahnVpnService.kt` — add `originIp`/`originLocation` flows; make `onStartCommand` switch-safe (extract `beginConnect`, add `pendingProfileId`); clear origin flows on teardown only when not switching.
- **Create** `android/app/.../vpn/OriginProbe.kt` — background trigger that runs `Mobile.probeOrigin()` and writes the origin flows.
- **Modify** `android/app/.../ui/HomeScreen.kt` — render origin/exit rows in `ConnectionHero`; trigger origin probe; remove the notification-only note.
- **Create** `android/app/.../ui/ProfileCardAction.kt` — pure `profileCardAction(isActive, state)` helper.
- **Create** `android/app/src/test/java/.../ui/ProfileCardActionTest.kt` — unit test for the helper.
- **Modify** `android/app/.../ui/MainScreen.kt` — `ProfileRow` Connect/Disconnect button, remove "Set active"; `ProfilesScreen` observes VPN state.

---

## Task 1: Go origin probe

**Files:**
- Create: `android/core/originprobe.go`
- Test: `android/core/originprobe_test.go`

**Interfaces:**
- Consumes: `parseIPInfo(body []byte) (ip, city, country string, err error)`, `ipinfoURL` const — both from `android/core/exitprobe.go`.
- Produces: `func ProbeOrigin(ctx context.Context) (ip, city, country string, err error)`

- [ ] **Step 1: Write the failing test**

Create `android/core/originprobe_test.go`:

```go
package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestProbeOriginHappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ip":"1.2.3.4","city":"Tehran","country":"IR"}`))
	}))
	defer srv.Close()

	ip, city, country, err := probeOriginAt(context.Background(), srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if ip != "1.2.3.4" || city != "Tehran" || country != "IR" {
		t.Fatalf("got %q/%q/%q", ip, city, country)
	}
}

func TestProbeOriginNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	if _, _, _, err := probeOriginAt(context.Background(), srv.URL, srv.Client()); err == nil {
		t.Fatal("expected error on 500")
	}
}

func TestProbeOriginBadBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	}))
	defer srv.Close()
	if _, _, _, err := probeOriginAt(context.Background(), srv.URL, srv.Client()); err == nil {
		t.Fatal("expected error on malformed body")
	}
}

func TestProbeOriginTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write([]byte(`{"ip":"1.2.3.4"}`))
	}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, _, _, err := probeOriginAt(ctx, srv.URL, srv.Client()); err == nil {
		t.Fatal("expected timeout error")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test -run TestProbeOrigin ./...`
Expected: FAIL (compile error: `probeOriginAt` / `ProbeOrigin` undefined).

- [ ] **Step 3: Write minimal implementation**

Create `android/core/originprobe.go`. It splits an injectable `probeOriginAt` (for tests) from the public `ProbeOrigin` (fixed URL, direct client). `parseIPInfo` and `ipinfoURL` already exist in `exitprobe.go`.

```go
package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// ProbeOrigin fetches the device's real (pre-VPN) IP + geo over a plain direct socket.
// It is session-independent: the app's own sockets bypass the tunnel in every routing
// mode, so this returns the true carrier IP whether or not a tunnel is running. Blocking;
// call off the main thread. Reuses the ipinfo provider + parser shared with the exit probe.
func ProbeOrigin(ctx context.Context) (ip, city, country string, err error) {
	client := &http.Client{Timeout: 15 * time.Second}
	return probeOriginAt(ctx, ipinfoURL, client)
}

func probeOriginAt(ctx context.Context, url string, client *http.Client) (ip, city, country string, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", "", "", err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "TunnelBahn-Android/1.0")
	resp, err := client.Do(req)
	if err != nil {
		return "", "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", "", fmt.Errorf("origin probe: status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return "", "", "", err
	}
	ip, city, country, err = parseIPInfo(body)
	if err != nil {
		return "", "", "", err
	}
	if ip == "" {
		return "", "", "", fmt.Errorf("origin probe: empty ip")
	}
	return ip, city, country, nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android/core && go test -run TestProbeOrigin ./...`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add android/core/originprobe.go android/core/originprobe_test.go
git commit -m "feat(core): session-independent origin IP + geo probe"
```

---

## Task 2: Bind ProbeOrigin to Kotlin

**Files:**
- Modify: `android/core/mobile/mobile.go`

**Interfaces:**
- Consumes: `core.ProbeOrigin(ctx) (ip, city, country string, err error)` from Task 1.
- Produces (bound to Kotlin as `tunnelbahn.mobile`): `class OriginInfo { getIp(): String; getCity(): String; getCountry(): String }` and static `Mobile.probeOrigin(): OriginInfo` (throws on error).

- [ ] **Step 1: Add the struct and binding**

In `android/core/mobile/mobile.go`, add `import "context"` to the import block, then add near the other exported types:

```go
// OriginInfo is the pre-VPN IP + geo, returned by ProbeOrigin. Fields are named Ip (not
// IP) so gomobile emits getIp()/getCity()/getCountry() and Kotlin sees .ip/.city/.country.
type OriginInfo struct {
	Ip      string
	City    string
	Country string
}

// ProbeOrigin fetches the device's real (pre-VPN) IP + geo. Blocking; call off the main
// thread. Returns an error the Kotlin side can catch and treat as "not yet known".
func ProbeOrigin() (*OriginInfo, error) {
	ip, city, country, err := core.ProbeOrigin(context.Background())
	if err != nil {
		return nil, err
	}
	return &OriginInfo{Ip: ip, City: city, Country: country}, nil
}
```

- [ ] **Step 2: Verify Go still builds**

Run: `cd android/core && go build ./...`
Expected: builds clean.

- [ ] **Step 3: Rebuild the AAR**

Run: `cd android && ./build-core.sh`
Expected: prints `built android/app/libs/libtunnelbahn.aar`. (Requires NDK + JAVA_HOME per the script's header; if the environment lacks them, note it and hand this build step to the user.)

- [ ] **Step 4: Commit**

```bash
git add android/core/mobile/mobile.go android/app/libs/libtunnelbahn.aar
git commit -m "feat(mobile): bind ProbeOrigin + OriginInfo to Kotlin"
```

---

## Task 3: Origin/exit flows + background origin trigger

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/vpn/OriginProbe.kt`

**Interfaces:**
- Consumes: `tunnelbahn.mobile.Mobile.probeOrigin()` (Task 2), `tunnelbahn.app.ui.formatLocation(city, country)`.
- Produces:
  - `TunnelBahnVpnService.Companion.originIp: MutableStateFlow<String>`
  - `TunnelBahnVpnService.Companion.originLocation: MutableStateFlow<String>`
  - `object OriginProbe { fun refresh() }` — idempotent-ish: runs one background probe if origin is currently blank, writes the two flows.

- [ ] **Step 1: Add the origin flows**

In `TunnelBahnVpnService.kt` companion object, directly below the existing `exitIp`/`exitLocation` declarations (around line 345), add:

```kotlin
        /** Origin (pre-VPN) IP and geo. Populated by [OriginProbe], independent of a session,
         *  so it is visible while disconnected. Same value connected or not. */
        val originIp = MutableStateFlow("")
        val originLocation = MutableStateFlow("")
```

- [ ] **Step 2: Do NOT clear origin on teardown**

Note: `endSession` (around line 180) clears `exitIp`/`exitLocation`. Leave origin flows untouched there — origin is device-scoped, not session-scoped, so it should persist across disconnect. (No code change in this step; this is a guard against "also clear origin", which would be wrong.)

- [ ] **Step 3: Create the background trigger**

Create `android/app/src/main/java/tunnelbahn/app/vpn/OriginProbe.kt`:

```kotlin
package tunnelbahn.app.vpn

import tunnelbahn.app.ui.formatLocation
import tunnelbahn.mobile.Mobile
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Fetches the device's origin IP + geo once and publishes it to the service flows. The
 * probe is a blocking gomobile call, so it runs on a dedicated thread. Session-independent:
 * safe to call whether or not a tunnel is up. Skips work when origin is already known or a
 * probe is already in flight, so callers can trigger it freely (e.g. every time Home shows).
 */
object OriginProbe {
    private val running = AtomicBoolean(false)

    fun refresh() {
        if (TunnelBahnVpnService.originIp.value.isNotBlank()) return
        if (!running.compareAndSet(false, true)) return
        Thread {
            try {
                val info = Mobile.probeOrigin()
                TunnelBahnVpnService.originIp.value = info.ip
                TunnelBahnVpnService.originLocation.value = formatLocation(info.city, info.country)
            } catch (_: Exception) {
                // Origin is informational; leave the flows blank so the UI keeps showing
                // "Locating..." and a later refresh() can retry.
            } finally {
                running.set(false)
            }
        }.start()
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL. (`Mobile.probeOrigin()` and `info.ip/.city/.country` resolve against the AAR rebuilt in Task 2.)

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt \
        android/app/src/main/java/tunnelbahn/app/vpn/OriginProbe.kt
git commit -m "feat(app): origin IP flows + background origin probe trigger"
```

---

## Task 4: Render origin/exit rows on the connection view

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt`

**Interfaces:**
- Consumes: `TunnelBahnVpnService.originIp/originLocation/exitIp/exitLocation` (Task 3), `OriginProbe.refresh()` (Task 3).

- [ ] **Step 1: Trigger the origin probe when Home shows**

In `HomeScreen` (after the existing `collectAsStateWithLifecycle` for `state`/`connectedSince`, ~line 95), add a one-shot trigger and collect the four flows:

```kotlin
    val originIp by TunnelBahnVpnService.originIp.collectAsStateWithLifecycle()
    val originLocation by TunnelBahnVpnService.originLocation.collectAsStateWithLifecycle()
    val exitIp by TunnelBahnVpnService.exitIp.collectAsStateWithLifecycle()
    val exitLocation by TunnelBahnVpnService.exitLocation.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) { tunnelbahn.app.vpn.OriginProbe.refresh() }
```

Add the import `androidx.compose.runtime.LaunchedEffect` if not already present.

- [ ] **Step 2: Pass the values into `ConnectionHero`**

Update the `ConnectionHero(...)` call site (~line 159) to pass the four new values:

```kotlin
                ConnectionHero(
                    profile = profile,
                    state = state,
                    elapsedMs = elapsedMs,
                    notifDenied = notifDenied,
                    originIp = originIp,
                    originLocation = originLocation,
                    exitIp = exitIp,
                    exitLocation = exitLocation,
                    onConnect = { connect() },
                    onDisconnect = { stopVpn(ctx) },
                    onProfiles = onProfiles,
                )
```

- [ ] **Step 3: Add the params and rows to `ConnectionHero`**

Update the `ConnectionHero` signature (~line 183) to add the four params after `notifDenied: Boolean,`:

```kotlin
    originIp: String,
    originLocation: String,
    exitIp: String,
    exitLocation: String,
```

Then, inside `ConnectionHero`'s `Column`, replace the notification-only note block (the `if (notifDenied && running) { ... }` at ~lines 237-245) with the IP panel. Insert this after the transport-summary `Text` (~line 236) and delete the old `notifDenied` note entirely:

```kotlin
        Spacer(Modifier.height(20.dp))
        IpGeoPanel(
            running = running,
            originIp = originIp,
            originLocation = originLocation,
            exitIp = exitIp,
            exitLocation = exitLocation,
        )
```

Because `notifDenied` is no longer read inside `ConnectionHero`, remove the `notifDenied` param and its call-site argument (from Step 2 leave it out). (The `notifDenied` state and `ensureNotifPermission` flow stay as-is in `HomeScreen`; only the on-screen note is removed.)

- [ ] **Step 4: Add the `IpGeoPanel` composable**

Add this private composable in `HomeScreen.kt` (near `ConnectionHero`):

```kotlin
@Composable
private fun IpGeoPanel(
    running: Boolean,
    originIp: String,
    originLocation: String,
    exitIp: String,
    exitLocation: String,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        if (running) {
            IpGeoRow("You", originIp, originLocation)
            Spacer(Modifier.height(4.dp))
            IpGeoRow("Exit", exitIp, exitLocation)
        } else {
            IpGeoRow("Your IP", originIp, originLocation)
        }
    }
}

@Composable
private fun IpGeoRow(label: String, ip: String, location: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(44.dp),
        )
        Text(
            if (ip.isBlank()) "Locating..." else ip,
            style = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum"),
            color = MaterialTheme.colorScheme.onSurface,
        )
        if (location.isNotBlank()) {
            Text(
                "  ·  $location",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
```

Add imports if missing: `androidx.compose.foundation.layout.Row`, `androidx.compose.foundation.layout.width`, `androidx.compose.foundation.layout.Spacer`, `androidx.compose.foundation.layout.height`. (`Row`, `Spacer`, `height`, `Column`, `Alignment`, `TextOverflow` are already used in this file; verify `width` is imported.)

- [ ] **Step 5: Verify it compiles**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL. No unused-parameter error for `notifDenied` (it was removed from `ConnectionHero`).

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt
git commit -m "feat(app): show origin + exit IP and geo on the connection view"
```

---

## Task 5: Pure helper for card button action

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/ui/ProfileCardAction.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/ui/ProfileCardActionTest.kt`

**Interfaces:**
- Produces: `enum class CardAction { CONNECT, DISCONNECT }` and `fun profileCardAction(isActive: Boolean, state: String): CardAction`.
- Consumes: `TunnelBahnVpnService.STATE_RUNNING`, `STATE_CONNECTING`.

- [ ] **Step 1: Write the failing test**

Create `android/app/src/test/java/tunnelbahn/app/ui/ProfileCardActionTest.kt`:

```kotlin
package tunnelbahn.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import tunnelbahn.app.vpn.TunnelBahnVpnService

class ProfileCardActionTest {
    @Test fun activeAndRunningShowsDisconnect() {
        assertEquals(CardAction.DISCONNECT, profileCardAction(true, TunnelBahnVpnService.STATE_RUNNING))
    }

    @Test fun activeAndConnectingShowsDisconnect() {
        assertEquals(CardAction.DISCONNECT, profileCardAction(true, TunnelBahnVpnService.STATE_CONNECTING))
    }

    @Test fun activeButDisconnectedShowsConnect() {
        assertEquals(CardAction.CONNECT, profileCardAction(true, TunnelBahnVpnService.STATE_DISCONNECTED))
    }

    @Test fun inactiveWhileAnotherRunsShowsConnect() {
        assertEquals(CardAction.CONNECT, profileCardAction(false, TunnelBahnVpnService.STATE_RUNNING))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "tunnelbahn.app.ui.ProfileCardActionTest"`
Expected: FAIL (compile error: `profileCardAction`/`CardAction` unresolved).

- [ ] **Step 3: Write minimal implementation**

Create `android/app/src/main/java/tunnelbahn/app/ui/ProfileCardAction.kt`:

```kotlin
package tunnelbahn.app.ui

import tunnelbahn.app.vpn.TunnelBahnVpnService

/** What a profile card's primary button should do, given whether it is the active
 *  (last-connected) profile and the live VPN state. Only the active card can be live. */
enum class CardAction { CONNECT, DISCONNECT }

fun profileCardAction(isActive: Boolean, state: String): CardAction {
    val live = state == TunnelBahnVpnService.STATE_RUNNING ||
        state == TunnelBahnVpnService.STATE_CONNECTING
    return if (isActive && live) CardAction.DISCONNECT else CardAction.CONNECT
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "tunnelbahn.app.ui.ProfileCardActionTest"`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/ProfileCardAction.kt \
        android/app/src/test/java/tunnelbahn/app/ui/ProfileCardActionTest.kt
git commit -m "feat(app): pure helper for profile card connect/disconnect action"
```

---

## Task 6: Switch-safe session handoff in the service

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt`

**Interfaces:**
- Produces: `onStartCommand` that, when a session is already active, stops it and defers the new connect via a `pendingProfileId` handoff (never two live sessions). Internal `beginConnect(profile)` extracted from the old connect sequence.

- [ ] **Step 1: Add the pending field**

In the field block (~line 41, next to `connectingProfileId`), add:

```kotlin
    // When a Connect intent arrives while a session is live, we stop the current session and
    // stash the next profile id here; the worker's teardown path (endSession) picks it up and
    // connects it, so there are never two live sessions racing on the tun.
    private var pendingProfileId: String? = null
```

- [ ] **Step 2: Extract `beginConnect` and rewrite `onStartCommand`**

Replace the body of `onStartCommand` (the part after the `ACTION_STOP` block) so it routes to a switch when already live. Replace from `val profileId = intent?.getStringExtra(...)` down through `startTunnel(profile)`/`return START_STICKY` with:

```kotlin
        val profileId = intent?.getStringExtra(EXTRA_PROFILE_ID)
        if (profileId == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        // Already running or connecting: switch. Stop the current session and defer the new
        // connect until its teardown completes (endSession consumes pendingProfileId).
        if (session != null) {
            pendingProfileId = profileId
            userStopping = true // this teardown is a deliberate switch, not a failed connect
            session?.stop()
            return START_STICKY
        }

        return beginConnect(profileId)
    }

    /** Loads [profileId] and starts a fresh connect attempt. Assumes no live session. */
    private fun beginConnect(profileId: String): Int {
        val profile = ProfileStore(this).load(profileId)
        if (profile == null) {
            lastError.value = "profile not found: $profileId"
            endSession(failed = true)
            return START_NOT_STICKY
        }
        connectingProfileId = profile.id
        // Fresh attempt: clear the previous outcome so stale errors do not linger.
        reachedRunning = false
        userStopping = false
        lastError.value = ""
        ensureNotificationChannel()
        startForeground(NOTIF_ID, buildNotification())
        state.value = STATE_CONNECTING
        startTunnel(profile)
        return START_STICKY
    }
```

- [ ] **Step 3: Hand off in `endSession`**

In `endSession` (~line 173), after the state-clearing lines (`worker = null`, `exitIp.value = ""`, `exitLocation.value = ""`) and BEFORE the `if (failed)` block, insert the handoff. When a switch is pending, connect it instead of tearing the service down:

```kotlin
        val next = pendingProfileId
        pendingProfileId = null
        if (next != null) {
            // Deliberate switch: the old session is gone; connect the next profile without
            // dropping the foreground or stopping the service.
            beginConnect(next)
            return
        }
```

(The existing `if (failed) { STATE_ERROR + Haptics.failure } else { STATE_DISCONNECTED }` and the `stopForeground`/`stopSelf` tail run only when there is no pending switch.)

- [ ] **Step 4: Verify it compiles**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Manual verification note**

This path is lifecycle-bound and not unit-tested in this repo (consistent with the existing service). Verified end-to-end in Task 7's manual check: connect A, then Connect B from Profiles, and confirm a single clean switch (A tears down, B connects, no duplicate notification, no stuck CONNECTING).

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt
git commit -m "feat(app): serialize profile switching via pending-connect handoff"
```

---

## Task 7: Per-card Connect/Disconnect, remove "Set active"

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/MainScreen.kt`

**Interfaces:**
- Consumes: `profileCardAction(isActive, state)` + `CardAction` (Task 5), `startVpn(ctx, id)`/`stopVpn(ctx)` (`ui/VpnControls.kt`), `ProfileStore.setSelectedId(id)`, `TunnelBahnVpnService.state`.

- [ ] **Step 1: Observe VPN state in `ProfilesScreen`**

In `ProfilesScreen` (~line 46, after `val store = ...`), collect the live state and current context:

```kotlin
    val state by TunnelBahnVpnService.state.collectAsStateWithLifecycle()
```

Add imports: `androidx.lifecycle.compose.collectAsStateWithLifecycle`, `androidx.compose.runtime.getValue`, `tunnelbahn.app.vpn.TunnelBahnVpnService`. (`LocalContext` is already imported; `ctx` is already defined.)

- [ ] **Step 2: Replace the `ProfileRow` call site**

Replace the `ProfileRow(...)` call inside `items(...)` (~line 92) with connect/disconnect wiring. Connect makes last-connected = active (`setSelectedId`) then starts; Disconnect stops:

```kotlin
                    ProfileRow(
                        profile = p,
                        active = p.id == selectedId,
                        action = profileCardAction(p.id == selectedId, state),
                        onConnect = {
                            store.setSelectedId(p.id)
                            selectedId = p.id
                            startVpn(ctx, p.id)
                        },
                        onDisconnect = { stopVpn(ctx) },
                        onEdit = { onEdit(p.id) },
                        onDelete = { confirmDelete = p },
                    )
```

- [ ] **Step 3: Rewrite the `ProfileRow` composable**

Replace the `ProfileRow` signature and its button `Row` (the `onSetActive` param and the `if (!active) OutlinedButton("Set active")` block). New signature and buttons:

```kotlin
@Composable
private fun ProfileRow(
    profile: Profile,
    active: Boolean,
    action: CardAction,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
```

Then in the button `Row` (~lines 174-183), replace the `if (!active) { OutlinedButton(onSetActive) { Text("Set active") } }` with:

```kotlin
                when (action) {
                    CardAction.CONNECT -> Button(onClick = onConnect) { Text("Connect") }
                    CardAction.DISCONNECT -> OutlinedButton(onClick = onDisconnect) { Text("Disconnect") }
                }
```

Keep the existing `OutlinedButton(onEdit) { Text("Edit") }` and `TextButton(onDelete) { Text("Delete") }`. Add the import `androidx.compose.material3.Button`.

- [ ] **Step 4: Verify it compiles**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL (no dangling `onSetActive` references).

- [ ] **Step 5: Run the full unit suite**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: PASS (includes `ProfileCardActionTest` and existing suites).

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/ui/MainScreen.kt
git commit -m "feat(app): per-card Connect/Disconnect; last-connected is active"
```

---

## Task 8: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Build the debug APK**

Run: `cd android && ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 2: Go tests green**

Run: `cd android/core && go test ./...`
Expected: PASS (includes `originprobe_test.go`).

- [ ] **Step 3: Manual smoke (device/emulator)**

1. Open Home with a profile selected but disconnected. Confirm a single `Your IP <ip> · <city, country>` row appears (after a moment; shows `Locating...` first).
2. Connect. Confirm the view now shows two rows: `You <origin>` and `Exit <exit>` (exit shows `Locating...` until the probe returns, then the server IP/geo).
3. Disconnect. Confirm the exit row disappears and the single origin row remains.
4. Open Profiles. Confirm each card has a **Connect** button and there is no **Set active** button. The currently-active/running card shows **Disconnect**.
5. With profile A running, tap **Connect** on profile B. Confirm a clean switch: A tears down, B connects, B becomes the highlighted/active card, exactly one ongoing notification, no stuck "Connecting".
6. Confirm the exit IP/geo differs from origin (proves traffic egresses via the server), and the notification still shows speed + exit location.

- [ ] **Step 4: Update memory**

If the switch-handoff or origin-probe behavior surfaced anything non-obvious, add/update a memory note under `.../memory/` and its `MEMORY.md` pointer. (e.g., link from [[android-app-traffic-bypasses-own-tunnel]] since the origin probe relies on that bypass.)

---

## Self-Review

**Spec coverage:**
- Origin probe in Go at (effectively) session-independent scope, reusing parseIPInfo → Tasks 1-2. ✓
- Origin/exit flows + geo via formatLocation → Task 3. ✓
- Origin visible when disconnected + You/Exit when running → Task 4. ✓
- Remove notification-only note → Task 4 Step 3. ✓
- Per-card Connect, remove "Set active", last-connected = active → Tasks 5, 7. ✓
- Running card shows Disconnect → Tasks 5, 7. ✓
- Switch serialized, never two live sessions → Task 6. ✓
- Tests: Go origin probe (Task 1), pure Kotlin card-action helper (Task 5); UI/service via build + manual (Tasks 4, 6, 8) per repo convention. ✓
- Out-of-scope items (no flags, no clipboard, no disk cache) respected. ✓

**Placeholder scan:** No TBD/TODO; every code step has concrete code. ✓

**Type consistency:** `profileCardAction`/`CardAction` defined in Task 5 and used identically in Task 7. `originIp`/`originLocation` defined in Task 3, consumed in Task 4. `beginConnect(profileId: String): Int` defined and called consistently in Task 6. `OriginInfo` fields `Ip/City/Country` → Kotlin `.ip/.city/.country` used in Task 3. ✓

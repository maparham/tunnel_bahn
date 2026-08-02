# Android QR Profile Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user import a TunnelBahn profile (SSH or WG-over-wstunnel) onto Android by scanning a QR shown by the macOS app, keys included, no retyping.

**Architecture:** The macOS app encodes a compact JSON payload (identity + endpoint + keys + WG relay params, no host key) as a QR. Android scans it with ZXing (no Google Play Services), parses it into a `Profile`, and saves it. For SSH the Android Go core is changed to trust-on-first-use: with no pinned host key it accepts the server key on first connect, reports it up, and Kotlin persists it so the next connect pins strictly.

**Tech Stack:** Kotlin/Jetpack Compose, Go (gomobile AAR), Swift/AppKit, ZXing (`zxing-android-embedded`), kotlinx.serialization.

**Spec:** `docs/superpowers/specs/2026-08-02-android-qr-import-design.md`

## Global Constraints

- No legacy/compat/migration code; no `schemaVersion`. The payload's `kind` field is a format discriminator only.
- Private keys never in plain profile JSON at rest; imported keys go through `ProfileStore.save` into `EncryptedSharedPreferences`.
- SSH keys ed25519/ECDSA only (no RSA) — unchanged.
- No em dashes in UI strings; tooltips one or two short sentences via the questionmark + tooltip idiom.
- Android: minSdk 24, compileSdk/targetSdk 35, JVM target 17. Gradle runs under the Android Studio JBR (JDK 21) at `/Applications/Android Studio.app/Contents/jbr/Contents/Home`.
- Payload `transport` values: `"ssh"` and `"wgws"` (must match `Profile.toCoreConfigJson`'s existing mapping).

---

### Task 1: Go core SSH trust-on-first-use

**Files:**
- Modify: `android/core/transport/ssh.go` (`SSHConfig`, `connect()`)
- Modify: `android/core/session.go` (`EventSink`, `buildTransport` ssh case)
- Modify: `android/core/mobile/mobile.go` (`EventSink`, `sinkAdapter`)
- Test: `android/core/transport/ssh_tofu_test.go` (new)
- Rebuild: `android/app/libs/libtunnelbahn.aar` via `android/build-core.sh`

**Interfaces:**
- Produces: `EventSink.OnHostKey(line string)` on all three Go interfaces (`transport` uses a callback field `SSHConfig.OnHostKey`); Kotlin sees a new `onHostKey(String)` method on the generated `tunnelbahn.mobile.EventSink`.

- [ ] **Step 1: Write the failing Go test**

Create `android/core/transport/ssh_tofu_test.go`. It stands up a minimal in-process SSH server with an ephemeral ed25519 host key, dials it via `NewSSH` with `HostKey: nil`, and asserts `OnHostKey` fires with the server key's authorized-key line.

```go
package transport

import (
	"context"
	"crypto/ed25519"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestSSHTOFUReportsHostKey(t *testing.T) {
	_, hostPriv, _ := ed25519.GenerateKey(nil)
	hostSigner, err := ssh.NewSignerFromKey(hostPriv)
	if err != nil {
		t.Fatal(err)
	}
	wantLine := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(hostSigner.PublicKey())))

	// Client key (server accepts any).
	_, cliPriv, _ := ed25519.GenerateKey(nil)
	cliSigner, _ := ssh.NewSignerFromKey(cliPriv)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	go func() {
		nc, err := ln.Accept()
		if err != nil {
			return
		}
		cfg := &ssh.ServerConfig{PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) { return nil, nil }}
		cfg.AddHostKey(hostSigner)
		conn, chans, reqs, err := ssh.NewServerConn(nc, cfg)
		if err != nil {
			return
		}
		go ssh.DiscardRequests(reqs)
		for ch := range chans {
			ch.Reject(ssh.Prohibited, "no channels in test")
		}
		_ = conn
	}()

	var mu sync.Mutex
	var got string
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		return net.Dial(network, addr)
	}
	s, err := NewSSH(SSHConfig{
		Addr:    ln.Addr().String(),
		User:    "tb",
		Signer:  cliSigner,
		HostKey: nil, // TOFU
		Dial:    DialFunc(dial),
		OnHostKey: func(line string) {
			mu.Lock()
			got = line
			mu.Unlock()
		},
	})
	if err != nil {
		t.Fatalf("NewSSH: %v", err)
	}
	defer s.Close()

	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if got != wantLine {
		t.Fatalf("OnHostKey line = %q, want %q", got, wantLine)
	}
}
```

- [ ] **Step 2: Run it and watch it fail to compile**

Run: `cd android/core && go test ./transport/ -run TestSSHTOFU`
Expected: FAIL — `SSHConfig` has no field `OnHostKey`.

- [ ] **Step 3: Add the `OnHostKey` field and nil-key handling in `transport/ssh.go`**

Add `"strings"` to the import block. Add the field to `SSHConfig` (after `OnState`):

```go
	// OnHostKey is called once, during the first successful handshake, with the
	// server's presented key as an authorized_keys line, when HostKey is nil (TOFU).
	// The Kotlin layer persists it so the next connect pins it via HostKey.
	OnHostKey func(line string)
```

Replace the `ccfg` literal in `connect()` so a nil `HostKey` means capture-and-accept:

```go
	ccfg := &ssh.ClientConfig{
		User: s.cfg.User,
		Auth: []ssh.AuthMethod{ssh.PublicKeys(s.cfg.Signer)},
	}
	if s.cfg.HostKey != nil {
		ccfg.HostKeyCallback = ssh.FixedHostKey(s.cfg.HostKey)
		// Constrain negotiation to the pinned key's type, otherwise the server may
		// present a different algorithm that can never match and the handshake fails.
		ccfg.HostKeyAlgorithms = []string{s.cfg.HostKey.Type()}
	} else {
		// TOFU: accept whatever the server presents on this first connect and report it.
		ccfg.HostKeyCallback = func(_ string, _ net.Addr, key ssh.PublicKey) error {
			if s.cfg.OnHostKey != nil {
				s.cfg.OnHostKey(strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key))))
			}
			return nil
		}
	}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd android/core && go test ./transport/ -run TestSSHTOFU -v`
Expected: PASS.

- [ ] **Step 5: Wire TOFU through `session.go`**

Add `"strings"` to imports if not present. Add to the `EventSink` interface:

```go
	OnHostKey(line string)
```

In `buildTransport`'s `case "ssh":`, make the host key optional and pass the callback:

```go
	case "ssh":
		signer, err := ssh.ParsePrivateKey([]byte(cfg.SSH.PrivateKeyPEM))
		if err != nil {
			return nil, fmt.Errorf("ssh private key: %w", err)
		}
		var hostKey ssh.PublicKey
		if strings.TrimSpace(cfg.SSH.HostKeyAuthorized) != "" {
			hostKey, _, _, _, err = ssh.ParseAuthorizedKey([]byte(cfg.SSH.HostKeyAuthorized))
			if err != nil {
				return nil, fmt.Errorf("ssh host key: %w", err)
			}
		}
		return transport.NewSSH(transport.SSHConfig{
			Addr:    cfg.SSH.Addr,
			User:    cfg.SSH.User,
			Signer:  signer,
			HostKey: hostKey, // nil => trust-on-first-use
			Dial:    transport.DialFunc(dial),
			OnHostKey: func(line string) {
				if sink != nil {
					sink.OnHostKey(line)
				}
			},
			OnState: func(connected bool) {
				if sink == nil {
					return
				}
				if connected {
					sink.OnState("running")
				} else {
					sink.OnState("degraded")
				}
			},
		})
```

- [ ] **Step 6: Add `OnHostKey` to the gomobile surface in `mobile.go`**

In the exported `EventSink` interface add `OnHostKey(line string)`, and add the adapter method:

```go
func (a sinkAdapter) OnHostKey(line string) { a.s.OnHostKey(line) }
```

- [ ] **Step 7: Verify Go compiles and all core tests pass**

Run: `cd android/core && go build ./... && go test ./...`
Expected: PASS (the existing non-empty-host-key path is unchanged; new TOFU test passes).

- [ ] **Step 8: Rebuild the AAR (checkpoint)**

Run: `cd android && ./build-core.sh`
Expected: prints "built android/app/libs/libtunnelbahn.aar" and lists `classes.jar` + `arm64-v8a`. The regenerated `tunnelbahn.mobile.EventSink` now declares `onHostKey(String)`. The Kotlin `Sink` will fail to compile until Task 2 implements it.

- [ ] **Step 9: Commit**

```bash
git add android/core
git commit -m "feat(core): SSH trust-on-first-use when no host key is pinned"
```
(The AAR itself is gitignored; only the Go sources are committed.)

---

### Task 2: Persist the TOFU host key in the Kotlin service

**Files:**
- Modify: `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt`

**Interfaces:**
- Consumes: `EventSink.onHostKey(String)` from the Task 1 AAR.
- Produces: after a first SSH connect, the profile's `sshHostKeyAuthorized` is populated in `ProfileStore`.

- [ ] **Step 1: Add a field to remember the connecting profile id**

Near the other per-attempt fields (`reachedRunning`, `userStopping`):

```kotlin
    // The profile currently being connected, so onHostKey can persist the TOFU key back to it.
    private var connectingProfileId: String? = null
```

Set it in `onStartCommand` right after the profile loads successfully (just before `reachedRunning = false`):

```kotlin
        connectingProfileId = profile.id
```

- [ ] **Step 2: Implement `onHostKey` in the `Sink`**

Add to the `inner class Sink : EventSink` (alongside `onState`/`onError`):

```kotlin
        override fun onHostKey(line: String) {
            // TOFU: pin the server key into the profile so the next connect verifies strictly.
            // Only write when blank, so an already-pinned key is never silently replaced.
            val id = connectingProfileId ?: return
            val store = ProfileStore(this@TunnelBahnVpnService)
            store.load(id)?.let { p ->
                if (p.sshHostKeyAuthorized.isBlank()) {
                    store.save(p.copy(sshHostKeyAuthorized = line))
                }
            }
        }
```

- [ ] **Step 3: Build the app to confirm the AAR/Kotlin interface matches**

Run: `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL (the `Sink` now satisfies the new `EventSink`).

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt
git commit -m "feat(android): persist TOFU host key into the profile on first SSH connect"
```

---

### Task 3: Pure QR payload parser

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/profile/QRImport.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/profile/QRImportTest.kt`

**Interfaces:**
- Produces: `fun parseImportedProfile(raw: String, newId: String): QRImportResult` and `sealed interface QRImportResult { data class Ok(val profile: Profile); data class Error(val reason: String) }`.

- [ ] **Step 1: Write the failing tests**

Create `android/app/src/test/java/tunnelbahn/app/profile/QRImportTest.kt`:

```kotlin
package tunnelbahn.app.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QRImportTest {
    private val id = "fixed-id"

    @Test fun ssh_payload_maps_to_profile_with_blank_host_key() {
        val raw = """
            {"kind":"tunnelbahn.profile","name":"My SSH","transport":"ssh",
             "ssh":{"addr":"1.2.3.4:443","user":"tb","privateKeyPEM":"PEMDATA"}}
        """.trimIndent()
        val r = parseImportedProfile(raw, id) as QRImportResult.Ok
        val p = r.profile
        assertEquals(id, p.id)
        assertEquals("My SSH", p.name)
        assertEquals(Transport.SSH, p.transport)
        assertEquals("1.2.3.4:443", p.endpoint)
        assertEquals("tb", p.sshUser)
        assertEquals("PEMDATA", p.sshPrivateKeyPem)
        assertEquals("", p.sshHostKeyAuthorized) // TOFU fills this on first connect
        assertEquals(AppScope.FULL, p.appScope)
    }

    @Test fun wg_payload_maps_relay_fields() {
        val raw = """
            {"kind":"tunnelbahn.profile","name":"My WG","transport":"wgws",
             "wg":{"privateKey":"pk","peerPublicKey":"peer","presharedKey":"",
                   "localAddrs":["10.9.0.2/32"],"dns":["1.1.1.1"],"mtu":1280,
                   "wsURL":"wss://1.2.3.4:443/tun/events","forwardHost":"127.0.0.1","forwardPort":51840}}
        """.trimIndent()
        val p = (parseImportedProfile(raw, id) as QRImportResult.Ok).profile
        assertEquals(Transport.WGWS, p.transport)
        assertEquals("pk", p.wgPrivateKey)
        assertEquals("peer", p.wgPeerPublicKey)
        assertEquals(listOf("10.9.0.2/32"), p.wgLocalAddrs)
        assertEquals(1280, p.wgMtu)
        assertEquals("wss://1.2.3.4:443/tun/events", p.wsUrl)
        assertEquals("127.0.0.1", p.wsForwardHost)
        assertEquals(51840, p.wsForwardPort)
    }

    @Test fun foreign_kind_is_rejected() {
        val raw = """{"kind":"something-else","name":"x","transport":"ssh"}"""
        assertTrue(parseImportedProfile(raw, id) is QRImportResult.Error)
    }

    @Test fun malformed_json_is_rejected() {
        assertTrue(parseImportedProfile("not json", id) is QRImportResult.Error)
    }

    @Test fun missing_transport_block_is_rejected() {
        val raw = """{"kind":"tunnelbahn.profile","name":"x","transport":"ssh"}"""
        assertTrue(parseImportedProfile(raw, id) is QRImportResult.Error)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:testDebugUnitTest --tests "tunnelbahn.app.profile.QRImportTest"`
Expected: FAIL — `parseImportedProfile` unresolved.

- [ ] **Step 3: Implement `QRImport.kt`**

```kotlin
package tunnelbahn.app.profile

import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

sealed interface QRImportResult {
    data class Ok(val profile: Profile) : QRImportResult
    data class Error(val reason: String) : QRImportResult
}

@Serializable
private data class QRPayload(
    val kind: String = "",
    val name: String = "",
    val transport: String = "",
    val ssh: QRSsh? = null,
    val wg: QRWg? = null,
)

@Serializable
private data class QRSsh(val addr: String = "", val user: String = "", val privateKeyPEM: String = "")

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
)

private val importJson = Json { ignoreUnknownKeys = true }

/** Parses a scanned QR payload into a [Profile] with id [newId]. [newId] is injected so this
 *  stays pure and unit-testable. */
fun parseImportedProfile(raw: String, newId: String): QRImportResult {
    val payload = try {
        importJson.decodeFromString(QRPayload.serializer(), raw)
    } catch (_: SerializationException) {
        return QRImportResult.Error("Not a valid TunnelBahn QR code.")
    } catch (_: IllegalArgumentException) {
        return QRImportResult.Error("Not a valid TunnelBahn QR code.")
    }
    if (payload.kind != "tunnelbahn.profile") {
        return QRImportResult.Error("Not a TunnelBahn profile QR code.")
    }
    return when (payload.transport) {
        "ssh" -> {
            val s = payload.ssh ?: return QRImportResult.Error("QR is missing SSH details.")
            QRImportResult.Ok(
                Profile(
                    id = newId,
                    name = payload.name,
                    transport = Transport.SSH,
                    endpoint = s.addr,
                    sshUser = s.user,
                    sshPrivateKeyPem = s.privateKeyPEM,
                    sshHostKeyAuthorized = "", // TOFU on first connect
                )
            )
        }
        "wgws" -> {
            val w = payload.wg ?: return QRImportResult.Error("QR is missing WireGuard details.")
            QRImportResult.Ok(
                Profile(
                    id = newId,
                    name = payload.name,
                    transport = Transport.WGWS,
                    wgPrivateKey = w.privateKey,
                    wgPeerPublicKey = w.peerPublicKey,
                    wgPresharedKey = w.presharedKey,
                    wgLocalAddrs = w.localAddrs,
                    wgDns = w.dns,
                    wgMtu = w.mtu,
                    wsUrl = w.wsURL,
                    wsForwardHost = w.forwardHost,
                    wsForwardPort = w.forwardPort,
                )
            )
        }
        else -> QRImportResult.Error("Unknown transport in QR code.")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:testDebugUnitTest --tests "tunnelbahn.app.profile.QRImportTest"`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/tunnelbahn/app/profile/QRImport.kt \
        android/app/src/test/java/tunnelbahn/app/profile/QRImportTest.kt
git commit -m "feat(android): parse scanned QR payload into a Profile"
```

---

### Task 4: Scanner dependency, camera permission, and UI entry points

**Files:**
- Modify: `android/app/build.gradle.kts`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/java/tunnelbahn/app/ui/QrImport.kt` (Compose helper)
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/MainScreen.kt` (`ProfilesScreen` top bar)
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt` (`EmptyHome`)

**Interfaces:**
- Consumes: `parseImportedProfile` (Task 3), `ProfileStore.save`/`setSelectedId`.
- Produces: `@Composable fun rememberQrImport(onImported: (Profile) -> Unit, onError: (String) -> Unit): () -> Unit` that, when invoked, requests camera permission then launches the scanner.

- [ ] **Step 1: Add the ZXing dependency**

In `android/app/build.gradle.kts` `dependencies { ... }` add:

```kotlin
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
```

- [ ] **Step 2: Add the camera permission**

In `AndroidManifest.xml`, alongside the other `<uses-permission>` lines:

```xml
    <uses-permission android:name="android.permission.CAMERA" />
```

- [ ] **Step 3: Sync/build to pull the dependency**

Run: `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL, ZXing resolves.

- [ ] **Step 4: Create the Compose import helper `ui/QrImport.kt`**

```kotlin
package tunnelbahn.app.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts.RequestPermission
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import tunnelbahn.app.profile.Profile
import tunnelbahn.app.profile.QRImportResult
import tunnelbahn.app.profile.parseImportedProfile
import java.util.UUID

/** Returns a callback that requests camera permission, launches the ZXing scanner, and routes
 *  the decoded payload to [onImported] or [onError]. ZXing runs without Google Play Services. */
@Composable
fun rememberQrImport(
    onImported: (Profile) -> Unit,
    onError: (String) -> Unit,
): () -> Unit {
    val scan = rememberLauncherForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@rememberLauncherForActivityResult // user cancelled
        when (val r = parseImportedProfile(contents, UUID.randomUUID().toString())) {
            is QRImportResult.Ok -> onImported(r.profile)
            is QRImportResult.Error -> onError(r.reason)
        }
    }
    val options = remember {
        ScanOptions()
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setBeepEnabled(false)
            .setOrientationLocked(false)
            .setPrompt("Scan the TunnelBahn desktop QR")
    }
    val permission = rememberLauncherForActivityResult(RequestPermission()) { granted ->
        if (granted) scan.launch(options) else onError("Camera permission is needed to scan.")
    }
    return { permission.launch(Manifest.permission.CAMERA) }
}
```

- [ ] **Step 5: Wire it into `ProfilesScreen` (`MainScreen.kt`)**

Add a `ProfileStore` handle and a `Snackbar` host if not present, then add the import action to the top bar. In the `ProfilesScreen` composable, near the existing store/state:

```kotlin
    val importError = remember { mutableStateOf<String?>(null) }
    val launchImport = rememberQrImport(
        onImported = { p ->
            store.save(p)
            store.setSelectedId(p.id)
            onEdit(p.id) // open the editor so the user can review routing/apps
        },
        onError = { importError.value = it },
    )
```

Add a top-bar action button (next to the back arrow / title actions):

```kotlin
    IconButton(onClick = launchImport) {
        Icon(Icons.Default.QrCodeScanner, contentDescription = "Import from QR")
    }
```

Show `importError.value` via a `Snackbar` (or a simple `AlertDialog`), clearing it on dismiss. Import `androidx.compose.material.icons.filled.QrCodeScanner` and `tunnelbahn.app.ui.rememberQrImport`.

- [ ] **Step 6: Add an import button to `EmptyHome` (`HomeScreen.kt`)**

`EmptyHome` currently takes `onAddProfile`. Add an `onImport: () -> Unit` parameter and a secondary button:

```kotlin
        OutlinedButton(onClick = onImport) { Text("Import from QR") }
```

In `HomeScreen`, build the import callback with `rememberQrImport` (onImported: save + `setSelectedId` + recompose Home by navigating via `onAddProfile`'s sibling; simplest is to route to Profiles or re-enter Home). Pass it into `EmptyHome(onAddProfile, onImport)`. Surface errors with a `Snackbar`.

- [ ] **Step 7: Build**

Run: `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 8: Commit**

```bash
git add android/app/build.gradle.kts android/app/src/main/AndroidManifest.xml \
        android/app/src/main/java/tunnelbahn/app/ui/QrImport.kt \
        android/app/src/main/java/tunnelbahn/app/ui/MainScreen.kt \
        android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt
git commit -m "feat(android): scan a QR to import a profile (ZXing, no GMS)"
```

---

### Task 5: macOS payload encoder

**Files:**
- Create: `TunnelBahn/Services/AndroidProfileQRCodec.swift`
- Test: `TunnelBahnTests/AndroidProfileQRCodecTests.swift` (match the project's existing test target/dir)

**Interfaces:**
- Consumes: `WireGuardProfile`, `KeychainService`, `WireGuardTCPWrapper`, `SSHProfile`.
- Produces: `AndroidProfileQRCodec.encode(_ profile: WireGuardProfile, keychain: KeychainService) throws -> String` returning compact JSON.

- [ ] **Step 1: Write the failing tests**

Create `TunnelBahnTests/AndroidProfileQRCodecTests.swift`. Use a stub keychain that returns fixed PEM/keys. Assert the SSH `addr` join and the WG `wsURL` join for tls and non-tls, and that a plain-WG profile (no enabled wrapper) throws.

```swift
import XCTest
@testable import TunnelBahn

final class AndroidProfileQRCodecTests: XCTestCase {
    // Provide a KeychainService test double returning fixed secrets keyed by account.
    // (Mirror however KeychainService is faked elsewhere in the suite.)

    func testSSHEncodeJoinsHostAndPort() throws {
        let profile = makeSSHProfile(host: "1.2.3.4", port: 443, user: "tb")
        let json = try AndroidProfileQRCodec.encode(profile, keychain: fakeKeychain)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["kind"] as? String, "tunnelbahn.profile")
        XCTAssertEqual(obj["transport"] as? String, "ssh")
        let ssh = obj["ssh"] as! [String: Any]
        XCTAssertEqual(ssh["addr"] as? String, "1.2.3.4:443")
        XCTAssertEqual(ssh["user"] as? String, "tb")
        XCTAssertNil(obj["wg"])
    }

    func testWGEncodeBuildsWSSUrl() throws {
        let profile = makeWGProfile(serverHost: "1.2.3.4", serverPort: 443, tls: true,
                                    pathPrefix: "tun", forwardHost: "127.0.0.1", forwardPort: 51840)
        let json = try AndroidProfileQRCodec.encode(profile, keychain: fakeKeychain)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["transport"] as? String, "wgws")
        let wg = obj["wg"] as! [String: Any]
        XCTAssertEqual(wg["wsURL"] as? String, "wss://1.2.3.4:443/tun/events")
        XCTAssertEqual(wg["forwardPort"] as? Int, 51840)
    }

    func testPlainWireGuardWithoutWrapperThrows() {
        let profile = makeWGProfile(wrapper: nil)
        XCTAssertThrowsError(try AndroidProfileQRCodec.encode(profile, keychain: fakeKeychain))
    }
}
```

(Add the `makeSSHProfile`/`makeWGProfile`/`fakeKeychain` helpers to match existing test conventions in the target.)

- [ ] **Step 2: Run to verify failure**

Run the `AndroidProfileQRCodecTests` via the project's usual test command (e.g. `xcodebuild test -scheme TunnelBahn -only-testing:TunnelBahnTests/AndroidProfileQRCodecTests` or the repo's test script).
Expected: FAIL — `AndroidProfileQRCodec` undefined.

- [ ] **Step 3: Implement `AndroidProfileQRCodec.swift`**

```swift
import Foundation

struct AndroidProfileQRPayload: Encodable {
    struct SSH: Encodable { let addr, user, privateKeyPEM: String }
    struct WG: Encodable {
        let privateKey, peerPublicKey, presharedKey: String
        let localAddrs, dns: [String]
        let mtu: Int
        let wsURL, forwardHost: String
        let forwardPort: Int
    }
    let kind = "tunnelbahn.profile"
    let name: String
    let transport: String
    let ssh: SSH?
    let wg: WG?
}

enum AndroidProfileQRError: LocalizedError {
    case noAndroidTransport
    case missingSecret(String)

    var errorDescription: String? {
        switch self {
        case .noAndroidTransport: return "This profile has no Android-compatible transport."
        case .missingSecret(let s): return "Missing key material: \(s)."
        }
    }
}

enum AndroidProfileQRCodec {
    static func encode(_ profile: WireGuardProfile, keychain: KeychainService) throws -> String {
        let payload: AndroidProfileQRPayload
        if profile.transport == .ssh, let ssh = profile.ssh {
            let pem = try keychain.read(account: ssh.privateKeyRef)
            payload = AndroidProfileQRPayload(
                name: profile.name, transport: "ssh",
                ssh: .init(addr: "\(ssh.host):\(ssh.port)", user: ssh.username, privateKeyPEM: pem),
                wg: nil
            )
        } else if let w = profile.tcpWrapper, w.enabled, let peer = profile.peers.first {
            let priv = try keychain.read(account: profile.interface.privateKeyRef)
            let psk = try peer.presharedKeyRef.map { try keychain.read(account: $0) } ?? ""
            let scheme = w.tls ? "wss" : "ws"
            payload = AndroidProfileQRPayload(
                name: profile.name, transport: "wgws", ssh: nil,
                wg: .init(
                    privateKey: priv, peerPublicKey: peer.publicKey, presharedKey: psk,
                    localAddrs: profile.interface.addresses, dns: profile.interface.dnsServers,
                    mtu: profile.interface.mtu ?? 1280,
                    wsURL: "\(scheme)://\(w.serverHost):\(w.serverPort)/\(w.pathPrefix)/events",
                    forwardHost: w.forwardHost, forwardPort: Int(w.forwardPort)
                )
            )
        } else {
            throw AndroidProfileQRError.noAndroidTransport
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [] // compact
        return String(decoding: try enc.encode(payload), as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same test command as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Services/AndroidProfileQRCodec.swift TunnelBahnTests/AndroidProfileQRCodecTests.swift
git commit -m "feat(macos): encode a profile as an Android-import QR payload"
```

---

### Task 6: macOS export action + QR panel

**Files:**
- Modify: `TunnelBahn/Views/ProfilesView.swift`

**Interfaces:**
- Consumes: `AndroidProfileQRCodec.encode` (Task 5), `WireGuardConfigRenderer.makeQRCodeImage`.

- [ ] **Step 1: Add the menu action**

In the context-menu builder near the existing "Show QR Code" item (~`ProfilesView.swift:408`), add:

```swift
menu.addItem(makeMenuItem(title: "Export to Android (QR)", symbolName: "qrcode") {
    showAndroidQRPanel(for: profile)
})
```

- [ ] **Step 2: Add the panel presenter**

Model it on `showQRCodePanel`. Encode via the codec; on success render with `makeQRCodeImage`; include a one-line caption noting the QR contains the private key. On `AndroidProfileQRError` show the localized message instead of a QR.

```swift
private func showAndroidQRPanel(for profile: WireGuardProfile) {
    let content: AnyView
    do {
        let json = try AndroidProfileQRCodec.encode(profile, keychain: .shared)
        if let img = WireGuardConfigRenderer.makeQRCodeImage(from: json) {
            content = AnyView(
                VStack(spacing: 8) {
                    Text(profile.name).font(.headline)
                    Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 240, height: 240)
                    Text("Contains the private key. Scan only on a trusted device.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            )
        } else {
            content = AnyView(Text("Profile is too large to encode as a QR code.")
                .foregroundStyle(.secondary).padding(32))
        }
    } catch {
        content = AnyView(Text(error.localizedDescription).foregroundStyle(.secondary).padding(32))
    }
    // Present with the same NSPanel pattern as showQRCodePanel, title "Android QR: <name>".
    presentQRPanel(title: "Android QR: \(profile.name)", content: content)
}
```

If `showQRCodePanel` does not already factor out an `presentQRPanel(title:content:)` helper, extract one from its body (lines ~629-644) and use it from both call sites (DRY).

- [ ] **Step 3: Build the macOS app**

Run the repo's macOS build (e.g. `xcodebuild -scheme TunnelBahn build` or the project's build script).
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add TunnelBahn/Views/ProfilesView.swift
git commit -m "feat(macos): Export to Android (QR) action in the profiles menu"
```

---

### Task 7: On-device end-to-end verification

**Files:** none (manual verification with the connected Pixel 8a; requires the device unlocked).

- [ ] **Step 1: Install the debug build**

Run: `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:installDebug`
Expected: "Installed on 1 device".

- [ ] **Step 2: Export an SSH profile QR from the macOS app**

In the macOS app, right-click an SSH profile, "Export to Android (QR)". Leave the panel open.

- [ ] **Step 3: Scan and import on Android**

On the Pixel: Profiles screen (or empty Home) -> "Import from QR" -> grant camera -> scan the panel. Confirm the profile appears with the right name/endpoint/user and opens in the editor.

- [ ] **Step 4: Connect (TOFU pins) and verify persistence**

Connect the imported SSH profile. Confirm it reaches Connected (success haptic). Then verify the host key was persisted:

Run: `adb shell run-as tunnelbahn.app cat /data/data/tunnelbahn.app/shared_prefs/tb_profiles.xml | grep -o 'sshHostKeyAuthorized[^,}]*' | head`
Expected: a non-empty `ssh-ed25519 ...` (or ecdsa) value after the first connect.

- [ ] **Step 5: Reconnect (strict pin) and WG case**

Disconnect and reconnect the same profile; confirm it still connects (now strict-pinning the stored key). Repeat Steps 2-4 for a WG-over-wstunnel profile, confirming egress through the tunnel.

- [ ] **Step 6: Finish the branch**

Announce and use superpowers:finishing-a-development-branch to verify tests and complete the work.

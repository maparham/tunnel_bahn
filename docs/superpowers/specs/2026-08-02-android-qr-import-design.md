# Android QR Profile Import Design

**Date:** 2026-08-02
**Status:** Proposed
**Context:** The Android client can only create profiles by hand. The macOS app already renders a QR for a profile, but it encodes a wg-quick `.conf` (WireGuard `[Interface]`/`[Peer]` + TCP-wrapper block) with **no SSH** — and SSH is the primary Iran transport. This adds a first-class "scan the desktop QR to import a profile" path covering both SSH and WG-over-wstunnel.

## Goal

Let a user import a TunnelBahn profile onto Android by scanning a QR shown by the macOS app, for both the SSH and WG-over-wstunnel transports, including the private key material, with no manual retyping.

## Decisions (from brainstorming)

- **Both transports** import: SSH and WG-over-wstunnel.
- **Android does TOFU** for the SSH host key: the QR carries no host key; the Android core trusts the server key on first connect and pins it locally, exactly as the macOS app already does. This is the least cross-app coupling and matches the project's existing host-key trust model.
- **Plaintext private key in the QR is acceptable** — the same tradeoff the desktop's existing wg-quick QR already makes. On import the key lands in Android `EncryptedSharedPreferences`, never in plain profile JSON at rest.
- **Routing and per-app scope are not carried** in the QR. They default on import (full tunnel, default resolver) and the user tunes them in the editor's Advanced section. The QR carries only the hard-to-retype material: identity, endpoint, user, keys, and the WG relay parameters.

## Payload format

A single JSON object, encoded as raw UTF-8 directly in the QR. Raw JSON is chosen over a base64/`tunnelbahn://` wrapper because both force QR byte mode anyway, and base64 would add ~33% with no benefit; the keys involved (ed25519/ECDSA, never RSA) are small.

```json
{
  "kind": "tunnelbahn.profile",
  "name": "My Server",
  "transport": "ssh",
  "ssh": {
    "addr": "1.2.3.4:443",
    "user": "tb",
    "privateKeyPEM": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----\n"
  },
  "wg": {
    "privateKey": "...",
    "peerPublicKey": "...",
    "presharedKey": "...",
    "localAddrs": ["10.9.0.2/32"],
    "dns": ["1.1.1.1"],
    "mtu": 1280,
    "wsURL": "wss://1.2.3.4:443/tun74fd08a683078a3e0439/events",
    "forwardHost": "127.0.0.1",
    "forwardPort": 51840
  }
}
```

Rules:

- `transport` is `"ssh"` or `"wgws"`.
- `ssh` is present iff `transport == "ssh"`; `wg` is present iff `transport == "wgws"`. The other is omitted.
- The `ssh` block carries **no** host key — Android TOFU supplies it (see the core change below).
- `kind` is a fixed format discriminator so the Android scanner can reject non-TunnelBahn QRs. It is **not** a schema version and carries no migration semantics (no-legacy policy).
- `presharedKey` may be an empty string when the peer has no PSK.

### Field mapping (macOS `WireGuardProfile` -> payload)

SSH (`transport == .ssh`, `ssh: SSHProfile?`):

| Payload key       | macOS source                                  |
|-------------------|-----------------------------------------------|
| `ssh.addr`        | `"\(ssh.host):\(ssh.port)"`                    |
| `ssh.user`        | `ssh.username`                                 |
| `ssh.privateKeyPEM` | `KeychainService.read(account: ssh.privateKeyRef)` |

WG-over-wstunnel (`transport == .wireguard` with `tcpWrapper != nil && tcpWrapper.enabled`):

| Payload key         | macOS source                                                        |
|---------------------|---------------------------------------------------------------------|
| `wg.privateKey`     | `KeychainService.read(account: interface.privateKeyRef)`            |
| `wg.peerPublicKey`  | `peers[0].publicKey`                                                 |
| `wg.presharedKey`   | `peers[0].presharedKeyRef` -> Keychain, else `""`                   |
| `wg.localAddrs`     | `interface.addresses`                                               |
| `wg.dns`            | `interface.dnsServers`                                              |
| `wg.mtu`            | `interface.mtu ?? 1280`                                             |
| `wg.wsURL`          | `"\(tls ? "wss" : "ws")://\(serverHost):\(serverPort)/\(pathPrefix)/events"` |
| `wg.forwardHost`    | `tcpWrapper.forwardHost`                                            |
| `wg.forwardPort`    | `tcpWrapper.forwardPort`                                            |

Known limitation: `WireGuardTCPWrapper.verifyCert` has no Android counterpart (the Android relay follows wstunnel's default of not validating). The reference bare-IP server runs `verifyCert == false`, so this is lossless for it. Out of scope to add an Android verify-cert knob here.

### Payload -> Android `Profile` (on import)

Build `Profile(...)` with a freshly generated `id` (`java.util.UUID.randomUUID().toString()`), then `ProfileStore.save(profile)` (which scrubs the key fields into `EncryptedSharedPreferences`).

- `name` <- payload `name`
- `transport` <- `Transport.SSH` or `Transport.WGWS`
- SSH: `endpoint` <- `ssh.addr`, `sshUser` <- `ssh.user`, `sshPrivateKeyPem` <- `ssh.privateKeyPEM`, `sshHostKeyAuthorized` <- `""` (TOFU fills it on first connect)
- WG: `wgPrivateKey`, `wgPeerPublicKey`, `wgPresharedKey`, `wgLocalAddrs`, `wgDns`, `wgMtu`, `wsUrl` <- `wg.wsURL`, `wsForwardHost` <- `wg.forwardHost`, `wsForwardPort` <- `wg.forwardPort`
- Defaults: `appScope = FULL`, `packages = []`, `routingMode = EXCLUDE`, `includeCIDRs/excludeCIDRs = []`, `resolver = "1.1.1.1:53"`

## macOS: new "Export to Android (QR)" action

Add a distinct action in `ProfilesView`'s profile context menu (near the existing "Show QR Code", ~`ProfilesView.swift:406`), titled "Export to Android (QR)". It:

1. Builds the payload struct from the selected `WireGuardProfile` (reading keys from Keychain).
2. Encodes it with `JSONEncoder` (`outputFormatting = []`, compact).
3. Renders via the existing `WireGuardConfigRenderer.makeQRCodeImage(from:)`.
4. Presents in the same floating `NSPanel` pattern as `showQRCodePanel`, titled "Android QR: <name>", with a one-line caption noting the QR contains the private key.

The existing "Show QR Code" (wg-quick) action stays unchanged for WireGuard-app interop.

New file `TunnelBahn/Services/AndroidProfileQRCodec.swift`:

```swift
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
    let transport: String   // "ssh" | "wgws"
    let ssh: SSH?
    let wg: WG?
}

enum AndroidProfileQRCodec {
    /// Throws if a required Keychain secret is missing or the profile's transport
    /// is not exportable (plain WireGuard with no TCP wrapper).
    static func encode(_ profile: WireGuardProfile, keychain: KeychainService) throws -> String
}
```

`encode` returns the compact JSON string. Reject (throw) a plain-WireGuard profile with no enabled `tcpWrapper`, since the Android client has no plain-UDP WG transport — surface that in the panel as "This profile has no Android-compatible transport."

## Android: scanner + import

### Dependency

Add `com.journeyapps:zxing-android-embedded:4.3.0` (pure ZXing, **no Google Play Services** — required because target devices in Iran frequently lack GMS). Add `<uses-permission android:name="android.permission.CAMERA" />` to `AndroidManifest.xml` (runtime prompt on API 23+).

### Decode + validation

New file `android/app/src/main/java/tunnelbahn/app/profile/QRImport.kt` — pure, testable, no Android deps:

```kotlin
sealed interface QRImportResult {
    data class Ok(val profile: Profile) : QRImportResult
    data class Error(val reason: String) : QRImportResult
}

/** Parses a scanned QR payload into a Profile with a fresh id. [newId] is injected so the
 *  function stays pure and unit-testable (no UUID call inside). */
fun parseImportedProfile(raw: String, newId: String): QRImportResult
```

Behavior:

- Reject when JSON is malformed, `kind != "tunnelbahn.profile"`, `transport` is unknown, or the transport's block (`ssh`/`wg`) is absent -> `Error` with a short reason.
- On success -> `Ok(Profile(...))` per the mapping above.

### UI entry points

- `ProfilesScreen` top bar: add an "Import from QR" action (icon `Icons.Default.QrCodeScanner` or `Icons.Default.Add` sibling) next to the existing add FAB behavior.
- `EmptyHome` (`HomeScreen.kt`): add a secondary "Import from QR" button under "Add profile".

Both call a shared `launchQrImport()` that:

1. Launches the scanner via `rememberLauncherForActivityResult(ScanContract())` with `ScanOptions().setBeepEnabled(false).setOrientationLocked(false).setPrompt("Scan the TunnelBahn desktop QR")`.
2. On a non-null result, calls `parseImportedProfile(contents, UUID.randomUUID().toString())`.
3. `Ok` -> `store.save(profile)`, `store.setSelectedId(profile.id)`, navigate to the editor for that profile (so the user can review/tune routing) or back to Profiles with a confirmation. `Error` -> a `Snackbar`/`Toast` with the reason.
4. Camera permission: request `Manifest.permission.CAMERA` via `rememberLauncherForActivityResult(RequestPermission())` before launching the scan; if denied, show a short explanatory Snackbar.

`ScanContract` (from zxing-android-embedded) already provides the capture Activity, so no custom camera UI is needed.

## Android core: SSH TOFU

Today `android/core/session.go:buildTransport` requires a non-empty, parseable `hostKeyAuthorized` (`ssh.ParseAuthorizedKey` errors on empty) and pins strictly via `ssh.FixedHostKey`. Imported SSH profiles have no host key, so this must become trust-on-first-use.

### `android/core/transport/ssh.go`

Allow a nil pinned key and capture-and-accept when nil:

- `SSHConfig`: `HostKey ssh.PublicKey` may be nil; add `OnHostKey func(authorizedLine string)`.
- In `connect()`:
  - If `cfg.HostKey != nil`: keep `HostKeyCallback = ssh.FixedHostKey(cfg.HostKey)` and `HostKeyAlgorithms = []string{cfg.HostKey.Type()}` (current strict behavior).
  - Else: `HostKeyCallback = func(_ string, _ net.Addr, key ssh.PublicKey) error { if cfg.OnHostKey != nil { cfg.OnHostKey(strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key)))) }; return nil }`, and no `HostKeyAlgorithms` constraint.

### `android/core/session.go`

- Add `OnHostKey(line string)` to the local `EventSink` interface.
- In the `ssh` case of `buildTransport`: if `cfg.SSH.HostKeyAuthorized` is empty, pass `HostKey: nil` and `OnHostKey: func(line string) { sink.OnHostKey(line) }`; otherwise parse and pass the pinned key as today (no `OnHostKey`).

### `android/core/mobile/mobile.go` (gomobile surface)

- Add `OnHostKey(line string)` to the exported `EventSink` interface.
- Add `func (a sinkAdapter) OnHostKey(line string) { a.s.OnHostKey(line) }`.

### Rebuild the AAR

```bash
cd android && ./build-core.sh
```

This regenerates `android/app/libs/libtunnelbahn.aar` with the new `EventSink.onHostKey` method. Treat the rebuild as a checkpoint: the Kotlin `Sink` will not compile until the new AAR is in place.

### Kotlin `Sink` (`TunnelBahnVpnService.kt`)

- Implement `override fun onHostKey(line: String)`: persist it into the connecting profile so the next connect pins strictly. The service knows the profile id from `onStartCommand`; store it in a field (`connectingProfileId`) and in `onHostKey` do:

```kotlin
val id = connectingProfileId ?: return
val store = ProfileStore(this)
store.load(id)?.let { p ->
    if (p.sshHostKeyAuthorized.isBlank()) store.save(p.copy(sshHostKeyAuthorized = line))
}
```

Only write when the field was blank, so a legitimately pinned key is never silently overwritten by a later observation. A server key rotation therefore fails strict verification on the next connect (correct TOFU behavior); recovering from an intentional rotation is a future "reset host key" affordance, out of scope here.

Side benefit: manually-created Android SSH profiles no longer need the host key typed in up front — leaving it blank now yields TOFU.

## Constraints (carried from project memory)

- No em dashes in UI strings; tooltips one or two short sentences via the questionmark + tooltip idiom.
- No legacy/compat/migration code; no `schemaVersion`. `kind` is a format discriminator only.
- Private keys never in plain profile JSON at rest; imported keys go through `ProfileStore.save` into `EncryptedSharedPreferences`.
- SSH keys ed25519/ECDSA only (no RSA) — unchanged; the payload just carries whatever PEM the desktop already holds.

## Files touched

macOS:
- `TunnelBahn/Services/AndroidProfileQRCodec.swift` (new) — payload struct + `encode`.
- `TunnelBahn/Views/ProfilesView.swift` — new "Export to Android (QR)" menu action + panel.

Android app:
- `android/app/build.gradle.kts` (+ `gradle/libs.versions.toml` if used) — zxing-android-embedded.
- `android/app/src/main/AndroidManifest.xml` — `CAMERA` permission.
- `android/app/src/main/java/tunnelbahn/app/profile/QRImport.kt` (new) — `parseImportedProfile`.
- `android/app/src/main/java/tunnelbahn/app/ui/ProfilesScreen` (in `MainScreen.kt`) — import action.
- `android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt` — import button on `EmptyHome`.
- `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt` — `connectingProfileId` field + `Sink.onHostKey`.

Android core:
- `android/core/transport/ssh.go` — nilable pinned key + capture callback.
- `android/core/session.go` — `EventSink.OnHostKey`; TOFU wiring in `buildTransport`.
- `android/core/mobile/mobile.go` — `EventSink.OnHostKey` + adapter.
- Rebuild `android/app/libs/libtunnelbahn.aar` via `android/build-core.sh`.

## Testing

- Kotlin unit (`QRImportTest`): SSH payload -> `Profile` (fields + blank host key); WG payload -> `Profile` (incl. `wsUrl`/forward mapping); unknown `kind` -> `Error`; malformed JSON -> `Error`; missing transport block -> `Error`.
- Swift unit (`AndroidProfileQRCodecTests`): SSH encode round-trip (`addr` join); WG encode round-trip (`wsURL` join for tls/non-tls); plain-WG-without-wrapper throws.
- Go unit (`transport` / `session`): empty host key -> callback fires with a valid authorized line and connect proceeds; non-empty host key -> strict `FixedHostKey` path unchanged (regression).
- On-device: show a desktop QR for an SSH profile; scan on the Pixel; confirm the profile appears, connects (TOFU pins the key into the profile), and a second connect strict-pins. Repeat for a WG-over-wstunnel profile.

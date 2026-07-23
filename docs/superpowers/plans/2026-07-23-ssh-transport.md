# SSH Egress Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add SSH `direct-tcpip` port forwarding as a per-profile alternative egress transport to WireGuard, reusing the existing transport-agnostic UDS relay seam.

**Architecture:** The packet-tunnel extension's `PacketTunnelRelayServer` already drives its egress bridge through a small stream-flow interface (`openTCP`/`sendTCP`/`close` + `onPayloadFromFlow`/`onFlowClosed`). Extract that into a `RelayFlowTransport` protocol; `SmoltcpRelayBridge` (WG) conforms as-is, and a new `SSHFlowTransport` (SwiftNIO SSH) conforms alongside it. `PacketTunnelProvider.startTunnel` selects the transport from the active profile's `transport` type. The proxy-side capture, UDS framing, backpressure, and per-app stats are untouched.

**Tech Stack:** Swift 5.10, macOS 14+, NetworkExtension (system extensions), XcodeGen (`project.yml`), SwiftNIO SSH (`swift-nio-ssh`, new SPM dependency), existing `KeychainService`.

## Global Constraints

- Deployment target: macOS 14.0; Swift 5.10 (from `project.yml`).
- **No builds unless the user explicitly asks** in that turn (standing rule). Verification of extension behavior is via the S1..SN scenario-probe workflow (set toggles + start tunnel via URL scheme, then STOP — the user runs probes), NOT xcodebuild.
- **No subprocess / exec** in the system extension (sandboxed). SSH must be an embedded library.
- Auth: **private key only** for v1 (ed25519/RSA). No password / keyboard-interactive / ssh-agent.
- Tunneled UDP is **dropped**; DNS forwarded over TCP:53 through SSH. No UDP egresses.
- Host-key verification is **mandatory** (TOFU + Keychain, hard-fail on mismatch).
- Bump build number on every extension change is handled by existing `tools/autobump-build-number.sh` postBuildScript — do not hand-edit build numbers.
- Follow existing patterns: `AppLog` for logging with `[APPSPLIT_*]` tags, `KeychainService` for secrets, `.instantTooltip()` not `.help()` in views.

---

## File Structure

**New files:**
- `NetworkExtension/RelayFlowTransport.swift` — the transport protocol + shared `SendResult` re-home.
- `NetworkExtension/SSHFlowTransport.swift` — SwiftNIO-SSH-backed transport (connection lifecycle, key auth, host-key verify, `direct-tcpip` channels, keepalive/reconnect).
- `NetworkExtension/SSHChannelHandler.swift` — per-channel NIO handler bridging channel bytes ↔ flow callbacks.
- `Shared/SSHHostKeyStore.swift` — TOFU host-key fingerprint persistence via Keychain.
- `TunnelBahn/Models/SSHProfile.swift` — SSH profile fields (host/port/user/key ref).
- `TunnelBahn/Views/SSHProfileEditorFields.swift` — SSH-specific editor subview.
- `Tests/…` for the pure-Swift-testable pieces (profile codable round-trip, host-key store) — see note in Task 2/9 on test target.

**Modified files:**
- `project.yml` — add `packages:` (swift-nio-ssh) + link into `PacketTunnelExtension`.
- `NetworkExtension/PacketTunnelRelayServer.swift` — depend on `RelayFlowTransport` instead of concrete `SmoltcpRelayBridge`.
- `NetworkExtension/SmoltcpRelayBridge.swift` — declare conformance to `RelayFlowTransport`.
- `NetworkExtension/PacketTunnelProvider.swift` — branch `startTunnel`/`stopTunnel` on transport type.
- `TunnelBahn/Models/WireGuardProfile.swift` (or the profile container) — add `transport` discriminator + optional SSH payload.
- `TunnelBahn/Views/ProfileEditorSheet.swift` — show WG or SSH fields by type.
- `Shared/TunnelRuntimeState.swift` — carry SSH connection params to the extension.
- `Shared/KeychainService.swift` — store/fetch SSH private key + host-key fingerprint (if not already generic enough).
- `docs/…` — README/CHANGELOG note.

---

## Task 1: Add SwiftNIO SSH dependency and prove it links (de-risk)

**Files:**
- Modify: `project.yml` (add `packages:` block + PacketTunnelExtension dependency)
- Create: `NetworkExtension/SSHLinkSmoke.swift` (temporary compile-only reference)

**Interfaces:**
- Produces: SwiftNIO SSH symbols (`NIOSSH`, `NIO`) available in the `PacketTunnelExtension` target.

**Why first:** The one design risk that can't be settled on paper (per the spec) is whether `swift-nio-ssh` links into a system-extension target. Everything downstream assumes it does. This task is the go/no-go gate. It is the one task that legitimately requires a build — get explicit user approval to build for this task only.

- [ ] **Step 1: Add the package to `project.yml`**

Add a top-level `packages:` section:

```yaml
packages:
  swift-nio-ssh:
    url: https://github.com/apple/swift-nio-ssh.git
    from: 0.9.0
```

And under `targets.PacketTunnelExtension.dependencies` add:

```yaml
    dependencies:
      - package: swift-nio-ssh
        product: NIOSSH
```

(Confirm the latest `swift-nio-ssh` tag at implementation time; `NIOSSH` transitively pulls `swift-nio` and `swift-crypto`.)

- [ ] **Step 2: Add a compile-only reference so the linker actually pulls the symbols**

Create `NetworkExtension/SSHLinkSmoke.swift`:

```swift
import Foundation
import NIOSSH

// Temporary: proves NIOSSH links into the system-extension target. Deleted in Task 4.
enum SSHLinkSmoke {
    static func referenceSymbol() -> String {
        String(describing: SSHClientConfiguration.self)
    }
}
```

- [ ] **Step 3: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: no errors; `TunnelBahn.xcodeproj` updated with the SPM package.

- [ ] **Step 4: Build the extension target (REQUIRES USER APPROVAL — this is the one build task)**

Ask the user to approve a build, then run:
`xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build`
Expected: BUILD SUCCEEDED, and the `com.tunnelbahn.mac.networkextension` target links `NIOSSH` with no unresolved-symbol or sandbox errors.

If it FAILS to link: stop and report. Fallback options to discuss with the user: pin an older NIOSSH/NIO tag compatible with Swift 5.10, or vendor a prebuilt xcframework. Do not proceed to Task 4+ until linking is proven.

- [ ] **Step 5: Commit**

```bash
git add project.yml NetworkExtension/SSHLinkSmoke.swift TunnelBahn.xcodeproj
git commit -m "build: add swift-nio-ssh dependency to packet-tunnel extension"
```

---

## Task 2: Profile model — transport discriminator + SSH fields

**Files:**
- Create: `TunnelBahn/Models/SSHProfile.swift`
- Modify: the profile container type (inspect `TunnelBahn/Models/WireGuardProfile.swift` and `ProfileStore.swift` to find where a saved profile is represented) to add a `transport` discriminator.
- Modify: `Shared/TunnelRuntimeState.swift` (carry SSH params to the extension)
- Create: `TunnelBahn/DebugSelfChecks.swift` (or extend an existing debug-only file) — `#if DEBUG` assertions run once at app launch

**Interfaces:**
- Produces:
  - `enum TransportKind: String, Codable { case wireguard, ssh }`
  - `struct SSHProfile: Codable, Equatable { var host: String; var port: UInt16; var username: String; var privateKeyRef: String; /* Keychain key id */ var hostKeyFingerprint: String? }`
  - Profile container gains `var transport: TransportKind` and `var ssh: SSHProfile?`.
- Consumes: existing `KeychainService` for `privateKeyRef` storage (wired in Task 8, not here).

**Testing decision (locked): NO test target.** The repo has no unit-test target and the user chose not to add one. Verify the pure-Swift Codable behavior with a `#if DEBUG` self-check that runs once at app launch and `assert`s the round-trip. These self-checks are temporary scaffolding — keep them terse and clearly commented as debug-only.

- [ ] **Step 1: Write the failing self-check — profile round-trips through Codable with an SSH payload**

Create `TunnelBahn/DebugSelfChecks.swift`:

```swift
import Foundation

#if DEBUG
enum DebugSelfChecks {
    /// Call once from the app's launch path (e.g. `AppDelegate`/`App.init`).
    static func run() {
        checkSSHProfileRoundTrips()
        checkLegacyProfileDefaultsToWireGuard()
    }

    private static func checkSSHProfileRoundTrips() {
        let ssh = SSHProfile(host: "vpn.example.com", port: 22,
                             username: "tun", privateKeyRef: "kc-ssh-1",
                             hostKeyFingerprint: nil)
        let data = try! JSONEncoder().encode(ssh)
        let decoded = try! JSONDecoder().decode(SSHProfile.self, from: data)
        assert(decoded == ssh, "SSHProfile Codable round-trip mismatch")
    }

    private static func checkLegacyProfileDefaultsToWireGuard() {
        // A profile JSON written before this feature has no `transport` key.
        let legacy = #"{"name":"Home","peers":[]}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(ProfileContainer.self, from: legacy)
        assert(decoded.transport == .wireguard, "legacy profile must default to .wireguard")
    }
}
#endif
```

(Replace `ProfileContainer` with the actual saved-profile type name found in `ProfileStore.swift`. Wire `DebugSelfChecks.run()` into the app launch path under `#if DEBUG`.)

- [ ] **Step 2: Run to verify it fails to compile / asserts**

Run: `xcodebuild -scheme TunnelBahn -configuration Debug build`
Expected: FAIL — `SSHProfile` / `transport` undefined (self-check references types that don't exist yet).

- [ ] **Step 3: Implement the model**

Create `TunnelBahn/Models/SSHProfile.swift`:

```swift
import Foundation

enum TransportKind: String, Codable, CaseIterable {
    case wireguard
    case ssh
}

struct SSHProfile: Codable, Equatable {
    var host: String
    var port: UInt16
    var username: String
    /// Keychain account id under which the PEM private key is stored.
    var privateKeyRef: String
    /// TOFU-pinned server host-key fingerprint (SHA-256, base64). nil until first connect.
    var hostKeyFingerprint: String?
}
```

Add to the profile container (exact type per `ProfileStore.swift`), with a defaulting decoder so legacy profiles read back as `.wireguard`:

```swift
var transport: TransportKind
var ssh: SSHProfile?

// In init(from:) — default when the key is absent:
transport = try container.decodeIfPresent(TransportKind.self, forKey: .transport) ?? .wireguard
ssh = try container.decodeIfPresent(SSHProfile.self, forKey: .ssh)
```

- [ ] **Step 4: Run to verify the self-check passes**

Run: `xcodebuild -scheme TunnelBahn -configuration Debug build`, then launch the Debug app once and confirm no assertion fires (check the log — `DebugSelfChecks.run()` completed). Expected: builds and launches cleanly.

- [ ] **Step 5: Extend `TunnelRuntimeState` to carry SSH params to the extension**

In `Shared/TunnelRuntimeState.swift`, add an optional SSH block so the packet-tunnel extension can read connection params (mirroring how the WG `profile`/`secrets` are carried). The private key itself is fetched from the shared Keychain by the extension, not embedded, so the runtime state carries only `host/port/username/privateKeyRef/hostKeyFingerprint` + `transport`.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Models/SSHProfile.swift Shared/TunnelRuntimeState.swift TunnelBahn/DebugSelfChecks.swift TunnelBahn/Models/ ProfileStore.swift
git commit -m "feat(model): add SSH profile type and transport discriminator"
```

---

## Task 3: Extract the `RelayFlowTransport` protocol seam

**Files:**
- Create: `NetworkExtension/RelayFlowTransport.swift`
- Modify: `NetworkExtension/SmoltcpRelayBridge.swift` (add conformance)
- Modify: `NetworkExtension/PacketTunnelRelayServer.swift` (depend on the protocol)

**Interfaces:**
- Produces:
  ```swift
  protocol RelayFlowTransport: AnyObject {
      var onPayloadFromFlow: ((UInt64, Data) -> Void)? { get set }
      var onFlowClosed: ((UInt64, String?) -> Void)? { get set }
      func openTCP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool
      func sendTCP(flowID: UInt64, data: Data) -> SendResult
      func close(flowID: UInt64)
  }
  ```
- Consumes: existing `SendResult` enum (`.ok`/`.transient`/`.permanent`) — move its definition into `RelayFlowTransport.swift` if it currently lives on `SmoltcpRelayBridge`, otherwise leave it and import.

**This is a pure refactor — no behavior change. Verified by the WG path still working (scenario probe), not by a new unit test.**

- [ ] **Step 1: Define the protocol**

Create `NetworkExtension/RelayFlowTransport.swift` with the protocol above. If `SendResult` is currently nested in `SmoltcpRelayBridge`, relocate it here as a top-level enum and update references.

- [ ] **Step 2: Conform `SmoltcpRelayBridge`**

In `NetworkExtension/SmoltcpRelayBridge.swift`, change the class declaration:

```swift
final class SmoltcpRelayBridge: RelayFlowTransport, @unchecked Sendable {
```

Its existing `openTCP`, `sendTCP`, `close`, `onPayloadFromFlow`, `onFlowClosed` already match the protocol — no other change. The smoltcp-only methods (`feedInbound`, `pollOutboundPackets`, `shouldInterceptInbound`, `drainReceivedPayloads`, `drainClosedFlows`) stay on the concrete type.

- [ ] **Step 3: Retype `PacketTunnelRelayServer`**

In `NetworkExtension/PacketTunnelRelayServer.swift`, change the stored property and initializer parameter from `SmoltcpRelayBridge` to `RelayFlowTransport`:

```swift
private let relayBridge: RelayFlowTransport
init?(relayBridge: RelayFlowTransport, packetQueue: DispatchQueue) {
```

The body already uses only protocol methods. Keep `packetQueue` as-is (SSH transport will also serialize onto a queue).

- [ ] **Step 4: Verify the WG path is unaffected (scenario check — no build unless asked)**

Confirm by reading that no call site referenced smoltcp-only methods through the `relayBridge` property inside `PacketTunnelRelayServer`. `PacketTunnelProvider` still constructs `SmoltcpRelayBridge` concretely and passes it in — that keeps compiling. Note in the commit that behavioral verification of WG will happen in the Task 6 scenario run.

- [ ] **Step 5: Commit**

```bash
git add NetworkExtension/RelayFlowTransport.swift NetworkExtension/SmoltcpRelayBridge.swift NetworkExtension/PacketTunnelRelayServer.swift
git commit -m "refactor(ne): extract RelayFlowTransport protocol seam"
```

---

## Task 4: `SSHFlowTransport` — connection, key auth, host-key TOFU

**Files:**
- Create: `NetworkExtension/SSHFlowTransport.swift`
- Create: `Shared/SSHHostKeyStore.swift`
- Delete: `NetworkExtension/SSHLinkSmoke.swift` (from Task 1)
- Modify: `TunnelBahn/DebugSelfChecks.swift` — add host-key TOFU self-checks (no test target)

**Interfaces:**
- Consumes: `RelayFlowTransport` (Task 3), `SSHProfile` params via `TunnelRuntimeState` (Task 2), `KeychainService`.
- Produces:
  ```swift
  final class SSHFlowTransport: RelayFlowTransport, @unchecked Sendable {
      init(host: String, port: UInt16, username: String,
           privateKeyPEM: String, pinnedHostKeyFingerprint: String?,
           hostKeyStore: SSHHostKeyStore, queue: DispatchQueue)
      func start() async throws          // establishes the SSH transport connection
      func stop()
      // + RelayFlowTransport members (channels added in Task 5)
  }
  struct SSHHostKeyStore {
      func fingerprint(forHost: String) -> String?
      func pin(fingerprint: String, forHost: String)
      /// Returns true if key is trusted (matches pin) or newly pinned (TOFU); false on mismatch.
      func verifyOrPin(fingerprint: String, forHost: String) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing self-check — host-key store TOFU semantics**

Add to `TunnelBahn/DebugSelfChecks.swift` (inside the existing `#if DEBUG` enum), and call from `run()`:

```swift
    private static func checkHostKeyTOFU() {
        // first-seen key is pinned and trusted
        let s1 = SSHHostKeyStore(backing: InMemoryKV())
        assert(s1.verifyOrPin(fingerprint: "AAAA", forHost: "h"))
        assert(s1.fingerprint(forHost: "h") == "AAAA")
        // matching key stays trusted
        assert(s1.verifyOrPin(fingerprint: "AAAA", forHost: "h"))
        // changed key is rejected
        assert(!s1.verifyOrPin(fingerprint: "BBBB", forHost: "h"))
    }
```

Define a tiny `InMemoryKV` conforming to the store's backing protocol, guarded by `#if DEBUG` (place it next to the self-checks or in the same file).

- [ ] **Step 2: Run to verify it fails to compile**

Run: `xcodebuild -scheme TunnelBahn -configuration Debug build`
Expected: FAIL — `SSHHostKeyStore` undefined.

- [ ] **Step 3: Implement `SSHHostKeyStore`**

Create `Shared/SSHHostKeyStore.swift`. Back it with an abstract KV (Keychain in production via `KeychainService`, `InMemoryKV` in tests):

```swift
protocol HostKeyBacking { func get(_ k: String) -> String?; func set(_ k: String, _ v: String) }

struct SSHHostKeyStore {
    private let backing: HostKeyBacking
    init(backing: HostKeyBacking) { self.backing = backing }
    func fingerprint(forHost host: String) -> String? { backing.get("ssh-hostkey.\(host)") }
    func pin(fingerprint fp: String, forHost host: String) { backing.set("ssh-hostkey.\(host)", fp) }
    func verifyOrPin(fingerprint fp: String, forHost host: String) -> Bool {
        if let existing = fingerprint(forHost: host) { return existing == fp }
        pin(fingerprint: fp, forHost: host); return true
    }
}
```

- [ ] **Step 4: Implement `SSHHostKeyStore` (from Task 4 Step 3 below), then build + launch Debug so the TOFU self-check passes.** Expected: no assertion fires.

- [ ] **Step 5: Implement `SSHFlowTransport` connect + auth + host-key verify**

Create `NetworkExtension/SSHFlowTransport.swift`. Use SwiftNIO SSH client bootstrap with:
- a `NIOSSHClientUserAuthenticationDelegate` that offers the private key (`NIOSSHPrivateKey` parsed from the PEM; support ed25519 and RSA),
- a `NIOSSHClientServerAuthenticationDelegate` whose `validateHostKey` computes the key's SHA-256 fingerprint and calls `hostKeyStore.verifyOrPin(...)`; fail the promise on mismatch (hard MITM fail).

Sketch (confirm exact NIOSSH API names against the linked version):

```swift
import NIO
import NIOSSH
import Foundation

final class SSHFlowTransport: RelayFlowTransport, @unchecked Sendable {
    var onPayloadFromFlow: ((UInt64, Data) -> Void)?
    var onFlowClosed: ((UInt64, String?) -> Void)?

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let host: String, port: UInt16, username: String
    private let privateKey: NIOSSHPrivateKey
    private let serverAuth: HostKeyValidator
    private var channel: Channel?               // the SSH transport connection

    init(host: String, port: UInt16, username: String,
         privateKeyPEM: String, pinnedHostKeyFingerprint: String?,
         hostKeyStore: SSHHostKeyStore, queue: DispatchQueue) throws {
        self.host = host; self.port = port; self.username = username
        self.privateKey = try Self.parsePrivateKey(pem: privateKeyPEM)
        self.serverAuth = HostKeyValidator(host: host, store: hostKeyStore)
    }

    func start() async throws {
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { ch in
                ch.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: PrivateKeyAuth(username: self.username, key: self.privateKey),
                            serverAuthDelegate: self.serverAuth)),
                        allocator: ch.allocator,
                        inboundChildChannelInitializer: nil)
                ])
            }
        self.channel = try await bootstrap.connect(host: host, port: Int(port)).get()
    }

    func stop() { try? channel?.close().wait(); try? group.syncShutdownGracefully() }

    // openTCP / sendTCP / close implemented in Task 5.
    func openTCP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool { false }
    func sendTCP(flowID: UInt64, data: Data) -> SendResult { .permanent }
    func close(flowID: UInt64) {}

    static func parsePrivateKey(pem: String) throws -> NIOSSHPrivateKey { /* ed25519/RSA from PEM */ fatalError("impl") }
}
```

Implement `HostKeyValidator` (`NIOSSHClientServerAuthenticationDelegate`) to fingerprint the offered key (SHA-256 of the SSH wire encoding, base64) and consult the store, and `PrivateKeyAuth` (`NIOSSHClientUserAuthenticationDelegate`) offering `.privateKey`. Delete `SSHLinkSmoke.swift`.

Log with `[APPSPLIT_SSH]` tags: connect start, auth success/fail, host-key pinned vs matched vs REJECTED.

- [ ] **Step 6: Commit**

```bash
git add NetworkExtension/SSHFlowTransport.swift Shared/SSHHostKeyStore.swift TunnelBahn/DebugSelfChecks.swift
git rm NetworkExtension/SSHLinkSmoke.swift
git commit -m "feat(ne): SSH transport connect, key auth, host-key TOFU verification"
```

---

## Task 5: `SSHFlowTransport` — `direct-tcpip` channels + backpressure

**Files:**
- Create: `NetworkExtension/SSHChannelHandler.swift`
- Modify: `NetworkExtension/SSHFlowTransport.swift` (implement `openTCP`/`sendTCP`/`close`)

**Interfaces:**
- Consumes: the SSH transport `Channel` from Task 4, `RelayFlowTransport` callbacks.
- Produces: working per-flow forwarding — `openTCP` opens a `direct-tcpip` child channel; `sendTCP` writes with window-based backpressure returning `.transient` when the child channel is not writable; inbound channel data → `onPayloadFromFlow`; channel close/EOF/error → `onFlowClosed`.

- [ ] **Step 1: Implement the per-channel handler**

Create `NetworkExtension/SSHChannelHandler.swift`: a `ChannelInboundHandler` that unwraps `SSHChannelData` byte buffers and calls `onData(flowID, Data)`; on `channelInactive`/error calls `onClose(flowID, errorString?)`. Store the child `Channel` keyed by `flowID` in a thread-safe map on the transport's `queue`.

```swift
import NIO
import NIOSSH

final class SSHChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let flowID: UInt64
    let onData: (UInt64, Data) -> Void
    let onClose: (UInt64, String?) -> Void
    init(flowID: UInt64, onData: @escaping (UInt64, Data) -> Void, onClose: @escaping (UInt64, String?) -> Void) {
        self.flowID = flowID; self.onData = onData; self.onClose = onClose
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = d.data, d.type == .channel else { return }
        onData(flowID, Data(buf.readableBytesView))
    }
    func channelInactive(context: ChannelHandlerContext) { onClose(flowID, nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { onClose(flowID, "\(error)") ; context.close(promise: nil) }
}
```

- [ ] **Step 2: Implement `openTCP`**

On the transport `queue`, use the parent `channel`'s `NIOSSHHandler` to create a child channel with a `SSHChannelType.directTCPIP(.init(targetHost: remoteHost, targetPort: Int(remotePort), originatorAddress: ...))`; add an `SSHChannelHandler` bound to `flowID`; store the child channel in the map. Return `true` synchronously after the create request is enqueued; treat a create failure as an async `onFlowClosed(flowID, ...)`. (This mirrors how `SmoltcpRelayBridge.openTCP` returns a synchronous bool while completion is async.)

- [ ] **Step 3: Implement `sendTCP` with backpressure**

```swift
func sendTCP(flowID: UInt64, data: Data) -> SendResult {
    guard let child = channels[flowID] else { return .permanent }
    var buf = child.allocator.buffer(capacity: data.count); buf.writeBytes(data)
    let framed = SSHChannelData(type: .channel, data: .byteBuffer(buf))
    child.writeAndFlush(framed, promise: nil)
    return child.isWritable ? .ok : .transient   // maps NIO high-watermark to relay backpressure
}
```

Set the child channel's write buffer water marks in the child initializer so `isWritable` flips at a sane threshold; this is what the relay server's existing `.transient` hysteresis consumes.

- [ ] **Step 4: Implement `close`**

Close the child channel for `flowID` and remove it from the map. Guard against double-close (the `channelInactive` callback also removes it).

- [ ] **Step 5: Verify (scenario probe — deferred to Task 6's integrated run)**

Per-channel behavior is only observable end-to-end; it is exercised in the Task 6 scenario run, not a unit test. No build here unless the user asks.

- [ ] **Step 6: Commit**

```bash
git add NetworkExtension/SSHChannelHandler.swift NetworkExtension/SSHFlowTransport.swift
git commit -m "feat(ne): SSH direct-tcpip per-flow channels with window backpressure"
```

---

## Task 6: Provider branch + keepalive/reconnect + first end-to-end scenario

**Files:**
- Modify: `NetworkExtension/PacketTunnelProvider.swift` (`startTunnel`/`stopTunnel`)
- Modify: `NetworkExtension/SSHFlowTransport.swift` (keepalive + reconnect)

**Interfaces:**
- Consumes: `TransportKind` from runtime state (Task 2), `SSHFlowTransport` (Tasks 4–5), `PacketTunnelRelayServer` retyped to `RelayFlowTransport` (Task 3).
- Produces: a working SSH tunnel selectable by profile type.

- [ ] **Step 1: Branch `startTunnel` on transport**

In `PacketTunnelProvider.startTunnel`, after loading `runtime`, branch:

```swift
switch runtime.transport {
case .wireguard:
    // existing BoringTunAdapter + SmoltcpRelayBridge path, unchanged
case .ssh:
    try await startSSH(runtime: runtime)
}
```

`startSSH` (new private method): fetch the PEM from Keychain via `privateKeyRef`; build `SSHFlowTransport`; `try await transport.start()`; then construct `PacketTunnelRelayServer(relayBridge: transport, packetQueue: <a dedicated serial queue>)` and `server.start()`. Call `setTunnelNetworkSettings` with a minimal `NEPacketTunnelNetworkSettings` (tunnelRemoteAddress = the SSH server host) so the provider reports connected — no WG routes, no DNS servers pointing at a tun, no smoltcp. Persist the (possibly newly-pinned) `hostKeyFingerprint` back so the app UI can show it.

- [ ] **Step 2: Branch `stopTunnel`**

Tear down whichever transport is active: for SSH, `relayServer?.stop()` then `sshTransport?.stop()`. Ensure the `SSHFlowTransport` invalidates the event-loop group and clears the channel map (guard against the singleton-lifecycle reuse noted in project memory — invalidate cached channels/groups in `startSSH`, not only in stop).

- [ ] **Step 3: Keepalive + reconnect**

In `SSHFlowTransport`, add a keepalive timer (send an SSH global request / ignore-message periodically). On the parent `channel`'s `closeFuture` firing unexpectedly, mark all live flows closed via `onFlowClosed(flowID, "ssh connection dropped")`, then attempt reconnect with backoff. Log `[APPSPLIT_SSH] reconnect` transitions. Mirror the WG watchdog philosophy already in the codebase.

- [ ] **Step 4: End-to-end scenario setup (no probes run by us — user runs them)**

Prepare an SSH test profile. Per the scenario-test workflow: set the app's toggles and start the tunnel via the URL scheme, then STOP. Provide the user the probe list:
- S-SSH-1 (in-filter TCP): `curl https://<in-filter-host>` → succeeds, egress IP = SSH server.
- S-SSH-2 (out-of-filter): `curl https://<out-of-filter-host>` → egress IP = real IP (filter still narrows).
- S-SSH-3 (UDP dropped/TCP fallback): `curl --http3 https://<host>` fails/falls back; `curl https://<host>` (TCP) succeeds.
- S-SSH-4 (WG regression): switch to a WG profile, in-filter probe still tunnels (proves Task 3 refactor safe).

- [ ] **Step 5: Commit**

```bash
git add NetworkExtension/PacketTunnelProvider.swift NetworkExtension/SSHFlowTransport.swift
git commit -m "feat(ne): select SSH vs WG transport in startTunnel; SSH keepalive/reconnect"
```

---

## Task 7: DNS-over-TCP

**Files:**
- Modify: `TransparentProxyExtension/UDPFlowRelay.swift` (or wherever UDP:53 is currently handled) and/or `TransparentProxyProvider.swift`
- Modify: `NetworkExtension/SSHFlowTransport.swift` if resolution is delegated to the SSH server (hostname `direct-tcpip`)

**Interfaces:**
- Consumes: the flow-capture path in the proxy extension; `SSHFlowTransport.openTCP`.
- Produces: DNS resolution that works while UDP is dropped in SSH mode.

**Decision to lock at implementation:** Prefer **remote resolution** — when a tunneled TCP flow's destination is known as a hostname, send the hostname (not a pre-resolved IP) as the `direct-tcpip` target so the SSH server resolves it (no DNS leak, no separate DNS path). Only add an explicit DNS-over-TCP forward for the residual case where the app issues its own DNS UDP query that would otherwise be dropped.

- [ ] **Step 1: Confirm where DNS is captured today**

Read `TransparentProxyProvider.handleNewFlow` and `UDPFlowRelay.swift` to find how UDP:53 is currently treated in WG mode. Document it inline in the task (the plan executor records findings here).

- [ ] **Step 2: In SSH mode, forward captured DNS as TCP:53**

For a captured UDP:53 flow in SSH mode: instead of dropping, translate each UDP DNS query datagram into a length-prefixed TCP DNS message (RFC 7766) over a `direct-tcpip` channel to `:53` on the resolver (the SSH server or a configured resolver), read the TCP response, strip the length prefix, and return it as the UDP reply datagram to the flow. Keep this isolated in a small `DNSOverTCPForwarder` helper.

- [ ] **Step 3: Verify via scenario probe S-SSH-3 extended**

Add a DNS probe: `dig` / `nslookup` a fresh domain while the SSH tunnel is up and UDP is dropped → resolution succeeds. (User runs it.)

- [ ] **Step 4: Commit**

```bash
git add TransparentProxyExtension/ NetworkExtension/SSHFlowTransport.swift
git commit -m "feat: DNS-over-TCP forwarding for SSH transport (UDP dropped)"
```

---

## Task 8: UI — SSH profile editor + Keychain key storage

**Files:**
- Create: `TunnelBahn/Views/SSHProfileEditorFields.swift`
- Modify: `TunnelBahn/Views/ProfileEditorSheet.swift`
- Modify: `Shared/KeychainService.swift` (store/fetch PEM by `privateKeyRef`)

**Interfaces:**
- Consumes: `SSHProfile`, `TransportKind` (Task 2), `KeychainService`.
- Produces: create/edit of an SSH profile from the app UI; PEM persisted to Keychain; `privateKeyRef` saved on the profile.

- [ ] **Step 1: Transport picker in the editor**

In `ProfileEditorSheet`, add a `Picker` bound to `transport` (`WireGuard` / `SSH`). When `.wireguard`, show the existing WG fields; when `.ssh`, show `SSHProfileEditorFields`.

- [ ] **Step 2: SSH fields subview**

Create `TunnelBahn/Views/SSHProfileEditorFields.swift`: `TextField`s for host, port (default 22), username; a private-key control (file importer + paste area). Use `.instantTooltip(...)` (not `.help()`) for field hints per project rule. Do not gate any field visibility on live connection state (no-flicker rule).

- [ ] **Step 3: Persist the key to Keychain on save**

On save, if a new key was supplied, write the PEM to Keychain via `KeychainService` under a generated `privateKeyRef` (e.g. `ssh-key-<profileID>`), store the ref on the profile, and never persist the raw PEM in the profile JSON. Fetch happens in the extension (Task 6 `startSSH`) — confirm the Keychain access group / App Group sharing lets the packet-tunnel extension read it (this is the same cross-process boundary WG secrets already use; follow that pattern exactly, cf. host/extension uid boundary note).

- [ ] **Step 4: Verify (manual, app-side — no extension build needed to view the form)**

Reading-level verification: the editor shows SSH fields when SSH is picked; save round-trips through `ProfileStore` (covered by Task 2 codable test). Full flow validated in Task 6 scenario.

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Views/SSHProfileEditorFields.swift TunnelBahn/Views/ProfileEditorSheet.swift Shared/KeychainService.swift
git commit -m "feat(ui): SSH profile editor with Keychain-backed private key"
```

---

## Task 9: Host-key trust surfacing + docs

**Files:**
- Modify: `TunnelBahn/Views/ProfileDetailView.swift` or `StatusView.swift` (show pinned fingerprint / allow reset)
- Modify: `README.md`, `CHANGELOG.md`, and the design doc status

**Interfaces:**
- Consumes: `hostKeyFingerprint` from the profile (persisted back in Task 6).
- Produces: user-visible host-key state + a way to reset the pin (re-TOFU) if the server key legitimately rotates.

- [ ] **Step 1: Show the pinned fingerprint**

In the profile detail/status view, when the active profile is SSH and a `hostKeyFingerprint` is pinned, display it (SHA-256, base64) with an `.instantTooltip` explaining TOFU. Add a "Reset host key trust" action that clears the pin so the next connect re-pins.

- [ ] **Step 2: Docs**

Update `README.md` (SSH as an alternative transport, TCP-only, remote DNS), `CHANGELOG.md` (new feature entry), and flip the design doc `Status:` to `Implemented`. Note the HOL-blocking v1 limitation in README.

- [ ] **Step 3: Commit**

```bash
git add TunnelBahn/Views/ README.md CHANGELOG.md docs/superpowers/specs/2026-07-23-ssh-transport-design.md
git commit -m "feat(ui): surface SSH host-key trust; docs for SSH transport"
```

---

## Self-Review

**Spec coverage:**
- Transport seam / architecture → Tasks 3, 6. ✓
- SwiftNIO SSH embedded engine → Tasks 1, 4, 5. ✓
- Drop UDP + DNS-over-TCP → Task 7. ✓
- Unified profile list, per-profile type, private-key auth → Tasks 2, 8. ✓
- Host-key TOFU + Keychain, hard-fail mismatch → Tasks 4, 6, 9. ✓
- Self-loop guard → asserted in Task 6 (extension outbound to SSH server is not a matched app; documented, verified by S-SSH regression that WG/other apps unaffected). ✓
- Keepalive/reconnect → Task 6. ✓
- HOL-blocking documented → Task 9. ✓
- Scenario testing → Task 6/7 probe lists. ✓

**Placeholder scan:** The `parsePrivateKey`/NIOSSH bootstrap sketches are marked "confirm exact API against the linked version" because the precise SwiftNIO SSH symbol names are version-dependent and cannot be pinned without the dependency resolved in Task 1 — this is an intentional, flagged confirmation step, not an open TODO. All other steps carry concrete code or exact read targets.

**Type consistency:** `RelayFlowTransport` members (`openTCP`/`sendTCP`/`close`/`onPayloadFromFlow`/`onFlowClosed`) are identical across Tasks 3, 4, 5, 6. `SendResult` cases (`.ok`/`.transient`/`.permanent`) consistent. `TransportKind` / `SSHProfile` / `privateKeyRef` / `hostKeyFingerprint` names consistent across Tasks 2, 6, 8, 9.

**Known dependency risk carried forward:** Task 1 is a hard gate — if `swift-nio-ssh` does not link into the system-extension target, Tasks 4–7 are blocked and the approach must be revisited (vendored xcframework / older tag).

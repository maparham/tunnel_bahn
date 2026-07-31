# Exclude-Mode Destination Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-profile "exclude" destination-filter mode: tunnel everything EXCEPT the listed CIDRs/domains (e.g. route only non-Iranian IPs through the tunnel), with a per-profile local-DNS toggle.

**Architecture:** A `DestinationFilterMode` enum rides inside the existing `DestinationRoutingFilePayload` (which is embedded in `TransparentProxyRuntimeConfig`, so the extension gets it for free). In exclude mode the transparent proxy publishes catch-all intercept rules and inverts the per-flow decision: a new pure helper `DestinationRouteDecision.decide` is the single source of truth for both the TCP SNI decider and the UDP per-datagram path. TCP flows to excluded IPs are declined at flow-open (OS routes them via en0). The DNS toggle is implemented app-side by nil-ing `tunnelDNSHost`.

**Tech Stack:** Swift, NetworkExtension (NEAppProxyProvider), SwiftUI, XcodeGen, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-31-exclude-mode-routing-design.md`. One approved deviation: the UI uses a THIRD radio button in the existing radio group ("Tunnel all except selected") instead of the spec's nested segmented picker — the spec was written before seeing that `RoutingView.restrictProxySection()` is already a radio group; three peers fit it better than a nested picker.

## Global Constraints

- **No xcodebuild without user OK (project standing rule, see 2026-07-23 plan):** ask the user for a go-ahead before ANY `xcodebuild` build/test invocation (a blanket OK at session start counts). Never launch the app or touch the running tunnel/system extension yourself — jammed-sysext state is a known hazard (see project memory).
- **`project.yml` is the source of truth** for the Xcode project. After editing it, run `xcodegen generate` from the repo root (this rewrites `TunnelBahn.xcodeproj`).
- **Strict decoding (user decision 2026-07-31, supersedes the spec's decode-tolerance requirement):** the repo removed all backward-compat/tolerant decoding in d06f56c ("app is undistributed"). New Codable keys use synthesized strict decoding — required keys, NO `decodeIfPresent` fallbacks, no legacy-JSON tests. Defaults live only in memberwise-init parameters (`filterMode = .include`, `localDNSForExcluded = false`) so existing call sites compile unchanged. Persisted data from older builds failing to decode is acceptable.
- **Version skew is ACCEPTED residual risk (user decision, 2026-07-31):** a stale pre-filterMode system extension reads an exclude config as a whitelist (tunnels only the excluded CIDRs, leaks the rest). No handshake/capability probe is to be built — old extensions are the user's responsibility to remove. Do not add compatibility shims for this; see the spec's "Accepted residual risk" section.
- **Include mode must be byte-for-byte behavior-identical** to today. All new branches are gated on `mode == .exclude`.
- Commit after each task with a conventional-commit message (`feat(...)`, `test(...)`), ending with the Claude co-author trailer used in this repo.
- Test command (after user OK): `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -only-testing:TunnelBahnUnitTests -configuration Debug 2>&1 | tail -30` (the scheme's test action runs `TunnelBahnUnitTests`).
- Build check command (after user OK): `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build 2>&1 | tail -5`

---

### Task 1: Shared mode enum, decision helper, payload field + unit tests

**Files:**
- Modify: `Shared/DestinationRouting.swift` (types + `DestinationRoutingFilePayload`)
- Modify: `project.yml` (add sources to `TunnelBahnUnitTests`)
- Test: `Tests/Unit/DestinationRoutingModeTests.swift` (create)

**Interfaces:**
- Produces: `public enum DestinationFilterMode: String, Codable, Sendable { case include, exclude }`; `public enum DestinationRouteVerdict: Equatable, Sendable { case tunnel, direct }`; `public enum DestinationRouteDecision { static func decide(mode:ipMatch:sniMatch:) -> DestinationRouteVerdict }`; `DestinationRoutingFilePayload.filterMode: DestinationFilterMode` (init param defaulted to `.include`). Every later task consumes these exact names.

- [ ] **Step 1: Add test-target sources to project.yml**

In `project.yml`, under `TunnelBahnUnitTests: → sources:`, append (Tests/Unit is already a path entry, so the new test file is picked up automatically):

```yaml
      - path: Shared/DestinationRouting.swift
      - path: Shared/TransparentProxyRuntimeConfig.swift
```

Note: `Shared/TransparentProxyRuntimeConfig.swift` also declares `RemoteDNSTargetSelector`; it has no other file deps. Run: `xcodegen generate`

- [ ] **Step 2: Write the failing tests**

Create `Tests/Unit/DestinationRoutingModeTests.swift`:

```swift
import XCTest

final class DestinationRoutingModeTests: XCTestCase {
    // MARK: - DestinationRouteDecision

    func testIncludeModeSniMatchTunnels() {
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .include, ipMatch: false, sniMatch: true), .tunnel)
    }

    func testIncludeModeIpMatchTunnels() {
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .include, ipMatch: true, sniMatch: false), .tunnel)
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .include, ipMatch: true, sniMatch: nil), .tunnel)
    }

    func testIncludeModeNoMatchGoesDirect() {
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .include, ipMatch: false, sniMatch: false), .direct)
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .include, ipMatch: false, sniMatch: nil), .direct)
    }

    func testExcludeModeSniMatchGoesDirect() {
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .exclude, ipMatch: false, sniMatch: true), .direct)
    }

    func testExcludeModeIpMatchGoesDirect() {
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .exclude, ipMatch: true, sniMatch: false), .direct)
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .exclude, ipMatch: true, sniMatch: nil), .direct)
    }

    func testExcludeModeNoMatchTunnels() {
        // The fail-open inversion: unknown traffic tunnels in exclude mode.
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .exclude, ipMatch: false, sniMatch: false), .tunnel)
        XCTAssertEqual(DestinationRouteDecision.decide(mode: .exclude, ipMatch: false, sniMatch: nil), .tunnel)
    }

    // MARK: - DestinationRoutingFilePayload codec

    func testPayloadRoundTripsExclude() throws {
        let payload = DestinationRoutingFilePayload(
            enforceDestinationFiltering: true, ranges: ["5.22.0.0/16"], domainNames: ["digikala.com"], filterMode: .exclude
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DestinationRoutingFilePayload.self, from: data)
        XCTAssertEqual(decoded.filterMode, .exclude)
        XCTAssertEqual(decoded, payload)
    }

    // MARK: - TransparentProxyRuntimeConfig passthrough (filterMode rides inside destinationRouting)

    func testRuntimeConfigCarriesExcludeMode() throws {
        let cfg = TransparentProxyRuntimeConfig(
            signingIdentifiers: [],
            routeAllIdentifiedFlows: true,
            destinationRouting: DestinationRoutingFilePayload(
                enforceDestinationFiltering: true, ranges: [], filterMode: .exclude
            ),
            dropTunneledUDP: false,
            remoteDNSResolution: false
        )
        let b64 = try TransparentProxyRuntimeConfig.encodeBase64(cfg)
        let decoded = TransparentProxyRuntimeConfig.decode(from: [TransparentProxyRuntimeConfig.providerConfigurationKey: b64])
        XCTAssertEqual(decoded?.destinationRouting.filterMode, .exclude)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

(After user OK.) Run the test command from Global Constraints. Expected: compile FAILURE — `DestinationRouteDecision`/`filterMode` not defined. That is the failing state for type-level TDD.

- [ ] **Step 4: Implement the types**

In `Shared/DestinationRouting.swift`, above `DestinationRoutingFilePayload`, add:

```swift
/// Whether the destination rule set selects what to TUNNEL (`include` — the historical
/// whitelist behavior) or what to send DIRECT while everything else tunnels (`exclude`).
public enum DestinationFilterMode: String, Codable, Sendable {
    case include
    case exclude
}

public enum DestinationRouteVerdict: Equatable, Sendable {
    case tunnel
    case direct
}

/// Pure tunnel-vs-direct choice given rule-match results — the single source of truth for
/// both the TCP SNI decider and the UDP per-datagram path, so the two cannot drift.
/// `sniMatch` is nil when no SNI is available (non-TLS, fragmented ClientHello, no peek).
/// Note the fail-open inversion: include mode's no-match falls back to DIRECT; exclude
/// mode's no-match falls back to TUNNEL (unknown traffic belongs in the tunnel there).
public enum DestinationRouteDecision {
    public static func decide(mode: DestinationFilterMode, ipMatch: Bool, sniMatch: Bool?) -> DestinationRouteVerdict {
        let matchesRules = (sniMatch == true) || ipMatch
        switch mode {
        case .include: return matchesRules ? .tunnel : .direct
        case .exclude: return matchesRules ? .direct : .tunnel
        }
    }
}
```

In `DestinationRoutingFilePayload`: add `public var filterMode: DestinationFilterMode` after `domainNames`; add init param `filterMode: DestinationFilterMode = .include` (last position) and assign it. Codable stays synthesized (strict, per Global Constraints) — no custom `CodingKeys`/`init(from:)`.

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: all `DestinationRoutingModeTests` PASS (and pre-existing tests still pass).

- [ ] **Step 6: Commit**

```bash
git add Shared/DestinationRouting.swift project.yml TunnelBahn.xcodeproj Tests/Unit/DestinationRoutingModeTests.swift
git commit -m "feat(routing): DestinationFilterMode + pure route-decision helper in shared payload"
```

---

### Task 2: ProfileRoutingSnapshot fields + codec tests

**Files:**
- Modify: `TunnelBahn/Models/ProfileRoutingSnapshot.swift`
- Modify: `project.yml` (more test-target sources)
- Test: `Tests/Unit/ProfileRoutingSnapshotCodecTests.swift` (create)

**Interfaces:**
- Consumes: `DestinationFilterMode` (Task 1).
- Produces: `ProfileRoutingSnapshot.filterMode: DestinationFilterMode` and `.localDNSForExcluded: Bool`, both with defaulted init params so existing call sites compile unchanged.

- [ ] **Step 1: Add model sources to the test target**

In `project.yml` under `TunnelBahnUnitTests: → sources:` append:

```yaml
      - path: TunnelBahn/Models/ProfileRoutingSnapshot.swift
      - path: TunnelBahn/Models/RoutingMode.swift
      - path: TunnelBahn/Models/AppRule.swift
      - path: Shared/RoutingAction.swift
      - path: TunnelBahn/Models/DestinationCidrRule.swift
      - path: TunnelBahn/Models/DestinationCidrBulkGroup.swift
      - path: TunnelBahn/Models/DestinationDomainRule.swift
```

(`AppRule` needs `RoutingAction` from Shared; all are small self-contained Codable models. If the compiler names one more missing type, add that file the same way.) Run: `xcodegen generate`

- [ ] **Step 2: Write the failing tests**

Create `Tests/Unit/ProfileRoutingSnapshotCodecTests.swift`:

```swift
import XCTest

final class ProfileRoutingSnapshotCodecTests: XCTestCase {
    func testDefaultSnapshotIsIncludeWithTunnelDNS() {
        let s = ProfileRoutingSnapshot.default
        XCTAssertEqual(s.filterMode, .include)
        XCTAssertFalse(s.localDNSForExcluded)
    }

    func testSnapshotRoundTripsExcludeAndLocalDNS() throws {
        var s = ProfileRoutingSnapshot.default
        s.filterMode = .exclude
        s.localDNSForExcluded = true
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ProfileRoutingSnapshot.self, from: data)
        XCTAssertEqual(decoded.filterMode, .exclude)
        XCTAssertTrue(decoded.localDNSForExcluded)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run the test command. Expected: compile FAILURE — `filterMode` not a member of `ProfileRoutingSnapshot`.

- [ ] **Step 4: Implement the fields**

In `ProfileRoutingSnapshot`: add stored properties after `domainRules`:

```swift
var filterMode: DestinationFilterMode
/// Exclude mode only: suppress the tunnel-DNS redirect so routed apps resolve via the
/// local resolver (better domestic CDN steering; local DNS filtering applies).
var localDNSForExcluded: Bool
```

Memberwise init: append parameters `filterMode: DestinationFilterMode = .include, localDNSForExcluded: Bool = false` (after `domainRules`, which already has a default) and assign them. Codable stays synthesized (strict, per Global Constraints — after d06f56c the type has no custom `CodingKeys`/`init(from:)`; do not add any). `static var default` needs no change (init defaults cover it).

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Models/ProfileRoutingSnapshot.swift project.yml TunnelBahn.xcodeproj Tests/Unit/ProfileRoutingSnapshotCodecTests.swift
git commit -m "feat(routing): filterMode + localDNSForExcluded in profile snapshot (tolerant decode)"
```

---

### Task 3: AppSettings + AppState plumbing

**Files:**
- Modify: `TunnelBahn/Services/AppSettings.swift`
- Modify: `TunnelBahn/AppState.swift` (`bindChildStores` merge block ~line 129-145, `installRoutingSnapshot` ~line 208, `saveSnapshot` ~line 237, `syncDestinationRoutingFileWithPreferences` ~line 420)

**Interfaces:**
- Consumes: `ProfileRoutingSnapshot.filterMode/.localDNSForExcluded` (Task 2).
- Produces: `AppSettings.destinationFilterMode: DestinationFilterMode` and `AppSettings.localDNSForExcluded: Bool` (`@Published`, snapshot-backed, NOT UserDefaults-persisted — same pattern as `enforceDestinationFiltering`). Task 4 (VPNManager) and Task 8 (RoutingView) read these.

- [ ] **Step 1: Add the settings**

In `AppSettings`, after `destinationDomainNamesEnabled`:

```swift
/// Set by AppState when a profile is selected; not persisted independently.
@Published var destinationFilterMode: DestinationFilterMode = .include

/// Exclude mode only: when true, routed apps' DNS is not redirected to the tunnel
/// resolver. Set by AppState when a profile is selected; not persisted independently.
@Published var localDNSForExcluded: Bool = false
```

- [ ] **Step 2: Wire snapshot install/save**

In `AppState.installRoutingSnapshot`, next to the `settings.enforceDestinationFiltering = ...` line:

```swift
settings.destinationFilterMode = snapshot.filterMode
settings.localDNSForExcluded = snapshot.localDNSForExcluded
```

In `AppState.saveSnapshot`, add to the `ProfileRoutingSnapshot(...)` construction:

```swift
filterMode: settings.destinationFilterMode,
localDNSForExcluded: settings.localDNSForExcluded
```

- [ ] **Step 3: Wire the debounced-save publisher**

In `bindChildStores`, in the merge chain that already lists `settings.$enforceDestinationFiltering` (~line 133), add two more lines in the same style:

```swift
.merge(with: settings.$destinationFilterMode.dropFirst().map { _ in () }.eraseToAnyPublisher())
.merge(with: settings.$localDNSForExcluded.dropFirst().map { _ in () }.eraseToAnyPublisher())
```

- [ ] **Step 4: Thread mode into the host-side routing-file sync**

`AppState.syncDestinationRoutingFileWithPreferences` calls `vpnManager.syncDestinationRoutingFromHostActivity(enforceFiltering:flattenedRangeStrings:)`. Add a `filterMode: settings.destinationFilterMode` argument at that call site, and update BOTH VPNManager functions it depends on now, in this task (the defaulted parameters keep every other call site compiling; Task 4 builds on these signatures):

```swift
@MainActor
func syncDestinationRoutingFromHostActivity(enforceFiltering: Bool, flattenedRangeStrings: [String], filterMode: DestinationFilterMode = .include) {
    persistDestinationRoutingFromHost(enforceFiltering: enforceFiltering, ranges: flattenedRangeStrings, filterMode: filterMode)
}
```

And in `persistDestinationRoutingFromHost`: add a `filterMode: DestinationFilterMode = .include` parameter and pass `filterMode: filterMode` into the `DestinationRoutingFilePayload(...)` it builds (Task 4 Step 2 then only adds its traceLog field).

- [ ] **Step 5: Build check**

(After user OK.) Run the build check command. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Services/AppSettings.swift TunnelBahn/AppState.swift TunnelBahn/Services/VPNManager.swift
git commit -m "feat(app): filter-mode + local-DNS settings plumbed through profile snapshot lifecycle"
```

---

### Task 4: VPNManager connect-path plumbing

**Files:**
- Modify: `TunnelBahn/Services/VPNManager.swift` (`connect` destination block ~lines 358-416, `makeTransparentProxyRuntimeConfig` ~line 1383, `persistDestinationRoutingFromHost` ~line 1476)

**Interfaces:**
- Consumes: `AppSettings.destinationFilterMode/.localDNSForExcluded` (Task 3), `DestinationRoutingFilePayload.filterMode` (Task 1).
- Produces: the extension receives `filterMode` inside `providerConfiguration` and the App Group file; `tunnelDNSHost` is `nil` when the profile is exclude-mode with local DNS on.

- [ ] **Step 1: Extend `makeTransparentProxyRuntimeConfig`**

Add parameter `filterMode: DestinationFilterMode = .include` and pass `filterMode: filterMode` into the `DestinationRoutingFilePayload(...)` it constructs.

- [ ] **Step 2: Extend `persistDestinationRoutingFromHost` logging**

The `filterMode` parameter itself was added in Task 3 Step 4; here just include `mode=\(filterMode.rawValue)` in its traceLog line.

- [ ] **Step 3: Thread mode through the connect path**

In `connect`, next to `var destinationEnforce = false` (~line 358), add:

```swift
var destinationFilterMode: DestinationFilterMode = .include
```

The split-tunnel AllowedIPs branch (`if !profileOkForAccounting && profile.transport == .wireguard`, ~line 379) stays `.include` — AllowedIPs are inherently a whitelist; note this with a comment:

```swift
// Split-tunnel AllowedIPs are inherently include-semantics; user filter mode does not apply.
```

In the `else` branch (~line 384), alongside `destinationEnforce = settings.enforceDestinationFiltering`:

```swift
destinationFilterMode = settings.destinationFilterMode
```

and pass `filterMode: destinationFilterMode` to BOTH the `persistDestinationRoutingFromHost(...)` call in that branch and the `makeTransparentProxyRuntimeConfig(...)` call (~line 393).

- [ ] **Step 4: DNS toggle via tunnelDNSHost**

Replace the `tunnelDNSHost:` argument expression (~line 407) with:

```swift
// SSH mode resolves remotely (SNI); exclude-mode profiles with "resolve DNS locally"
// suppress the redirect so routed apps' DNS exits via the local-bypass direct path.
tunnelDNSHost: (profile.transport == .ssh
        || (destinationFilterMode == .exclude && settings.localDNSForExcluded))
    ? nil
    : (extensionProfile.interface.dnsServers.first(where: { $0.contains(".") }) ?? "1.1.1.1")
```

Also append `mode=\(destinationFilterMode.rawValue)` to the `"transparent proxy runtime config:"` traceLog line (~line 412).

- [ ] **Step 5: Build check**

Run the build check command (after user OK). Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Services/VPNManager.swift
git commit -m "feat(app): carry filter mode to proxy config; suppress DNS redirect for local-DNS exclude profiles"
```

---

### Task 5: Provider config state + exclude-mode intercept rules

**Files:**
- Modify: `TransparentProxyExtension/TransparentProxyProvider.swift` (fields ~line 88, `stopProxy` ~line 227, `refreshDestinationConfig` ~line 817, `applyDestinationPayload` ~line 873, `buildIncludedNetworkRules` ~lines 693-746)

**Interfaces:**
- Consumes: `DestinationFilterMode`, `config.destinationRouting.filterMode` (Task 1).
- Produces: `private var destinationFilterMode: DestinationFilterMode` (guarded by `destinationLock`, session-static); `buildIncludedNetworkRules(enforce:cidrs:hasDomainNames:mode:)`. Tasks 6-7 read the field.

- [ ] **Step 1: Add the field**

Next to `cachedPreparedRanges` (~line 88):

```swift
/// Session-static destination-filter semantics (include = tunnel listed, exclude = tunnel
/// all EXCEPT listed). Populated from `TransparentProxyRuntimeConfig.destinationRouting`
/// in `refreshDestinationConfig` (same session-static, `destinationLock`-guarded pattern
/// as `dropTunneledUDP`); the appMessage live-push never changes it. Defaults `.include`
/// so legacy configs keep the historical whitelist behavior.
private var destinationFilterMode: DestinationFilterMode = .include
```

- [ ] **Step 2: Reset in `stopProxy`**

In the `destinationLock` clear block (~line 227-236), add `destinationFilterMode = .include`.

- [ ] **Step 3: Populate in `refreshDestinationConfig`**

providerConfiguration branch — inside the existing session-static locked block (~line 824-830), add:

```swift
destinationFilterMode = config.destinationRouting.filterMode
```

sharedFile branch — after decoding `payload` (~line 853), before its `applyDestinationPayload` call, add the same generation-checked pattern:

```swift
destinationLock.lock()
if generation == currentSessionGeneration() {
    destinationFilterMode = payload.filterMode
}
destinationLock.unlock()
```

- [ ] **Step 4: Thread mode through rule building**

`buildIncludedNetworkRules()` (no-arg, ~line 693): also read `let mode = destinationFilterMode` under the lock and pass it through. Change the snapshot overload signature to:

```swift
private func buildIncludedNetworkRules(enforce: Bool, cidrs: [String], hasDomainNames: Bool, mode: DestinationFilterMode) -> [NENetworkRule] {
```

and insert, after the `catchAll` definition and BEFORE the SNI-mode branch:

```swift
// Exclude mode: every routed-app flow must reach handleNewFlow so the per-flow (TCP)
// and per-datagram (UDP) logic can send LISTED destinations direct and tunnel the rest.
// NENetworkRule cannot express negation, so interception is catch-all for both protocols.
if enforce, mode == .exclude {
    Self.log.notice("buildIncludedNetworkRules: exclude mode — catch-all TCP+UDP")
    return catchAll
}
```

In `applyDestinationPayload` (~line 873): while still under `destinationLock` (after the generation guard), read `let mode = destinationFilterMode`, and pass `mode: mode` at its `buildIncludedNetworkRules(enforce:cidrs:hasDomainNames:)` call site (~line 919). Also extend the `[FIRSTRUN-DIAG]` line in `startProxy` (~line 191) with `mode=\(...)` read in the existing locked block at ~line 188.

- [ ] **Step 5: Build check + commit**

Run the build check command (after user OK). Expected: `BUILD SUCCEEDED`.

```bash
git add TransparentProxyExtension/TransparentProxyProvider.swift
git commit -m "feat(proxy): session-static filter mode; catch-all intercept rules in exclude mode"
```

---

### Task 6: Provider TCP flow decision (decline + inverted SNI decider)

**Files:**
- Modify: `TransparentProxyExtension/TransparentProxyProvider.swift` (`handleNewFlow` destination block ~lines 340-465)

**Interfaces:**
- Consumes: `destinationFilterMode` (Task 5), `DestinationRouteDecision.decide` (Task 1).
- Produces: TCP flows to excluded IPs are declined (`decision=exclude-direct` log line); the SNI decider routes both modes through `DestinationRouteDecision`.

- [ ] **Step 1: Snapshot the mode**

In the `destinationLock` block (~lines 349-356), add `let filterMode = destinationFilterMode`.

- [ ] **Step 2: Disable the private-range tunnel override in exclude mode**

At the bypass-local check (~line 409), replace `tunnelRanges: preparedRanges` with:

```swift
// Exclude mode: a listed CIDR means DIRECT, so the "user configured this private range
// for tunneling" override can never apply — pass no tunnel ranges.
tunnelRanges: filterMode == .exclude ? [] : preparedRanges
```

- [ ] **Step 3: Decline excluded TCP destinations at flow-open**

Immediately after the bypass-local `if` block (after ~line 412), before the `decision=intercept` log:

```swift
// Exclude mode: a destination the user listed goes DIRECT. An IP match cannot be
// overridden by SNI (an SNI match would also mean direct), so the flow is declined at
// open and the OS routes it out en0 natively — no relay, no peek. UDP flows carry no
// remote at open; they are excluded per-datagram in UDPFlowRelay instead.
if filterMode == .exclude,
   let literal = literalRemoteHostname(from: flow),
   IPCIDRMatcher.literalMatches(literal, ranges: preparedRanges) {
    Self.log.notice("[APPSPLIT_FLOW] decision=exclude-direct signingID=\(signingID) remote=\(literal)")
    return false
}
```

- [ ] **Step 4: Route the SNI decider through the shared helper**

Replace the body of the `sniDecider` closure (~lines 425-450) so both modes share `DestinationRouteDecision` (log format and reason strings preserved):

```swift
let sniDecider: ((Data) -> Bool)? = sniMode ? { firstChunk in
    let sni = TLSClientHelloSNI.serverName(from: firstChunk)
    let ipMatch = remoteLiteral.map { IPCIDRMatcher.literalMatches($0, ranges: preparedRanges) } ?? false
    let sniMatch = sni.map { Self.sniMatches($0, names: domainNames) }
    let tunnel = DestinationRouteDecision.decide(mode: filterMode, ipMatch: ipMatch, sniMatch: sniMatch) == .tunnel
    let reason: String
    switch (sniMatch, ipMatch) {
    case (.some(true), _): reason = "sni"
    case (.some(false), true): reason = "ip"
    case (nil, true): reason = "ip-nosni"
    case (.some(false), false): reason = "unmatched"
    case (nil, false): reason = "no-sni"
    }
    // Summary at .notice carries decision + reason but NO hostname (privacy + volume);
    // the full detail with the SNI hostname is logged at .debug only.
    let decision = tunnel ? "tunnel" : "direct"
    Self.log.notice("[APPSPLIT_SNI] decision=\(decision) reason=\(reason) signingID=\(signingID)")
    Self.log.debug("[APPSPLIT_SNI] detail decision=\(decision) reason=\(reason) host=\(sni ?? "nil") remote=\(remoteLiteral ?? "nil") signingID=\(signingID)")
    return tunnel
} : nil
```

The `forceRemoteDNSPeek` fallback `{ _ in true }` (~line 464) is already "tunnel" — correct for both modes; leave it.

- [ ] **Step 5: Build check + commit**

Run the build check command (after user OK). Expected: `BUILD SUCCEEDED`. Behavior sanity: in include mode `decide(.include, ipMatch:, sniMatch:)` reproduces the old branch table exactly (sni→tunnel, ip→tunnel, ip-nosni→tunnel, unmatched/no-sni→direct).

```bash
git add TransparentProxyExtension/TransparentProxyProvider.swift
git commit -m "feat(proxy): exclude-mode TCP decline + mode-aware SNI decider via shared decision helper"
```

---

### Task 7: UDP per-datagram exclusion

**Files:**
- Modify: `TransparentProxyExtension/UDPFlowRelay.swift` (init ~line 82, `send(datagram:to:)` ~lines 149-193)
- Modify: `TransparentProxyExtension/TransparentProxyProvider.swift` (UDP relay construction ~line 500)

**Interfaces:**
- Consumes: `DestinationFilterMode` (Task 1), provider's `filterMode` snapshot (Task 6 Step 1).
- Produces: `UDPFlowRelay.init(..., filterMode: DestinationFilterMode = .include, ...)`.

- [ ] **Step 1: Add the init parameter**

In `UDPFlowRelay`, after the `tunnelInterfaceName` property:

```swift
/// Session-static destination-filter semantics. In `.exclude` mode `tunnelRanges()` holds
/// the DIRECT set: a matching datagram exits via `sendViaDirect`, everything else tunnels,
/// and the private-range tunnel override in `shouldBypassLocal` never applies.
private let filterMode: DestinationFilterMode
```

Add `filterMode: DestinationFilterMode = .include,` to `init` (between `dropTunneledUDP` and `tunnelDNSHost`) and assign it. Also add the memoization state next to the other `queue`-confined dictionaries (`nwConnections` etc.):

```swift
// Exclude-match memoization: in exclude mode the linear CIDR scan would otherwise run
// per datagram against a country-size list (~5-8k ranges) for ALL routed UDP (QUIC
// included) — unlike include mode, where interception is CIDR-narrowed upstream and the
// autoclosure keeps the scan off the hot path. Keyed by destination host; the exclude
// set can only GROW mid-session (appMessage pushes resolved excluded-domain IPs), so
// invalidate on size change. A stale entry errs toward tunneling — the safe direction.
// All access on `queue` (same discipline as the connection dictionaries).
private var excludeVerdictCache: [String: Bool] = [:]
private var excludeCacheRangeCount = -1
```

- [ ] **Step 2: Invert the per-datagram decision**

In `send(datagram:to:)`, replace the `useTunnel` computation (~lines 161-162) with:

```swift
// Exclude mode: a destination in the user's ranges goes DIRECT (tunnelRanges holds the
// exclude set); and a listed private CIDR can never mean "tunnel", so the bypass check
// gets no override ranges. Include mode is byte-for-byte the previous behavior.
let excluded = filterMode == .exclude && isExcluded(legacyEndpoint.hostname)
var useTunnel = routeThroughTunnel
    && !excluded
    && !IPCIDRMatcher.shouldBypassLocal(
        legacyEndpoint.hostname,
        tunnelRanges: filterMode == .exclude ? [] : tunnelRanges()
    )
```

and add the cached-scan helper (runs on `queue`, like `send`):

```swift
/// Memoized exclude-set membership for `host` (see `excludeVerdictCache` doc).
private func isExcluded(_ host: String) -> Bool {
    let ranges = tunnelRanges()
    if ranges.count != excludeCacheRangeCount {
        excludeVerdictCache.removeAll()
        excludeCacheRangeCount = ranges.count
    }
    if let cached = excludeVerdictCache[host] { return cached }
    let verdict = IPCIDRMatcher.literalMatches(host, ranges: ranges)
    excludeVerdictCache[host] = verdict
    return verdict
}
```

In the DNS-redirect condition (~line 169), add `!excluded`:

```swift
if routeThroughTunnel, !dropTunneledUDP, !useTunnel, !excluded,
   legacyEndpoint.port == "53", let redirect = tunnelDNSHost {
```

(An excluded resolver was explicitly listed by the user as direct — the anti-hijack redirect is for local/private resolvers only.)

- [ ] **Step 3: Pass the mode from the provider**

In `TransparentProxyProvider.handleNewFlow`'s `UDPFlowRelay(...)` construction (~line 500), add `filterMode: filterMode,` after `dropTunneledUDP: dropUDP,` (uses the Task 6 Step 1 snapshot).

- [ ] **Step 4: Build check + commit**

Run the build check command (after user OK). Expected: `BUILD SUCCEEDED`.

```bash
git add TransparentProxyExtension/UDPFlowRelay.swift TransparentProxyExtension/TransparentProxyProvider.swift
git commit -m "feat(proxy): exclude-mode per-datagram UDP direct path (redirect untouched for local resolvers)"
```

---

### Task 8: RoutingView UI

**Files:**
- Modify: `TunnelBahn/Views/RoutingView.swift` (`restrictProxySection()` ~lines 155-207, orange caption box ~lines 95-110, tooltip statics)

**Interfaces:**
- Consumes: `AppSettings.destinationFilterMode/.localDNSForExcluded` (Task 3).
- Produces: three-way radio group + exclude-mode DNS toggle.

- [ ] **Step 1: Add the third radio**

In `restrictProxySection()`, the `HStack` currently holds two `RadioButton`s. Adjust so the three options read: "Tunnel all destinations" (`enforce == false`), "Tunnel selected destinations" (`enforce == true && mode == .include`), "Tunnel all except selected" (`enforce == true && mode == .exclude`). Concretely:

- Radio 2 `isOn`: `appState.settings.enforceDestinationFiltering && appState.settings.destinationFilterMode == .include`; action: `destinationFilteringBinding.wrappedValue = true; appState.settings.destinationFilterMode = .include`
- New radio 3, cloned from radio 2's `VStack` pattern (same `disabled: destinationRoutingEditingLocked || !hasAnyDestinations` gating):

```swift
HStack(spacing: 6) {
    RadioButton(
        isOn: appState.settings.enforceDestinationFiltering
            && appState.settings.destinationFilterMode == .exclude,
        label: "Tunnel all except selected",
        disabled: destinationRoutingEditingLocked || !hasAnyDestinations
    ) {
        destinationFilteringBinding.wrappedValue = true
        appState.settings.destinationFilterMode = .exclude
    }
    Image(systemName: "questionmark.circle")
        .foregroundStyle(.secondary)
        .instantTooltip(Self.excludeDestinationsTooltip)
}
```

Add the tooltip static next to the existing ones:

```swift
static let excludeDestinationsTooltip =
    "Everything routed through this profile is tunneled EXCEPT destinations matching the lists below — e.g. import your country's IP ranges so domestic traffic stays direct and fast."
```

The empty-list safeguard (radio disabled when `!hasAnyDestinations`, `onAppear`/`onChange` forcing `enforceDestinationFiltering = false`) applies to exclude mode too — an empty exclude list (enforce off, catch-all intercept, tunnel everything) is behaviorally identical to what enforce-off already does, so nothing is lost.

**Do not loosen the `destinationRoutingEditingLocked` gating** (`appState.isViewingConnectedProfile`): the provider treats `filterMode` as connect-time static (Task 5), so a mode flip only takes effect on reconnect — this lock is exactly what makes that safe UX-wise (no mid-session radio change that silently does nothing until reconnect). The new radio and DNS toggle must both carry it.

- [ ] **Step 2: DNS toggle (exclude mode only)**

Below the radio group inside the same `GroupBox` `VStack` (after the "TCP only..." footnote), add:

```swift
if appState.settings.enforceDestinationFiltering,
   appState.settings.destinationFilterMode == .exclude {
    Toggle("Resolve DNS locally", isOn: $appState.settings.localDNSForExcluded)
        .toggleStyle(.checkbox)
        .disabled(destinationRoutingEditingLocked)
    Text("Local DNS steers excluded (domestic) sites to nearby CDN edges, but the local resolver's filtering then applies to tunneled sites. Off = DNS goes through the tunnel resolver.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
```

- [ ] **Step 3: Adapt the caption box**

The orange info box (~line 100) says `"IPs not matching any list here will **bypass the tunnel**."` Make it mode-aware:

```swift
Text(appState.settings.destinationFilterMode == .exclude
    ? "IPs matching a list here will **bypass the tunnel**; everything else is tunneled."
    : "IPs not matching any list here will **bypass the tunnel**.")
```

(keep the existing modifiers).

- [ ] **Step 4: Build check + commit**

Run the build check command (after user OK). Expected: `BUILD SUCCEEDED`.

```bash
git add TunnelBahn/Views/RoutingView.swift
git commit -m "feat(ui): exclude-mode radio + local-DNS toggle in destination routing view"
```

---

### Task 9: CHANGELOG + manual E2E checklist

**Files:**
- Modify: `CHANGELOG.md` (new Unreleased entry, matching the file's existing format)
- Create: `docs/superpowers/plans/2026-07-31-exclude-mode-e2e-checklist.md`

- [ ] **Step 1: CHANGELOG entry**

Add under the unreleased/next section (create one if absent, matching existing style):

```markdown
- Destination routing: new "Tunnel all except selected" (exclude) mode — tunnel everything
  except the listed CIDRs/domains (e.g. keep domestic IPs direct). Per-profile
  "Resolve DNS locally" toggle for exclude-mode profiles.
```

- [ ] **Step 2: Write the E2E checklist** (user-run; the agent must NOT start tunnels or builds unprompted)

```markdown
# Exclude-Mode Routing — Manual E2E Checklist

Profile: app-tunnel, WireGuard transport, one routed test app (e.g. a browser).
Setup: import a small bulk CIDR group containing a known-direct test range
(e.g. 5.22.0.0/16 or any reachable host you control), select
"Tunnel all except selected".

1. Connect. Log check (Console.app, subsystem com.tunnelbahn.mac.transparentproxy):
   `buildIncludedNetworkRules: exclude mode — catch-all TCP+UDP` and
   `[FIRSTRUN-DIAG] ... mode=exclude`.
2. From the routed app, hit a NON-listed site (e.g. https://ifconfig.me):
   shown IP must be the WG server's (tunneled).
3. Hit an IP inside the excluded range: log shows
   `decision=exclude-direct remote=<ip>`, and traffic egresses en0 (direct).
4. Add a domain rule (e.g. digikala.com), reconnect, visit it from the routed app:
   `[APPSPLIT_SNI] decision=direct reason=sni`.
5. DNS with "Resolve DNS locally" OFF: `nslookup example.com` from the routed app —
   no leak to the local resolver (query rides the tunnel; check WG server or
   tcpdump port 53 on en0 shows nothing from the app). Scope note: the redirect
   applies to queries aimed at LOCAL/private resolvers (the system default). An app
   hardcoding a public non-excluded resolver (e.g. 8.8.8.8) tunnels to it; one
   hardcoding an EXCLUDED resolver goes direct BY DESIGN (the user listed it) —
   that is correct behavior, not a leak.
6. Toggle "Resolve DNS locally" ON, reconnect: the same lookup now reaches the
   local resolver directly.
7. Regression (include mode): switch the profile back to "Tunnel selected
   destinations", reconnect, verify listed-IP-tunnels / unlisted-IP-direct
   still behaves as before.
8. Non-routed apps: verify an app outside the profile is entirely unaffected
   in both modes.
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md docs/superpowers/plans/2026-07-31-exclude-mode-e2e-checklist.md
git commit -m "docs: changelog + manual E2E checklist for exclude-mode routing"
```

# Full-Tunnel Exclude Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "Tunnel all except selected" (exclude mode) work in Full Tunnel routing mode, symmetric with App-Tunnel mode.

**Architecture:** The existing full-tunnel destination-filter shape (`isFullTunnelDestFilterShape`) is widened to accept `.exclude`. The transparent-proxy + XPC-relay stack runs unchanged with `filterMode == .exclude` (the proxy already implements exclude verdicts). Only the kernel route shape inverts: include narrows utun `includedRoutes` to the filter CIDRs; exclude keeps the default route and installs the (sanitized) filter CIDRs as `excludedRoutes`. A new pure helper `TunnelRouteShape` in `Shared/` computes both shapes and is unit-tested; a new optional `appTunnelExcludedRoutes` field in `TunnelRuntimeState` carries the exclude list to the packet-tunnel extension.

**Tech Stack:** Swift 5.10, macOS 14+, NetworkExtension (NEPacketTunnelNetworkSettings), XcodeGen, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-01-full-tunnel-exclude-mode-design.md`

## Global Constraints

- **Ask the user before the FIRST xcodebuild invocation of the session** (their standing instruction). Subsequent xcodebuilds need no ask.
- Unit test command: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests`. One known environmental failure to IGNORE: `WGTCPWrapperRelayTests.testDatagramRoundTripsThroughRelay`.
- Build command: `xcodebuild build -scheme TunnelBahn -destination 'platform=macOS'`.
- After editing `project.yml`, run `xcodegen generate` before any xcodebuild.
- No legacy/compat shims, no schemaVersion fields (app is undistributed). Exception: `TunnelRuntimeState` decoding in the extension stays tolerant — the new field MUST be optional so old payloads decode.
- UI strings: never use em dashes; tooltips are one or two short sentences.
- DNS in the exclude shape mirrors the include shape: `NEDNSSettings` is NOT applied; the proxy's port-53 redirect handles DNS.
- Kernel `excludedRoutes` sanitization is silent (traceLog only, no connect failure).
- Domain names stay App-Tunnel-only (`destinationDomainNames` gating in AppState is untouched).
- Do not modify: `Shared/DestinationRouting.swift` decision logic, TransparentProxyExtension, AppState connect call sites, SSH guard behavior.

---

### Task 1: `TunnelRouteShape` pure helper (Shared) + unit tests

**Files:**
- Create: `Shared/TunnelRouteShape.swift`
- Modify: `project.yml` (add the new file to `TunnelBahnUnitTests.sources`, after the `Shared/DestinationRouting.swift` line ~138)
- Test: `Tests/Unit/TunnelRouteShapeTests.swift` (new; `Tests/Unit` is already a wholesale source path of the test target)

**Interfaces:**
- Consumes: `IPCIDRMatcher.prepare(_:)`, `IPCIDRMatcher.literalMatches(_:ranges:)`, `DestinationFilterMode` (all public in `Shared/DestinationRouting.swift`).
- Produces (Task 3 relies on these exact names):
  - `TunnelRouteShape.fullTunnelOverride(filterMode: DestinationFilterMode, destinationCidrs: [String], interfaceAddresses: [String], dnsServers: [String]) -> TunnelRouteShape.RouteOverride`
  - `RouteOverride { includedRoutes: [String]?, excludedRoutes: [String]?, droppedExcludedRoutes: [String] }` (Equatable)

- [ ] **Step 1: Write the failing tests**

Create `Tests/Unit/TunnelRouteShapeTests.swift`:

```swift
import XCTest

final class TunnelRouteShapeTests: XCTestCase {
    // MARK: - Include shape (behavior moved verbatim from VPNManager's inline route building)

    func testIncludeModeNarrowsToCidrsPlusDNSHostRoutes() {
        let override = TunnelRouteShape.fullTunnelOverride(
            filterMode: .include,
            destinationCidrs: ["1.2.3.0/24", "2606:4700::/32"],
            interfaceAddresses: ["10.2.0.2/32"],
            dnsServers: ["10.2.0.1", "fd00::1"]
        )
        XCTAssertEqual(
            override.includedRoutes,
            ["1.2.3.0/24", "2606:4700::/32", "10.2.0.1/32", "fd00::1/128"]
        )
        XCTAssertNil(override.excludedRoutes)
        XCTAssertTrue(override.droppedExcludedRoutes.isEmpty)
    }

    // MARK: - Exclude shape

    func testExcludeModeKeepsNonConflictingCidrs() {
        let override = TunnelRouteShape.fullTunnelOverride(
            filterMode: .exclude,
            destinationCidrs: ["2.176.0.0/12", "5.22.0.0/17"],
            interfaceAddresses: ["10.2.0.2/32"],
            dnsServers: ["10.2.0.1"]
        )
        XCTAssertNil(override.includedRoutes)
        XCTAssertEqual(override.excludedRoutes, ["2.176.0.0/12", "5.22.0.0/17"])
        XCTAssertTrue(override.droppedExcludedRoutes.isEmpty)
    }

    func testExcludeModeDropsCidrContainingDNSServer() {
        // 10.0.0.0/8 contains the tunnel DNS server 10.2.0.1: installing it as a kernel
        // excludedRoute would black-hole DNS for utun-scoped traffic.
        let override = TunnelRouteShape.fullTunnelOverride(
            filterMode: .exclude,
            destinationCidrs: ["10.0.0.0/8", "2.176.0.0/12"],
            interfaceAddresses: ["10.2.0.2/32"],
            dnsServers: ["10.2.0.1"]
        )
        XCTAssertEqual(override.excludedRoutes, ["2.176.0.0/12"])
        XCTAssertEqual(override.droppedExcludedRoutes, ["10.0.0.0/8"])
    }

    func testExcludeModeDropsCidrContainingInterfaceAddress() {
        // DNS is public here; only the interface address 10.2.0.2 falls inside 10.2.0.0/24.
        let override = TunnelRouteShape.fullTunnelOverride(
            filterMode: .exclude,
            destinationCidrs: ["10.2.0.0/24"],
            interfaceAddresses: ["10.2.0.2/32"],
            dnsServers: ["1.1.1.1"]
        )
        XCTAssertEqual(override.excludedRoutes, [])
        XCTAssertEqual(override.droppedExcludedRoutes, ["10.2.0.0/24"])
    }

    func testExcludeModeDropsV6CidrContainingDNSServer() {
        let override = TunnelRouteShape.fullTunnelOverride(
            filterMode: .exclude,
            destinationCidrs: ["fd00::/16"],
            interfaceAddresses: ["fd00::2/128"],
            dnsServers: ["fd00::1"]
        )
        XCTAssertEqual(override.excludedRoutes, [])
        XCTAssertEqual(override.droppedExcludedRoutes, ["fd00::/16"])
    }

    func testExcludeModeAllConflictingYieldsEmptyKeptList() {
        let override = TunnelRouteShape.fullTunnelOverride(
            filterMode: .exclude,
            destinationCidrs: ["10.0.0.0/8"],
            interfaceAddresses: ["10.2.0.2/32"],
            dnsServers: ["10.2.0.1"]
        )
        XCTAssertEqual(override.excludedRoutes, [])
        XCTAssertEqual(override.droppedExcludedRoutes, ["10.0.0.0/8"])
    }

    func testExcludeModeKeepsUnparseableCidr() {
        // IPCIDRMatcher.prepare skips garbage, so it can never match a protected IP;
        // the adapter's route compactMap skips it again. Kept here so behavior matches
        // the include shape (which also passes raw strings through).
        let override = TunnelRouteShape.fullTunnelOverride(
            filterMode: .exclude,
            destinationCidrs: ["not-a-cidr"],
            interfaceAddresses: ["10.2.0.2/32"],
            dnsServers: ["10.2.0.1"]
        )
        XCTAssertEqual(override.excludedRoutes, ["not-a-cidr"])
        XCTAssertTrue(override.droppedExcludedRoutes.isEmpty)
    }
}
```

- [ ] **Step 2: Add the implementation file**

Create `Shared/TunnelRouteShape.swift`:

```swift
import Foundation

/// Kernel route-shape computation for the full-tunnel destination-filter shape
/// (`isFullTunnelDestFilterShape` in VPNManager). Pure and NetworkExtension-free so the
/// unit-test target can exercise it; VPNManager consumes it at connect time and persists
/// the result into `TunnelRuntimeState`.
public enum TunnelRouteShape {
    /// The utun route override for a full-tunnel destination filter. Exactly one of the
    /// two route lists is non-nil, keyed by filter mode.
    public struct RouteOverride: Equatable {
        /// Include mode: filter CIDRs + DNS host routes, installed as narrowed
        /// `includedRoutes`. nil in exclude mode.
        public let includedRoutes: [String]?
        /// Exclude mode: sanitized filter CIDRs, installed as `excludedRoutes` while the
        /// default route stays. nil in include mode.
        public let excludedRoutes: [String]?
        /// Exclude CIDRs dropped by sanitization because they contain a tunnel interface
        /// address or DNS server IP. Installing those as kernel excludedRoutes would
        /// black-hole the WireGuard virtual network or DNS for utun-scoped traffic. The
        /// caller logs these; the transparent proxy still honors the user's direct
        /// verdict for such destinations at flow level.
        public let droppedExcludedRoutes: [String]
    }

    /// - include: utun `includedRoutes` narrow to the filter CIDRs plus /32 (v4) and
    ///   /128 (v6) host routes for the tunnel DNS servers, which live inside the
    ///   WireGuard virtual network and are unreachable if not routed through utun.
    /// - exclude: utun keeps its default route; `excludedRoutes` carry the filter CIDRs
    ///   minus any CIDR containing a protected IP (interface address or DNS server).
    public static func fullTunnelOverride(
        filterMode: DestinationFilterMode,
        destinationCidrs: [String],
        interfaceAddresses: [String],
        dnsServers: [String]
    ) -> RouteOverride {
        switch filterMode {
        case .include:
            let dnsHostRoutes = dnsServers.map { $0.contains(":") ? "\($0)/128" : "\($0)/32" }
            return RouteOverride(
                includedRoutes: destinationCidrs + dnsHostRoutes,
                excludedRoutes: nil,
                droppedExcludedRoutes: []
            )
        case .exclude:
            let protectedIPs = dnsServers + interfaceAddresses.map { addr in
                addr.split(separator: "/").first.map(String.init) ?? addr
            }
            var kept: [String] = []
            var dropped: [String] = []
            for cidr in destinationCidrs {
                let prepared = IPCIDRMatcher.prepare([cidr])
                let conflicts = protectedIPs.contains { IPCIDRMatcher.literalMatches($0, ranges: prepared) }
                if conflicts {
                    dropped.append(cidr)
                } else {
                    kept.append(cidr)
                }
            }
            return RouteOverride(
                includedRoutes: nil,
                excludedRoutes: kept,
                droppedExcludedRoutes: dropped
            )
        }
    }
}
```

- [ ] **Step 3: Register the file with the unit-test target**

In `project.yml`, in the `TunnelBahnUnitTests.sources` list, directly after the line `- path: Shared/DestinationRouting.swift`, add:

```yaml
      - path: Shared/TunnelRouteShape.swift
```

(The app and both extension targets pick the file up automatically via their `- path: Shared` entries.)

Then run: `xcodegen generate`
Expected: "Created project at .../TunnelBahn.xcodeproj"

- [ ] **Step 4: Run the new tests, verify they pass**

REMINDER: if this is the session's first xcodebuild, ask the user first (Global Constraints).

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/TunnelRouteShapeTests`
Expected: all 7 tests PASS. (Steps 1–3 land together because the test file cannot compile without the type; compile failure of a lone Step 1 is the "red" evidence.)

- [ ] **Step 5: Commit**

```bash
git add Shared/TunnelRouteShape.swift Tests/Unit/TunnelRouteShapeTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(routing): TunnelRouteShape pure helper for full-tunnel filter kernel routes"
```

---

### Task 2: Extension plumbing — `appTunnelExcludedRoutes` through runtime state into NE settings

**Files:**
- Modify: `Shared/TunnelRuntimeState.swift:28-38`
- Modify: `NetworkExtension/PacketTunnelProvider.swift:46-48,97-103`
- Modify: `NetworkExtension/BoringTunAdapter.swift:174-179,235-239,877-956`

**Interfaces:**
- Consumes: nothing from Task 1 (the extension receives pre-sanitized strings).
- Produces (Task 3 relies on these exact names):
  - `TunnelRuntimeState.appTunnelExcludedRoutes: [String]?` (new stored property, memberwise init gains the parameter after `appTunnelIncludedRoutes`)
  - `BoringTunAdapter.start(with:secrets:appTunnelIncludedRoutes:appTunnelExcludedRoutes:effectiveEndpointOverride:)` (new parameter, default nil)

- [ ] **Step 1: Add the field to `TunnelRuntimeState`**

In `Shared/TunnelRuntimeState.swift`, after the `appTunnelIncludedRoutes` property (line 34), add:

```swift
    /// When set, the packet tunnel keeps its default route and installs these CIDRs as
    /// utun `excludedRoutes` (full-tunnel exclude filter). Mutually exclusive with
    /// `appTunnelIncludedRoutes` by construction in VPNManager; sanitized host-side so
    /// it never contains the tunnel interface network or DNS server IPs. Optional so a
    /// stale extension decoding an old payload (or an old extension decoding this one)
    /// falls back to plain full-tunnel, which over-tunnels but never leaks.
    let appTunnelExcludedRoutes: [String]?
```

- [ ] **Step 2: Thread it through `PacketTunnelProvider.startWireGuard`**

In `NetworkExtension/PacketTunnelProvider.swift`, extend the route logging (lines 46-48):

```swift
        if let routes = runtime.appTunnelIncludedRoutes, !routes.isEmpty {
            logger.notice("destination app-tunnel included routes count=\(routes.count)")
        }
        if let routes = runtime.appTunnelExcludedRoutes, !routes.isEmpty {
            logger.notice("full-tunnel exclude routes count=\(routes.count)")
        }
```

And in the `adapter?.start(...)` call (lines 98-103), add the argument after `appTunnelIncludedRoutes`:

```swift
            try await adapter?.start(
                with: runtime.profile,
                secrets: runtime.secrets,
                appTunnelIncludedRoutes: runtime.appTunnelIncludedRoutes,
                appTunnelExcludedRoutes: runtime.appTunnelExcludedRoutes,
                effectiveEndpointOverride: effectiveEndpointOverride
            )
```

- [ ] **Step 3: Extend `BoringTunAdapter.start` and `buildNetworkSettings`**

In `NetworkExtension/BoringTunAdapter.swift`:

3a. `start` signature (lines 174-179) gains the parameter:

```swift
    func start(
        with profile: WireGuardProfile,
        secrets: TunnelSecrets? = nil,
        appTunnelIncludedRoutes: [String]? = nil,
        appTunnelExcludedRoutes: [String]? = nil,
        effectiveEndpointOverride: String? = nil
    ) async throws {
```

3b. The `buildNetworkSettings` call (lines 235-239) passes it through:

```swift
        let networkSettings = Self.buildNetworkSettings(
            profile: profile,
            tunnelRemoteHost: endpointString,
            appTunnelIncludedRoutes: appTunnelIncludedRoutes,
            appTunnelExcludedRoutes: appTunnelExcludedRoutes
        )
```

Do NOT touch the outbound-filter block right below (lines 251-267): the exclude shape has `appTunnelIncludedRoutes == nil`, so it takes the existing else branch (default-route AllowedIPs, no packet filter) — per the spec, an excluded destination leaking through utun is suboptimal routing, not a privacy leak, and tunneled traffic rides the smoltcp XPC path anyway.

3c. `buildNetworkSettings` (starting line 877). New signature:

```swift
    private static func buildNetworkSettings(
        profile: WireGuardProfile,
        tunnelRemoteHost: String,
        appTunnelIncludedRoutes: [String]? = nil,
        appTunnelExcludedRoutes: [String]? = nil
    ) -> NEPacketTunnelNetworkSettings {
```

Directly after the existing `let usingDestinationAppTunnel = appTunnelIncludedRoutes?.isEmpty == false` (line 886), add:

```swift
        // Full-tunnel exclude shape: default route stays; the listed CIDRs bypass utun.
        // The host guarantees the two overrides are mutually exclusive; if both ever
        // arrive, include wins (fail toward over-tunneling, never toward a leak).
        var usingDestinationExclude = appTunnelExcludedRoutes?.isEmpty == false
        if usingDestinationAppTunnel && usingDestinationExclude {
            log.error("both included and excluded route overrides present; ignoring excluded")
            usingDestinationExclude = false
        }
        let excludeCIDRs = usingDestinationExclude ? (appTunnelExcludedRoutes ?? []) : []
```

After the `v6AllowedRoutes` computation (line 912), add the excluded-route arrays:

```swift
        // No gatewayAddress on excluded routes: excluded destinations exit via the
        // physical interface, not the tunnel.
        let v4ExcludedRoutes: [NEIPv4Route] = excludeCIDRs.compactMap { cidr in
            guard cidr.contains(".") else { return nil }
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
            return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: ipv4SubnetMask(prefix: prefix))
        }
        let v6ExcludedRoutes: [NEIPv6Route] = excludeCIDRs.compactMap { cidr in
            guard cidr.contains(":") else { return nil }
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
            return NEIPv6Route(destinationAddress: String(parts[0]), networkPrefixLength: NSNumber(value: min(max(prefix, 0), 128)))
        }
```

In the IPv4 block, extend the excludedRoutes assignment (lines 926-928):

```swift
            if usingDestinationAppTunnel {
                ipv4.excludedRoutes = [NEIPv4Route.default()]
            } else if !v4ExcludedRoutes.isEmpty {
                ipv4.excludedRoutes = v4ExcludedRoutes
            }
```

In the IPv6 block, extend likewise (lines 942-944):

```swift
            if usingDestinationAppTunnel {
                ipv6.excludedRoutes = [NEIPv6Route.default()]
            } else if !v6ExcludedRoutes.isEmpty {
                ipv6.excludedRoutes = v6ExcludedRoutes
            }
```

(`v4ExcludedRoutes`/`v6ExcludedRoutes` are non-empty only when `usingDestinationExclude`, so plain profiles are untouched.)

Update the DNS gate (line 948) to skip `NEDNSSettings` in the exclude shape, mirroring the include shape — DNS rides the transparent proxy's port-53 redirect over the XPC relay, and applying tunnel DNS system-wide would both defeat "Resolve DNS locally" and force excluded destinations' lookups through the tunnel resolver:

```swift
        if !profile.interface.dnsServers.isEmpty && hasDefaultRoute
            && !usingDestinationAppTunnel && !usingDestinationExclude {
```

(Keep the existing comment above it; append one line: `// The exclude filter shape also skips dnsSettings: DNS rides the proxy's port-53 redirect, same as the include shape.`)

- [ ] **Step 4: Build**

Run: `xcodebuild build -scheme TunnelBahn -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED. (VPNManager's single `TunnelRuntimeState(...)` init call at line ~1397 will FAIL to compile until Task 3 adds the argument — if building at this point, add the placeholder argument `appTunnelExcludedRoutes: nil` there now; Task 3 replaces it. Note this in the commit if done.)

- [ ] **Step 5: Run unit tests (regression)**

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests`
Expected: PASS except the known `WGTCPWrapperRelayTests.testDatagramRoundTripsThroughRelay`.

- [ ] **Step 6: Commit**

```bash
git add Shared/TunnelRuntimeState.swift NetworkExtension/PacketTunnelProvider.swift NetworkExtension/BoringTunAdapter.swift TunnelBahn/Services/VPNManager.swift
git commit -m "feat(ne): carry appTunnelExcludedRoutes to the packet tunnel; exclude-shape NE settings"
```

---

### Task 3: VPNManager connect path — widen the shape flag, build both route shapes

**Files:**
- Modify: `TunnelBahn/Services/VPNManager.swift:308-323` (shape flag + comment)
- Modify: `TunnelBahn/Services/VPNManager.swift:520-548` (route building + configureManager call)
- Modify: `TunnelBahn/Services/VPNManager.swift:1370-1404` (`makeRuntimeStateData`)

**Interfaces:**
- Consumes: `TunnelRouteShape.fullTunnelOverride(filterMode:destinationCidrs:interfaceAddresses:dnsServers:) -> RouteOverride` (Task 1); `TunnelRuntimeState.appTunnelExcludedRoutes` (Task 2).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Widen `isFullTunnelDestFilterShape`**

Replace lines 308-323 (the doc comment, the stale exclude comment, and the flag) with:

```swift
            /// Full-tunnel mode with destination filtering: activate the transparent proxy
            /// to filter all apps' flows by destination verdicts (include OR exclude; the
            /// proxy's DestinationRouteDecision handles both). Kernel route shapes are
            /// built below via TunnelRouteShape.fullTunnelOverride: include narrows utun
            /// includedRoutes to the filter CIDRs; exclude keeps the default route and
            /// installs the sanitized filter CIDRs as excludedRoutes. Enforce-off residual
            /// modes never reach here — the flag requires enforceDestinationFiltering, so
            /// a stale `.exclude` with enforce off falls through to plain full-tunnel
            /// (tunnel everything), matching the UI.
            let isFullTunnelDestFilterShape = AppConstants.isPerAppSplitTunnelEnabled
                && !appTunnelModeSelected
                && settings.enforceDestinationFiltering
                && !destinationCidrStrings.isEmpty
                && profileOkForAccounting
```

(The only semantic change is dropping `&& settings.destinationFilterMode == .include`.)

- [ ] **Step 2: Replace the inline route building**

Replace lines 520-528 (the comment block and `let tunnelIncludedRoutes` ternary) with:

```swift
            // Full-tunnel filter kernel route shapes (TunnelRouteShape.fullTunnelOverride):
            // include narrows includedRoutes to the filter CIDRs + DNS host routes; exclude
            // keeps the default route and excludes the sanitized filter CIDRs. Out-of-tunnel
            // traffic falls back to en0 without needing any cleanup on disconnect or crash —
            // the next connect rewrites the file with whatever shape is active then.
            var tunnelIncludedRoutes: [String]? = nil
            var tunnelExcludedRoutes: [String]? = nil
            if isFullTunnelDestFilterShape {
                let routeOverride = TunnelRouteShape.fullTunnelOverride(
                    filterMode: destinationFilterMode,
                    destinationCidrs: destinationCidrStrings,
                    interfaceAddresses: extensionProfile.interface.addresses,
                    dnsServers: extensionProfile.interface.dnsServers
                )
                tunnelIncludedRoutes = routeOverride.includedRoutes
                tunnelExcludedRoutes = routeOverride.excludedRoutes
                if !routeOverride.droppedExcludedRoutes.isEmpty {
                    traceLog(
                        "exclude kernel routes: dropped \(routeOverride.droppedExcludedRoutes.count) CIDR(s) overlapping tunnel interface/DNS: \(routeOverride.droppedExcludedRoutes.joined(separator: ","))"
                    )
                }
            }
```

Note: `destinationFilterMode` (declared line ~366, assigned line ~404) is correct here — the shape flag requires enforce on, and the enforce-on branch assigns the stored mode. The AllowedIPs split-tunnel branch requires `!profileOkForAccounting` and is mutually exclusive with this shape.

- [ ] **Step 3: Pass the exclude list into both runtime-state payloads and fix `narrowedRoutes`**

In the two `makeRuntimeStateData` calls (lines ~529-539), add the argument after `appTunnelIncludedRoutes: tunnelIncludedRoutes`:

```swift
                appTunnelExcludedRoutes: tunnelExcludedRoutes
```

In the `configureManager` call (line ~548), replace `narrowedRoutes: isFullTunnelDestFilterShape` with:

```swift
                narrowedRoutes: tunnelIncludedRoutes != nil
```

(The exclude shape's includedRoutes ARE the default route — nothing is narrowed, so it must take the same `includeAllNetworks` path as plain full-tunnel accounting.)

- [ ] **Step 4: Extend `makeRuntimeStateData`**

Signature (lines 1370-1374) gains the parameter:

```swift
    private func makeRuntimeStateData(
        profile: WireGuardProfile,
        includeSecrets: Bool,
        appTunnelIncludedRoutes: [String]? = nil,
        appTunnelExcludedRoutes: [String]? = nil
    ) throws -> Data {
```

Payload construction (lines 1397-1402) passes it through (replacing any Task 2 placeholder):

```swift
        let payload = TunnelRuntimeState(
            profile: profile,
            secrets: secrets,
            appTunnelIncludedRoutes: appTunnelIncludedRoutes,
            appTunnelExcludedRoutes: appTunnelExcludedRoutes,
            ssh: ssh
        )
```

- [ ] **Step 5: Build and run unit tests**

Run: `xcodebuild build -scheme TunnelBahn -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests`
Expected: PASS except the known relay test.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Services/VPNManager.swift
git commit -m "feat(routing): full-tunnel exclude shape in connect path via TunnelRouteShape"
```

---

### Task 4: UI ungate + tooltip + CHANGELOG

**Files:**
- Modify: `TunnelBahn/Views/RoutingView.swift:78-79,142-158,176-185,234-250`
- Modify: `CHANGELOG.md` (Unreleased > Added)

**Interfaces:**
- Consumes: nothing; pure UI/doc changes.
- Produces: nothing.

- [ ] **Step 1: Update the tooltip**

Replace lines 78-79:

```swift
    private static let excludeDestinationsTooltip =
        "Tunnel everything except the destinations below, e.g. your country's IP ranges."
```

(Drops "App-Tunnel mode only." One sentence, no em dashes.)

- [ ] **Step 2: Ungate the exclude radio**

In `restrictProxySection()` (lines 234-250), the exclude radio becomes symmetric with the include radio — remove the full-tunnel isOn clause, the disabled clause, and the stale comment:

```swift
                    HStack(spacing: 6) {
                        RadioButton(
                            isOn: (appState.settings.enforceDestinationFiltering
                                && displayedMode == .exclude)
                                || previewedEmptyMode == .exclude,
                            label: "Tunnel all except selected",
                            disabled: destinationRoutingEditingLocked
                        ) { selectMode(.exclude) }
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.excludeDestinationsTooltip)
                    }
```

- [ ] **Step 3: Delete the normalization**

- Delete the whole `normalizeExcludeModeForRoutingMode()` function and its doc comment (lines 176-185).
- In `.onAppear` (lines 142-147), delete the `normalizeExcludeModeForRoutingMode()` line (keep the `hasAnyDestinations` enforce reset).
- Delete the entire `.onChange(of: appState.settings.routingMode) { _, _ in normalizeExcludeModeForRoutingMode() }` modifier (lines 156-158) — the normalize call was its only body.

- [ ] **Step 4: CHANGELOG entry**

In `CHANGELOG.md` under `## [Unreleased]` / `### Added`, add:

```markdown
- **Full-tunnel exclude mode.** "Tunnel all except selected" now works in Full Tunnel
  routing mode: the tunnel keeps its default route while the enabled exclude-list CIDRs
  bypass it (kernel `excludedRoutes` plus the same transparent-proxy verdicts App-Tunnel
  exclude mode uses, preserving per-app/per-destination stats and live IP push). Exclude
  CIDRs that would black-hole the tunnel's own DNS or virtual network are dropped from
  kernel routes automatically.
```

- [ ] **Step 5: Build and run unit tests**

Run: `xcodebuild build -scheme TunnelBahn -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests`
Expected: PASS except the known relay test.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Views/RoutingView.swift CHANGELOG.md
git commit -m "feat(ui): enable exclude mode radio in full-tunnel routing; changelog"
```

---

### Task 5: Final verification sweep

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite**

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests`
Expected: PASS except `WGTCPWrapperRelayTests.testDatagramRoundTripsThroughRelay` (known environmental).

- [ ] **Step 2: Grep invariants**

Run and eyeball each:

```bash
# No residual UI gate:
grep -n "normalizeExcludeModeForRoutingMode\|fullTunnel" TunnelBahn/Views/RoutingView.swift
# Expected: no normalizeExcludeModeForRoutingMode hits; no fullTunnel gating on the exclude radio.

# Shape flag no longer pins include:
grep -n "destinationFilterMode == .include" TunnelBahn/Services/VPNManager.swift
# Expected: no hits inside the isFullTunnelDestFilterShape definition.

# Mutual exclusivity: both payload builders carry both fields:
grep -n "appTunnelExcludedRoutes" TunnelBahn/Services/VPNManager.swift Shared/TunnelRuntimeState.swift NetworkExtension/PacketTunnelProvider.swift NetworkExtension/BoringTunAdapter.swift
```

- [ ] **Step 3: Report**

Summarize for the user: what changed, test results (including the ignored known failure verbatim), and that E2E (tunnel up with a domestic bulk group excluded in full-tunnel mode, verify direct vs tunneled paths and working DNS) remains manual per repo convention.

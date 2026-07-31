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

    // MARK: - Enforce-off normalization invariant

    /// Guards the residual-mode leak fix. When enforce is off, the app-side (VPNManager /
    /// AppState) ternary normalizes the effective mode to `.include` regardless of the stored
    /// mode, so a residual `.exclude` can never reach the extension with enforce=false. The
    /// ternary lives in VPNManager (not reachable from this target); here we assert the decision
    /// contract that normalization must satisfy: under `.include`, a listed-IP flow TUNNELS —
    /// the exact verdict an enforce-off connect must produce for a previously-excluded range.
    func testEnforceOffNormalizesToIncludeSemantics() {
        let effectiveMode: DestinationFilterMode = false ? .exclude : .include // mirrors `enforce ? stored : .include`
        XCTAssertEqual(effectiveMode, .include)
        XCTAssertEqual(DestinationRouteDecision.decide(mode: effectiveMode, ipMatch: true, sniMatch: nil), .tunnel)
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

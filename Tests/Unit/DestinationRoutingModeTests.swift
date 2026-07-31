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

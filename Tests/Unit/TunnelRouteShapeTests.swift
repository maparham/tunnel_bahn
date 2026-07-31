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

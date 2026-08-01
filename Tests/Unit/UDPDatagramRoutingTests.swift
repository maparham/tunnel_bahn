import XCTest

final class UDPDatagramRoutingTests: XCTestCase {
    // MARK: - Anti-hijack DNS redirect vs the exclude list

    /// The regression from review: a port-53 datagram to a resolver INSIDE the exclude set
    /// must still be redirected to the tunnel resolver when the redirect is active. Sending
    /// it direct would hand every lookup (including tunneled sites') to a possibly
    /// censoring resolver in cleartext, with no NEDNSSettings backstop in the exclude shape.
    func testExcludedResolverPort53RedirectsToTunnelDNS() {
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: true,
            excluded: true,
            bypassesLocal: false,
            dropTunneledUDP: false,
            destinationHost: "2.176.0.53",
            destinationPort: "53",
            tunnelDNSHost: "10.2.0.1"
        )
        XCTAssertEqual(verdict, .tunnel(host: "10.2.0.1", port: "53"))
    }

    func testExcludedResolverPort53GoesDirectWhenRedirectDisabled() {
        // resolveDNSLocally suppresses the redirect (tunnelDNSHost nil): DNS exits direct.
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: true,
            excluded: true,
            bypassesLocal: false,
            dropTunneledUDP: false,
            destinationHost: "2.176.0.53",
            destinationPort: "53",
            tunnelDNSHost: nil
        )
        XCTAssertEqual(verdict, .direct)
    }

    func testExcludedNonDNSDatagramGoesDirect() {
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: true,
            excluded: true,
            bypassesLocal: false,
            dropTunneledUDP: false,
            destinationHost: "2.176.0.53",
            destinationPort: "443",
            tunnelDNSHost: "10.2.0.1"
        )
        XCTAssertEqual(verdict, .direct)
    }

    // MARK: - Existing behavior preserved

    func testLocalResolverPort53RedirectsToTunnelDNS() {
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: true,
            excluded: false,
            bypassesLocal: true,
            dropTunneledUDP: false,
            destinationHost: "192.168.1.1",
            destinationPort: "53",
            tunnelDNSHost: "10.2.0.1"
        )
        XCTAssertEqual(verdict, .tunnel(host: "10.2.0.1", port: "53"))
    }

    func testLocalNonDNSDatagramGoesDirect() {
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: true,
            excluded: false,
            bypassesLocal: true,
            dropTunneledUDP: false,
            destinationHost: "192.168.1.10",
            destinationPort: "1900",
            tunnelDNSHost: "10.2.0.1"
        )
        XCTAssertEqual(verdict, .direct)
    }

    func testRoutedRemoteDatagramTunnelsToOriginalDestination() {
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: true,
            excluded: false,
            bypassesLocal: false,
            dropTunneledUDP: false,
            destinationHost: "1.2.3.4",
            destinationPort: "443",
            tunnelDNSHost: "10.2.0.1"
        )
        XCTAssertEqual(verdict, .tunnel(host: "1.2.3.4", port: "443"))
    }

    func testNonRoutedFlowGoesDirect() {
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: false,
            excluded: false,
            bypassesLocal: false,
            dropTunneledUDP: false,
            destinationHost: "1.2.3.4",
            destinationPort: "53",
            tunnelDNSHost: "10.2.0.1"
        )
        XCTAssertEqual(verdict, .direct)
    }

    // MARK: - SSH fail-closed semantics untouched

    func testTunneledDatagramDropsWhenUDPDisabled() {
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: true,
            excluded: false,
            bypassesLocal: false,
            dropTunneledUDP: true,
            destinationHost: "1.2.3.4",
            destinationPort: "443",
            tunnelDNSHost: nil
        )
        XCTAssertEqual(verdict, .drop)
    }

    func testExcludedPort53WithUDPDisabledStaysDirectNotRedirected() {
        // SSH mode never redirects (redirect requires a WG tunnel path); the direct exit
        // for an excluded destination must not be converted into a drop.
        let verdict = UDPDatagramRouting.decide(
            routeThroughTunnel: true,
            excluded: true,
            bypassesLocal: false,
            dropTunneledUDP: true,
            destinationHost: "2.176.0.53",
            destinationPort: "53",
            tunnelDNSHost: "10.2.0.1"
        )
        XCTAssertEqual(verdict, .direct)
    }
}

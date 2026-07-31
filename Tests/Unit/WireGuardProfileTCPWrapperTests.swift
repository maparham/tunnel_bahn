import XCTest

final class WireGuardProfileTCPWrapperTests: XCTestCase {
    private func sampleProfile(wrapper: WireGuardTCPWrapper?) -> WireGuardProfile {
        WireGuardProfile(
            name: "wg-tcp",
            interface: WireGuardInterface(privateKeyRef: "ref", addresses: ["10.9.0.2/32"], dnsServers: ["1.1.1.1"], mtu: nil),
            peers: [WireGuardPeer(publicKey: "cHVia2V5cHVia2V5cHVia2V5cHVia2V5cHVia2V5MDA=", endpoint: "127.0.0.1:51840", allowedIPs: ["0.0.0.0/0"])],
            tcpWrapper: wrapper
        )
    }

    func testCodableRoundTripPreservesWrapper() throws {
        let wrapper = WireGuardTCPWrapper(
            serverHost: "3.139.146.5", serverPort: 443, tls: true, verifyCert: false,
            pathPrefix: "tun74fd08a683078a3e0439", forwardHost: "127.0.0.1", forwardPort: 51840
        )
        let data = try JSONEncoder().encode(sampleProfile(wrapper: wrapper))
        let decoded = try JSONDecoder().decode(WireGuardProfile.self, from: data)
        XCTAssertEqual(decoded.tcpWrapper, wrapper)
    }
}

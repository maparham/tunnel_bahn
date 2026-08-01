import XCTest

/// The wrapper's `enabled` flag lets the user switch the TCP transport off while keeping the
/// server/path/forward settings stored on the profile for later re-enable.
final class TCPWrapperEnabledFlagTests: XCTestCase {
    private let reference = WireGuardTCPWrapper(
        serverHost: "3.139.146.5", serverPort: 443, tls: true, verifyCert: false,
        pathPrefix: "tun74fd08a683078a3e0439", forwardHost: "127.0.0.1", forwardPort: 51840
    )

    func testMemberwiseDefaultIsEnabled() {
        XCTAssertTrue(reference.enabled)
    }

    func testDecodeWithoutEnabledKeyDefaultsToEnabled() throws {
        let map = [
            "server": "3.139.146.5:443",
            "pathprefix": "tun74fd08a683078a3e0439", "forward": "127.0.0.1:51840",
        ]
        XCTAssertEqual(try TCPWrapperConfigCodec.decode(map)?.enabled, true)
    }

    func testDecodeEnabledFalse() throws {
        let map = [
            "server": "3.139.146.5:443", "enabled": "false",
            "pathprefix": "tun74fd08a683078a3e0439", "forward": "127.0.0.1:51840",
        ]
        XCTAssertEqual(try TCPWrapperConfigCodec.decode(map)?.enabled, false)
    }

    func testDisabledWrapperEncodeThenDecodeRoundTrips() throws {
        var disabled = reference
        disabled.enabled = false
        let lines = TCPWrapperConfigCodec.encodeLines(disabled)
        var map: [String: String] = [:]
        for line in lines where line.contains("=") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            map[parts[0].lowercased()] = parts[1]
        }
        XCTAssertEqual(try TCPWrapperConfigCodec.decode(map), disabled)
    }

    func testJSONWithoutEnabledKeyDecodesAsEnabled() throws {
        // Runtime-state JSON written before the flag existed (vpn-state.json,
        // providerConfiguration) has no "enabled" key; it must decode as enabled.
        let old = """
            {"serverHost":"3.139.146.5","serverPort":443,"tls":true,"verifyCert":false,
             "pathPrefix":"tun74fd08a683078a3e0439","forwardHost":"127.0.0.1","forwardPort":51840}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WireGuardTCPWrapper.self, from: old)
        XCTAssertEqual(decoded, reference)
        XCTAssertTrue(decoded.enabled)
    }

    func testDisabledWrapperSurvivesProfileJSONRoundTrip() throws {
        var disabled = reference
        disabled.enabled = false
        let profile = WireGuardProfile(
            name: "t",
            interface: WireGuardInterface(privateKeyRef: "ref", addresses: ["10.9.0.2/32"], dnsServers: [], mtu: nil),
            peers: [WireGuardPeer(publicKey: "pk", endpoint: "127.0.0.1:51840", allowedIPs: ["0.0.0.0/0"])],
            tcpWrapper: disabled
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(WireGuardProfile.self, from: data)
        XCTAssertEqual(decoded.tcpWrapper, disabled)
        XCTAssertEqual(decoded.tcpWrapper?.enabled, false)
    }
}

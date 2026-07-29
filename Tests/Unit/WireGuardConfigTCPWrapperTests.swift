import XCTest

final class WireGuardConfigTCPWrapperTests: XCTestCase {
    // A full wrapped config resembling ~/Downloads/AWS-over-tcp.conf plus the [TCPWrapper] section.
    private let rawConfig = """
    [Interface]
    PrivateKey = aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGwwMDA=
    Address = 10.9.0.2/32
    DNS = 1.1.1.1

    [Peer]
    PublicKey = LuOmbtLMMHwhIBUJaPebD42U0qVTvRR6Zmcs2NYXIy0=
    AllowedIPs = 0.0.0.0/0
    Endpoint = 127.0.0.1:51840
    PersistentKeepalive = 25

    [TCPWrapper]
    Server = 3.139.146.5:443
    TLS = true
    VerifyCert = false
    PathPrefix = tun74fd08a683078a3e0439
    Forward = 127.0.0.1:51840
    """

    func testParseReadsWrapperSection() throws {
        let profile = try WireGuardConfigParser().parse(rawConfig: rawConfig, profileName: "aws-tcp")
        let w = try XCTUnwrap(profile.tcpWrapper)
        XCTAssertEqual(w.serverHost, "3.139.146.5")
        XCTAssertEqual(w.serverPort, 443)
        XCTAssertFalse(w.verifyCert)
        XCTAssertEqual(w.pathPrefix, "tun74fd08a683078a3e0439")
        XCTAssertEqual(w.forwardHost, "127.0.0.1")
        XCTAssertEqual(w.forwardPort, 51840)
    }

    func testRenderThenParseRoundTrips() throws {
        let parsed = try WireGuardConfigParser().parse(rawConfig: rawConfig, profileName: "aws-tcp")
        let rendered = try WireGuardConfigRenderer().renderFullConfigString(profile: parsed)
        XCTAssertTrue(rendered.contains("[TCPWrapper]"))
        let reparsed = try WireGuardConfigParser().parse(rawConfig: rendered, profileName: "aws-tcp")
        XCTAssertEqual(reparsed.tcpWrapper, parsed.tcpWrapper)
    }

    func testPlainConfigHasNilWrapper() throws {
        let plain = rawConfig.components(separatedBy: "[TCPWrapper]").first!
        let profile = try WireGuardConfigParser().parse(rawConfig: plain, profileName: "plain")
        XCTAssertNil(profile.tcpWrapper)
    }
}

import XCTest

final class AndroidProfileQRCodecTests: XCTestCase {

    /// In-memory SecretReading double: returns fixed values keyed by account.
    private struct FakeSecrets: SecretReading {
        var values: [String: String]
        func read(account: String) throws -> String {
            guard let v = values[account] else {
                throw AndroidProfileQRError.missingSecret(account)
            }
            return v
        }
    }

    private func makeSSHProfile(host: String, port: UInt16, user: String) -> WireGuardProfile {
        WireGuardProfile(
            name: "ssh-profile",
            interface: WireGuardInterface(privateKeyRef: "wg-ref", addresses: [], dnsServers: [], mtu: nil),
            peers: [],
            transport: .ssh,
            ssh: SSHProfile(host: host, port: port, username: user, privateKeyRef: "ssh-ref")
        )
    }

    private func makeWGProfile(
        serverHost: String = "1.2.3.4", serverPort: UInt16 = 443, tls: Bool = true,
        pathPrefix: String = "tun", forwardHost: String = "127.0.0.1", forwardPort: UInt16 = 51840,
        wrapper hasWrapper: Bool = true
    ) -> WireGuardProfile {
        let wrapper = hasWrapper ? WireGuardTCPWrapper(
            serverHost: serverHost, serverPort: serverPort, tls: tls, verifyCert: false,
            pathPrefix: pathPrefix, forwardHost: forwardHost, forwardPort: forwardPort
        ) : nil
        return WireGuardProfile(
            name: "wg-profile",
            interface: WireGuardInterface(privateKeyRef: "wg-ref", addresses: ["10.9.0.2/32"], dnsServers: ["1.1.1.1"], mtu: 1280),
            peers: [WireGuardPeer(publicKey: "peerpub", endpoint: "127.0.0.1:51840", allowedIPs: ["0.0.0.0/0"])],
            tcpWrapper: wrapper
        )
    }

    private let fakeKeychain = FakeSecrets(values: ["ssh-ref": "PEMDATA", "wg-ref": "wgpriv"])

    func testSSHEncodeJoinsHostAndPort() throws {
        let profile = makeSSHProfile(host: "1.2.3.4", port: 443, user: "tb")
        let json = try AndroidProfileQRCodec.encode(profile, secrets: fakeKeychain)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["kind"] as? String, "tunnelbahn.profile")
        XCTAssertEqual(obj["transport"] as? String, "ssh")
        let ssh = obj["ssh"] as! [String: Any]
        XCTAssertEqual(ssh["addr"] as? String, "1.2.3.4:443")
        XCTAssertEqual(ssh["user"] as? String, "tb")
        XCTAssertEqual(ssh["privateKeyPEM"] as? String, "PEMDATA")
        XCTAssertNil(obj["wg"])
    }

    func testWGEncodeBuildsWSSUrl() throws {
        let profile = makeWGProfile(serverHost: "1.2.3.4", serverPort: 443, tls: true,
                                    pathPrefix: "tun", forwardHost: "127.0.0.1", forwardPort: 51840)
        let json = try AndroidProfileQRCodec.encode(profile, secrets: fakeKeychain)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["transport"] as? String, "wgws")
        let wg = obj["wg"] as! [String: Any]
        XCTAssertEqual(wg["wsURL"] as? String, "wss://1.2.3.4:443/tun/events")
        XCTAssertEqual(wg["forwardPort"] as? Int, 51840)
        XCTAssertEqual(wg["privateKey"] as? String, "wgpriv")
        XCTAssertEqual(wg["peerPublicKey"] as? String, "peerpub")
        // Android's core parses bare IPs; the "/32" prefix must be stripped.
        XCTAssertEqual(wg["localAddrs"] as? [String], ["10.9.0.2"])
    }

    func testWGEncodeNonTLSBuildsWSUrl() throws {
        let profile = makeWGProfile(tls: false)
        let json = try AndroidProfileQRCodec.encode(profile, secrets: fakeKeychain)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let wg = obj["wg"] as! [String: Any]
        XCTAssertEqual(wg["wsURL"] as? String, "ws://1.2.3.4:443/tun/events")
    }

    func testPlainWireGuardWithoutWrapperThrows() {
        let profile = makeWGProfile(wrapper: false)
        XCTAssertThrowsError(try AndroidProfileQRCodec.encode(profile, secrets: fakeKeychain))
    }
}

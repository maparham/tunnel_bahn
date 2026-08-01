import XCTest

final class TCPWrapperConfigCodecTests: XCTestCase {
    private let reference = WireGuardTCPWrapper(
        serverHost: "3.139.146.5", serverPort: 443, tls: true, verifyCert: false,
        pathPrefix: "tun74fd08a683078a3e0439", forwardHost: "127.0.0.1", forwardPort: 51840
    )

    func testDecodeFromLowercasedMap() throws {
        // Parser lowercases keys and preserves values.
        let map = [
            "server": "3.139.146.5:443", "tls": "true", "verifycert": "false",
            "pathprefix": "tun74fd08a683078a3e0439", "forward": "127.0.0.1:51840",
        ]
        XCTAssertEqual(try TCPWrapperConfigCodec.decode(map), reference)
    }

    func testDecodeEmptyMapReturnsNil() throws {
        XCTAssertNil(try TCPWrapperConfigCodec.decode([:]))
    }

    func testMissingRequiredKeyThrows() {
        let map = ["tls": "true"]  // no server/pathprefix/forward
        XCTAssertThrowsError(try TCPWrapperConfigCodec.decode(map))
    }

    func testEncodeThenDecodeRoundTrips() throws {
        let lines = TCPWrapperConfigCodec.encodeLines(reference)
        // Re-parse the rendered lines into a lowercased map the way the parser would.
        var map: [String: String] = [:]
        for line in lines where line.contains("=") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            map[parts[0].lowercased()] = parts[1]
        }
        XCTAssertEqual(try TCPWrapperConfigCodec.decode(map), reference)
    }
}

import XCTest

final class WGTunnelJWTTests: XCTestCase {
    private func b64urlDecode(_ s: Substring) -> Data {
        var str = String(s).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)!
    }

    func testTokenShapeMatchesWstunnelReference() throws {
        let token = WGTunnelJWT.makeUDP(forwardHost: "127.0.0.1", forwardPort: 51840, id: "019fae0b-c9e2-7d22-9e50-6d71cc8482eb")
        let parts = token.split(separator: ".")
        XCTAssertEqual(parts.count, 3)

        let header = try JSONSerialization.jsonObject(with: b64urlDecode(parts[0])) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "HS256")
        XCTAssertEqual(header["typ"] as? String, "JWT")

        let claims = try JSONSerialization.jsonObject(with: b64urlDecode(parts[1])) as! [String: Any]
        XCTAssertEqual(claims["id"] as? String, "019fae0b-c9e2-7d22-9e50-6d71cc8482eb")
        XCTAssertEqual(claims["r"] as? String, "127.0.0.1")
        XCTAssertEqual(claims["rp"] as? Int, 51840)
        let p = claims["p"] as! [String: Any]
        let udp = p["Udp"] as! [String: Any]
        let timeout = udp["timeout"] as! [String: Any]
        XCTAssertEqual(timeout["secs"] as? Int, 30)
        XCTAssertEqual(timeout["nanos"] as? Int, 0)
    }

    func testSignatureSegmentIsNonEmpty() {
        let token = WGTunnelJWT.makeUDP(forwardHost: "10.0.0.1", forwardPort: 51820)
        XCTAssertFalse(token.split(separator: ".")[2].isEmpty)  // server ignores it, but it must be present
    }
}

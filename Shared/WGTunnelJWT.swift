import Foundation
import CryptoKit

/// Builds the JWT wstunnel v10 sends in the `authorization.bearer.<jwt>` WebSocket subprotocol.
/// The server decodes it with `dangerous::insecure_decode` (no signature verification) and the
/// real client signs with a random per-run secret, so we do the same: HS256 over a random key.
enum WGTunnelJWT {
    /// Claims match wstunnel's `JwtTunnelConfig` for a UDP forward:
    /// {"id":<uuid>,"p":{"Udp":{"timeout":{"secs":N,"nanos":0}}},"r":<host>,"rp":<port>}
    static func makeUDP(
        forwardHost: String,
        forwardPort: UInt16,
        timeoutSecs: Int = 30,
        id: String = UUID().uuidString
    ) -> String {
        let header = #"{"typ":"JWT","alg":"HS256"}"#
        // Hand-built to guarantee key order and integer literals (JSONEncoder is fine too, but the
        // server only reads fields by name — key order is irrelevant to it).
        let claims = "{\"id\":\"\(id)\",\"p\":{\"Udp\":{\"timeout\":{\"secs\":\(timeoutSecs),\"nanos\":0}}},\"r\":\"\(forwardHost)\",\"rp\":\(forwardPort)}"
        let signingInput = base64url(Data(header.utf8)) + "." + base64url(Data(claims.utf8))

        var keyBytes = Data(count: 32)
        keyBytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: keyBytes))
        return signingInput + "." + base64url(Data(mac))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

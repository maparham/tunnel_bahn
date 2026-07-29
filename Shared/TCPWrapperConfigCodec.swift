import Foundation

enum TCPWrapperConfigError: LocalizedError {
    case missingKey(String)
    case invalidPort(String)

    var errorDescription: String? {
        switch self {
        case let .missingKey(k): return "[TCPWrapper] section is missing required key '\(k)'."
        case let .invalidPort(v): return "[TCPWrapper] has an invalid host:port value '\(v)'."
        }
    }
}

/// Maps the `[TCPWrapper]` config section (keys already lowercased by the WG parser) to and from
/// `WireGuardTCPWrapper`. Pure: no Keychain, no I/O. The section carries no secrets.
enum TCPWrapperConfigCodec {
    /// Returns nil when the map is empty (no `[TCPWrapper]` section present). Throws on a
    /// partially-specified section (missing/invalid required keys).
    static func decode(_ map: [String: String]) throws -> WireGuardTCPWrapper? {
        if map.isEmpty { return nil }
        let (serverHost, serverPort) = try splitHostPort(require(map, "server"))
        let (forwardHost, forwardPort) = try splitHostPort(require(map, "forward"))
        let pathPrefix = try require(map, "pathprefix")
        let tls = parseBool(map["tls"], default: true)
        let verifyCert = parseBool(map["verifycert"], default: false)
        return WireGuardTCPWrapper(
            serverHost: serverHost, serverPort: serverPort, tls: tls, verifyCert: verifyCert,
            pathPrefix: pathPrefix, forwardHost: forwardHost, forwardPort: forwardPort
        )
    }

    static func encodeLines(_ w: WireGuardTCPWrapper) -> [String] {
        [
            "[TCPWrapper]",
            "Server = \(w.serverHost):\(w.serverPort)",
            "TLS = \(w.tls)",
            "VerifyCert = \(w.verifyCert)",
            "PathPrefix = \(w.pathPrefix)",
            "Forward = \(w.forwardHost):\(w.forwardPort)",
        ]
    }

    private static func require(_ map: [String: String], _ key: String) throws -> String {
        guard let v = map[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else {
            throw TCPWrapperConfigError.missingKey(key)
        }
        return v
    }

    private static func parseBool(_ v: String?, default def: Bool) -> Bool {
        guard let v = v?.trimmingCharacters(in: .whitespaces).lowercased() else { return def }
        if ["true", "1", "yes", "on"].contains(v) { return true }
        if ["false", "0", "no", "off"].contains(v) { return false }
        return def
    }

    /// Splits "host:port" (IPv4 or hostname). IPv6 literals are out of scope for the wrapper target.
    private static func splitHostPort(_ value: String) throws -> (String, UInt16) {
        guard let idx = value.lastIndex(of: ":") else { throw TCPWrapperConfigError.invalidPort(value) }
        let host = String(value[..<idx])
        let portStr = String(value[value.index(after: idx)...])
        guard !host.isEmpty, let port = UInt16(portStr) else { throw TCPWrapperConfigError.invalidPort(value) }
        return (host, port)
    }
}

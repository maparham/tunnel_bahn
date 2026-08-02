import Foundation

/// Minimal read-only seam over the secret store so the codec is unit-testable without the
/// Keychain singleton. Conformance lives here (not in KeychainService.swift) because that file
/// also compiles into the network extensions, which do not see this protocol.
protocol SecretReading {
    func read(account: String) throws -> String
}

extension KeychainService: SecretReading {}

/// The cross-app JSON a macOS profile is encoded into for Android to scan. Field names and
/// the `"ssh"`/`"wgws"` transport values match the Android `parseImportedProfile` parser.
struct AndroidProfileQRPayload: Encodable {
    struct SSH: Encodable { let addr, user, privateKeyPEM: String }
    struct WG: Encodable {
        let privateKey, peerPublicKey, presharedKey: String
        let localAddrs, dns: [String]
        let mtu: Int
        let wsURL, forwardHost: String
        let forwardPort: Int
    }
    let kind = "tunnelbahn.profile"
    let name: String
    let transport: String
    let ssh: SSH?
    let wg: WG?
}

enum AndroidProfileQRError: LocalizedError {
    case noAndroidTransport
    case missingSecret(String)

    var errorDescription: String? {
        switch self {
        case .noAndroidTransport: return "This profile has no Android-compatible transport."
        case .missingSecret(let s): return "Missing key material: \(s)."
        }
    }
}

enum AndroidProfileQRCodec {
    /// Encodes [profile] as the compact JSON Android scans. SSH profiles map to `"ssh"`; a WG
    /// profile with an enabled TCP wrapper maps to `"wgws"`. Plain WG (no wrapper) has no
    /// Android transport and throws. Reads key material through [secrets].
    static func encode(_ profile: WireGuardProfile, secrets: SecretReading) throws -> String {
        let payload: AndroidProfileQRPayload
        if profile.transport == .ssh, let ssh = profile.ssh {
            let pem = try secrets.read(account: ssh.privateKeyRef)
            payload = AndroidProfileQRPayload(
                name: profile.name, transport: "ssh",
                ssh: .init(addr: "\(ssh.host):\(ssh.port)", user: ssh.username, privateKeyPEM: pem),
                wg: nil
            )
        } else if let w = profile.tcpWrapper, w.enabled, let peer = profile.peers.first {
            let priv = try secrets.read(account: profile.interface.privateKeyRef)
            let psk = try peer.presharedKeyRef.map { try secrets.read(account: $0) } ?? ""
            let scheme = w.tls ? "wss" : "ws"
            payload = AndroidProfileQRPayload(
                name: profile.name, transport: "wgws", ssh: nil,
                wg: .init(
                    privateKey: priv, peerPublicKey: peer.publicKey, presharedKey: psk,
                    // Android's core parses these with netip.ParseAddr (bare IPs, no prefix), so
                    // strip the CIDR suffix the macOS interface stores (e.g. "10.9.0.2/32").
                    localAddrs: profile.interface.addresses.map(Self.stripPrefix),
                    dns: profile.interface.dnsServers.map(Self.stripPrefix),
                    mtu: profile.interface.mtu ?? 1280,
                    wsURL: "\(scheme)://\(w.serverHost):\(w.serverPort)/\(w.pathPrefix)/events",
                    forwardHost: w.forwardHost, forwardPort: Int(w.forwardPort)
                )
            )
        } else {
            throw AndroidProfileQRError.noAndroidTransport
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [] // compact
        return String(decoding: try enc.encode(payload), as: UTF8.self)
    }

    /// Drops a trailing CIDR prefix ("10.9.0.2/32" -> "10.9.0.2"), leaving bare addresses.
    private static func stripPrefix(_ addr: String) -> String {
        String(addr.split(separator: "/", maxSplits: 1).first ?? Substring(addr))
    }
}

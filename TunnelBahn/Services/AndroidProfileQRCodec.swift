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
        // "wgws" only. Optionals are omitted from the JSON when nil.
        let wsURL, forwardHost: String?
        let forwardPort: Int?
        // "wg" only.
        let endpoint: String?
        let keepalive: Int?
    }
    let kind = "tunnelbahn.profile"
    let name: String
    let transport: String
    let ssh: SSH?
    let wg: WG?
}

enum AndroidProfileQRError: LocalizedError {
    case noPeerEndpoint
    case missingSecret(String)

    var errorDescription: String? {
        switch self {
        case .noPeerEndpoint: return "This profile has no peer endpoint to export."
        case .missingSecret(let s): return "Missing key material: \(s)."
        }
    }
}

enum AndroidProfileQRCodec {
    /// Encodes [profile] as the compact JSON Android scans. SSH profiles map to "ssh"; a WG profile with an enabled TCP wrapper maps to "wgws"; any other WG profile maps to plain "wg" using the peer's endpoint. Reads key material through [secrets].
    static func encode(_ profile: WireGuardProfile, secrets: SecretReading) throws -> String {
        let payload: AndroidProfileQRPayload
        if profile.transport == .ssh, let ssh = profile.ssh {
            let pem = try secrets.read(account: ssh.privateKeyRef)
            payload = AndroidProfileQRPayload(
                name: profile.name, transport: "ssh",
                ssh: .init(addr: "\(ssh.host):\(ssh.port)", user: ssh.username, privateKeyPEM: pem),
                wg: nil
            )
        } else if let peer = profile.peers.first {
            let priv = try secrets.read(account: profile.interface.privateKeyRef)
            let psk = try peer.presharedKeyRef.map { try secrets.read(account: $0) } ?? ""
            // Android's core parses these with netip.ParseAddr (bare IPs, no prefix), so
            // strip the CIDR suffix the macOS interface stores (e.g. "10.9.0.2/32").
            let localAddrs = profile.interface.addresses.map(Self.stripPrefix)
            let dns = profile.interface.dnsServers.map(Self.stripPrefix)
            let mtu = profile.interface.mtu ?? 1280
            if let w = profile.tcpWrapper, w.enabled {
                let scheme = w.tls ? "wss" : "ws"
                payload = AndroidProfileQRPayload(
                    name: profile.name, transport: "wgws", ssh: nil,
                    wg: .init(
                        privateKey: priv, peerPublicKey: peer.publicKey, presharedKey: psk,
                        localAddrs: localAddrs, dns: dns, mtu: mtu,
                        wsURL: "\(scheme)://\(w.serverHost):\(w.serverPort)/\(w.pathPrefix)/events",
                        forwardHost: w.forwardHost, forwardPort: Int(w.forwardPort),
                        endpoint: nil, keepalive: nil
                    )
                )
            } else {
                let endpoint = peer.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !endpoint.isEmpty else { throw AndroidProfileQRError.noPeerEndpoint }
                payload = AndroidProfileQRPayload(
                    name: profile.name, transport: "wg", ssh: nil,
                    wg: .init(
                        privateKey: priv, peerPublicKey: peer.publicKey, presharedKey: psk,
                        localAddrs: localAddrs, dns: dns, mtu: mtu,
                        wsURL: nil, forwardHost: nil, forwardPort: nil,
                        endpoint: endpoint, keepalive: peer.persistentKeepalive ?? 25
                    )
                )
            }
        } else {
            throw AndroidProfileQRError.noPeerEndpoint
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

import Foundation

/// Discriminates which egress transport a saved profile uses. Existing (pre-SSH) profiles
/// have no `transport` key on disk and must decode as `.wireguard` — see the defaulting
/// decoder on `WireGuardProfile`.
enum TransportKind: String, Codable, CaseIterable, Hashable {
    case wireguard
    case ssh
}

struct SSHProfile: Codable, Equatable, Hashable {
    var host: String
    var port: UInt16
    var username: String
    /// Keychain account id under which the PEM private key is stored.
    var privateKeyRef: String
    /// TOFU-pinned server host-key fingerprint (SHA-256, base64). nil until first connect.
    var hostKeyFingerprint: String?
}

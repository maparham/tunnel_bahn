import Foundation

struct AppBackup: Codable {
    /// v2: `privateKeyValue` became optional and `sshPrivateKeyValue` was added for
    /// SSH-transport profiles. Version 1 builds decode `privateKeyValue` as non-optional,
    /// so without this bump they would fail a v2 import with a raw decoding error instead
    /// of their `unsupportedVersion` message.
    static let currentVersion = 2

    var version: Int
    var createdAt: Date
    var appSettings: AppSettingsSnapshot?
    var profiles: [ProfileBackupEntry]?
}

struct AppSettingsSnapshot: Codable {
    var autoReconnect: Bool
    var launchAtLogin: Bool
    var showTrafficRates: Bool
    var diagnosticsLevel: String
    var runTunnelConnectivityProbe: Bool
}

struct ProfileBackupEntry: Codable {
    // Keychain refs inside `profile` are stale account IDs — the actual key material
    // travels in the *Value fields below. On import, fresh account IDs are minted.
    var profile: WireGuardProfile
    /// WG interface private key. nil for SSH-transport profiles (they carry no WG key).
    var privateKeyValue: String?
    var peerPresharedKeys: [String: String]   // peer.id.uuidString -> raw PSK
    /// PEM private key for SSH-transport profiles. nil otherwise.
    var sshPrivateKeyValue: String?
    var routingSnapshot: ProfileRoutingSnapshot?
}

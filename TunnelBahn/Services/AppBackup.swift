import Foundation

struct AppBackup: Codable {
    static let currentVersion = 1

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
    // profile.interface.privateKeyRef is a stale keychain account ID — the actual
    // key material travels in privateKeyValue. On import, a fresh account ID is minted.
    var profile: WireGuardProfile
    var privateKeyValue: String
    var peerPresharedKeys: [String: String]   // peer.id.uuidString -> raw PSK
    var routingSnapshot: ProfileRoutingSnapshot?
}

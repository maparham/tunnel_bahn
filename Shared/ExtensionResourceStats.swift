import Foundation

/// CPU and resident memory samples for Network Extension processes, written from each
/// extension and read by the host app.
struct ExtensionResourceStats: Codable {
    static let currentSchemaVersion: Int = 1

    var packetTunnelCPU: Double
    var packetTunnelMemory: UInt64
    var transparentProxyCPU: Double
    var transparentProxyMemory: UInt64
    var lastUpdate: Date
    var schemaVersion: Int

    static let empty = ExtensionResourceStats(
        packetTunnelCPU: 0,
        packetTunnelMemory: 0,
        transparentProxyCPU: 0,
        transparentProxyMemory: 0,
        lastUpdate: .distantPast,
        schemaVersion: ExtensionResourceStats.currentSchemaVersion
    )
}

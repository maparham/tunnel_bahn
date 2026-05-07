import Foundation

enum VPNConnectionState: String, Codable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case reconnecting
    case error
}

struct ConnectionStats: Codable {
    var state: VPNConnectionState
    var connectedAt: Date?
    var lastError: String?
    var bytesIn: UInt64
    var bytesOut: UInt64
    var rxBytesPerSecond: Double
    var txBytesPerSecond: Double
    var connectedProfileID: UUID?
    var endpoint: String?
    var publicIP: String?
    var publicIPLocation: String?
    /// True when per-app policy is currently being enforced through Network Extension providers.
    var perAppSplitTunnelActive: Bool
    /// True while the transparent proxy is enabled to collect per-app stats (includes full-tunnel
    /// sessions that use the accounting stack, not only split-tunnel mode).
    var perAppStatsCollectionActive: Bool
    /// Aggregate app-payload receive / send rates (sum of all `perAppStats` counters), computed
    /// between host refresh ticks when per-app accounting is active. Same semantic layer as rows
    /// in `perAppStats`; not comparable to tunnel `rxBytesPerSecond` / `txBytesPerSecond`.
    var perAppAggregateRxBytesPerSecond: Double
    var perAppAggregateTxBytesPerSecond: Double
    /// Per-app payload byte counters, keyed by user-facing display name. Populated only in
    /// accounting-stack mode (split or full-tunnel with default-route profile); empty otherwise.
    /// Bytes here are app-payload bytes (pre-tunnel) and
    /// will not equal the WireGuard aggregate `bytesIn`/`bytesOut` (which are encrypted-frame
    /// totals on the UDP transport).
    var perAppStats: [String: AppTransferEntry]
    /// Wall-clock time of the last per-app stats flush from the extension. Used by the UI
    /// to detect staleness.
    var perAppStatsUpdatedAt: Date?

    static let empty = ConnectionStats(
        state: .disconnected,
        connectedAt: nil,
        lastError: nil,
        bytesIn: 0,
        bytesOut: 0,
        rxBytesPerSecond: 0,
        txBytesPerSecond: 0,
        connectedProfileID: nil,
        endpoint: nil,
        publicIP: nil,
        publicIPLocation: nil,
        perAppSplitTunnelActive: false,
        perAppStatsCollectionActive: false,
        perAppAggregateRxBytesPerSecond: 0,
        perAppAggregateTxBytesPerSecond: 0,
        perAppStats: [:],
        perAppStatsUpdatedAt: nil
    )
}

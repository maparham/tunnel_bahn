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
    var lastInboundAt: Date?
    var lastError: String?
    var bytesIn: UInt64
    var bytesOut: UInt64
    var rxBytesPerSecond: Double
    var txBytesPerSecond: Double
    var connectedProfileID: UUID?
    var endpoint: String?
    var publicIP: String?
    var publicIPLocation: String?
    /// True when app-tunnel policy is currently being enforced through Network Extension providers.
    var perAppSplitTunnelActive: Bool
    /// True while the transparent proxy is enabled to collect app-tunnel stats (includes full-tunnel
    /// sessions that use the accounting stack, not only split-tunnel mode).
    var perAppStatsCollectionActive: Bool
    /// Aggregate app-payload receive / send rates (sum of all `perAppStats` counters), computed
    /// between host refresh ticks when app-tunnel accounting is active. Same semantic layer as rows
    /// in `perAppStats`; not comparable to tunnel `rxBytesPerSecond` / `txBytesPerSecond`.
    var perAppAggregateRxBytesPerSecond: Double
    var perAppAggregateTxBytesPerSecond: Double
    /// App-tunnel payload byte counters, keyed by user-facing display name. Populated only in
    /// accounting-stack mode (split or full-tunnel with default-route profile); empty otherwise.
    /// Bytes here are app-payload bytes (pre-tunnel) and
    /// will not equal the WireGuard aggregate `bytesIn`/`bytesOut` (which are encrypted-frame
    /// totals on the UDP transport).
    var perAppStats: [String: AppTransferEntry]
    /// TCP-only session totals per app display name and remote IP literal; same flush cadence as `perAppStats`.
    var perDestinationStats: [PerDestinationTransferRow]
    /// Wall-clock time of the last app-tunnel stats flush from the extension. Used by the UI
    /// to detect staleness.
    var perAppStatsUpdatedAt: Date?
    /// Host app CPU usage (sum of non-idle thread scales; may exceed 100% on multi-core).
    var appCPUUsage: Double
    /// Host app resident memory size (RSS), bytes.
    var appMemoryUsage: UInt64
    /// Packet tunnel extension process; may exceed 100% on multi-core (same semantics as `appCPUUsage`).
    var packetTunnelCPUUsage: Double
    var packetTunnelMemoryUsage: UInt64
    /// Transparent proxy extension process.
    var transparentProxyCPUUsage: Double
    var transparentProxyMemoryUsage: UInt64
    /// Wall-clock time of the last merged write from either extension.
    var extensionStatsUpdatedAt: Date?
    /// True when the connected profile includes a default route (0.0.0.0/0 or ::/0) AND no
    /// destination split is active — i.e. the app's own internet requests reach the tunnel.
    /// False for LAN-only profiles and for destination-filtered sessions, where internet requests
    /// from TunnelBahn itself do not go through the tunnel. Drives the connectivity probe, the
    /// public-IP refresh, and the Profiles reachability badge.
    var tunnelHasDefaultRoute: Bool
    /// Result of the post-connect connectivity probe. Not persisted (excluded from Codable).
    var connectivityProbeResult: ConnectivityProbeResult = .unknown

    /// Signing IDs of competing transparent-proxy extensions observed by our proxy during the
    /// current session. When non-empty, those extensions are intercepting flows before ours and
    /// app-tunnel routing for user-selected apps may silently fail. Detection only runs while
    /// routing is narrowed to explicit app rules (never in route-all-identified-flows /
    /// full-traffic-accounting mode, where hints are intentionally unused). Not persisted.
    var competingProxySigningIDs: [String] = []

    /// True when this session's destination filter was forced to the WireGuard peer's AllowedIPs
    /// (a non-default-route split-tunnel profile), NOT derived from the user's destination rules.
    /// The host must then suppress live destination-range pushes to the running proxy: the peer has
    /// no route for user CIDRs, so intercepting those flows and relaying them into the tunnel would
    /// black-hole them. Not persisted (session-scoped, set at connect).
    var destinationFilterAllowedIPsDerived: Bool = false

    /// True while TunnelBahn's own internet traffic traverses the tunnel: connected with a
    /// default-route profile, no destination split, and (in app-tunnel mode) the host app
    /// included in the NEAppRule list. Drives the speed test's Tunnel/Direct classification.
    /// Not persisted (session-scoped, set at connect).
    var hostAppInternetPathIsTunnel: Bool = false

    /// True while the bundled speed test helper's internet traffic traverses the tunnel: connected
    /// with a default-route profile, a utun that still owns that default route, and — in NEAppRule
    /// shapes — a helper rule that was actually built. In plain full-tunnel shapes there are no
    /// NEAppRules at all and the helper rides the system-wide utun like everything else. Unlike
    /// `hostAppInternetPathIsTunnel` this stays true under a destination split, because the helper's
    /// own NEAppRule bypasses the destination filter.
    /// Not persisted (session-scoped, set at connect).
    var helperInternetPathIsTunnel: Bool = false

    // Exclude connectivityProbeResult and competingProxySigningIDs from Codable synthesis.
    private enum CodingKeys: String, CodingKey {
        case state, connectedAt, lastInboundAt, lastError, bytesIn, bytesOut
        case rxBytesPerSecond, txBytesPerSecond, connectedProfileID, endpoint
        case publicIP, publicIPLocation, perAppSplitTunnelActive, perAppStatsCollectionActive
        case perAppAggregateRxBytesPerSecond, perAppAggregateTxBytesPerSecond
        case perAppStats, perDestinationStats, perAppStatsUpdatedAt
        case appCPUUsage, appMemoryUsage, packetTunnelCPUUsage, packetTunnelMemoryUsage
        case transparentProxyCPUUsage, transparentProxyMemoryUsage, extensionStatsUpdatedAt
        case tunnelHasDefaultRoute
    }

    static let empty = ConnectionStats(
        state: .disconnected,
        connectedAt: nil,
        lastInboundAt: nil,
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
        perDestinationStats: [],
        perAppStatsUpdatedAt: nil,
        appCPUUsage: 0,
        appMemoryUsage: 0,
        packetTunnelCPUUsage: 0,
        packetTunnelMemoryUsage: 0,
        transparentProxyCPUUsage: 0,
        transparentProxyMemoryUsage: 0,
        extensionStatsUpdatedAt: nil,
        tunnelHasDefaultRoute: false
    )
}

import Foundation

/// App-tunnel transfer counters published by the TransparentProxy extension and read by the host app.
///
/// This is the JSON payload returned by the transparent proxy's `getStats` provider IPC reply:
/// the extension encodes its current snapshot on request and the host app decodes it directly,
/// with no intermediate file.
struct PerAppTransferStats: Codable {
    /// Keyed by user-facing display name (e.g. "Google Chrome"), not signing identifier.
    /// Helper signing IDs (Chrome's 6 helpers, Safari's WebKit.Networking, etc.) are rolled up
    /// into the parent app entry by `PerAppIdentityMap` before being written here.
    var apps: [String: AppTransferEntry]
    /// Wall-clock timestamp of the last extension flush. Useful for staleness detection in the UI.
    var lastUpdate: Date
    /// TCP-only per-(app, remote literal) session totals.
    var perDestination: [PerDestinationTransferRow]

    static let empty = PerAppTransferStats(
        apps: [:],
        lastUpdate: .distantPast,
        perDestination: []
    )
}

struct PerDestinationTransferRow: Codable, Equatable, Hashable, Identifiable {
    var appDisplayName: String
    var remoteLiteral: String
    var txBytes: UInt64
    var rxBytes: UInt64

    var id: String { "\(appDisplayName)\u{1e}\(remoteLiteral)" }
}

struct AppTransferEntry: Codable, Equatable {
    /// Bytes written to the destination by the app's flows (uplink, app payload bytes — pre-tunnel).
    var txBytes: UInt64
    /// Bytes received from the destination back to the app's flows (downlink, app payload bytes — pre-tunnel).
    var rxBytes: UInt64
    /// All signing identifiers that have contributed to this entry, retained for diagnostics
    /// and to surface unknown helpers (anything not in `PerAppSigningCatalog.knownRollupBySigningIdentifier`).
    var signingIdentifiers: Set<String>

    static let zero = AppTransferEntry(txBytes: 0, rxBytes: 0, signingIdentifiers: [])
}

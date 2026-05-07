import Foundation

/// Per-app transfer counters published by the TransparentProxy extension and read by the host app.
///
/// File semantics:
/// - Single writer (the extension) using atomic temp+rename pattern in `PerAppTransferStore`.
/// - Multiple concurrent readers (the host app) using non-blocking `Data(contentsOf:)`.
/// - `schemaVersion` is mandatory and lets future format changes coexist with older app/extension
///   pairs without crashing.
struct PerAppTransferStats: Codable {
    static let currentSchemaVersion: Int = 1

    /// Bumped when the on-disk format changes incompatibly. Readers MUST ignore unknown versions.
    var schemaVersion: Int
    /// Keyed by user-facing display name (e.g. "Google Chrome"), not signing identifier.
    /// Helper signing IDs (Chrome's 6 helpers, Safari's WebKit.Networking, etc.) are rolled up
    /// into the parent app entry by `PerAppIdentityMap` before being written here.
    var apps: [String: AppTransferEntry]
    /// Wall-clock timestamp of the last extension flush. Useful for staleness detection in the UI.
    var lastUpdate: Date

    static let empty = PerAppTransferStats(
        schemaVersion: PerAppTransferStats.currentSchemaVersion,
        apps: [:],
        lastUpdate: .distantPast
    )
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

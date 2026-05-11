import Foundation

/// Thread-safe per-(signingID, remote literal) byte counters for TCP flows only.
///
/// Rolled up to `(app display name, remote)` rows at flush time, analogous to
/// `PerAppCounterAggregator`.
final class PerDestinationCounterAggregator {
    private static let keySeparator: Character = "\u{1e}"

    static func compositeKey(signingID: String, remoteLiteral: String) -> String {
        "\(signingID)\(String(keySeparator))\(remoteLiteral)"
    }

    private let lock = NSLock()
    private var totals: [String: Totals] = [:]

    private struct Totals {
        var txBytes: UInt64 = 0
        var rxBytes: UInt64 = 0
    }

    func addTx(_ bytes: UInt64, signingID: String, remoteLiteral: String) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = Self.compositeKey(signingID: signingID, remoteLiteral: remoteLiteral)
        var t = totals[key] ?? Totals()
        t.txBytes &+= bytes
        totals[key] = t
    }

    func addRx(_ bytes: UInt64, signingID: String, remoteLiteral: String) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = Self.compositeKey(signingID: signingID, remoteLiteral: remoteLiteral)
        var t = totals[key] ?? Totals()
        t.rxBytes &+= bytes
        totals[key] = t
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        totals.removeAll(keepingCapacity: false)
    }

    /// Maps signing IDs to display names and merges rows that share `(displayName, remoteLiteral)`.
    func rollupToRows(rules: [AppRule]) -> [PerDestinationTransferRow] {
        lock.lock()
        let snap = totals
        lock.unlock()

        var merged: [String: PerDestinationTransferRow] = [:]

        for (compositeKey, t) in snap {
            let parts = compositeKey.split(separator: Self.keySeparator, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let signingID = String(parts[0])
            let remote = String(parts[1])

            let displayName = PerAppIdentityMap.displayName(for: signingID, rules: rules)
                ?? "Other (\(signingID))"

            let mergeKey = "\(displayName)\(String(Self.keySeparator))\(remote)"
            var row = merged[mergeKey] ?? PerDestinationTransferRow(
                appDisplayName: displayName,
                remoteLiteral: remote,
                txBytes: 0,
                rxBytes: 0
            )
            row.txBytes &+= t.txBytes
            row.rxBytes &+= t.rxBytes
            merged[mergeKey] = row
        }

        return merged.values.sorted { lhs, rhs in
            let lSum = lhs.txBytes &+ lhs.rxBytes
            let rSum = rhs.txBytes &+ rhs.rxBytes
            if lSum != rSum { return lSum > rSum }
            if lhs.appDisplayName != rhs.appDisplayName { return lhs.appDisplayName < rhs.appDisplayName }
            return lhs.remoteLiteral < rhs.remoteLiteral
        }
    }
}

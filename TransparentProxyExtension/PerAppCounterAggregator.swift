import Foundation
import os.log

/// Thread-safe accumulator of per-signing-identifier byte counters.
///
/// The aggregator is fed by relay handlers (TCP/UDP) on arbitrary queues and is drained
/// by a periodic flush timer that rolls helper signing identifiers up to user-facing
/// app names via `PerAppIdentityMap` and writes the result through `PerAppTransferStore`.
///
/// Design notes:
/// - In-memory totals are kept per signing identifier (cheaper than app-tunnel rollup on every
///   packet). Rollup only happens at flush time.
/// - Totals are MONOTONIC for the lifetime of the proxy session. The host app diffs them
///   to compute rates if it wants to. On disconnect the host app calls
///   `PerAppTransferStore.reset()` which clears the file but the in-memory totals here
///   reset on `stopProxy` because the provider instance is torn down.
final class PerAppCounterAggregator {
    private static let log = Logger(
        subsystem: "com.tunnelbahn.mac.transparentproxy",
        category: "Aggregator"
    )

    private let lock = NSLock()
    private var totals: [String: AppTransferEntry] = [:]
    private var unknownSigningIDs: Set<String> = []
    private var didLogFirstByteFor: Set<String> = []

    func addTx(_ bytes: UInt64, signingID: String) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var entry = totals[signingID] ?? .zero
        entry.txBytes &+= bytes
        entry.signingIdentifiers.insert(signingID)
        totals[signingID] = entry

        if didLogFirstByteFor.insert(signingID).inserted {
            Self.log.notice("first bytes observed: signingID=\(signingID, privacy: .public) tx=\(entry.txBytes, privacy: .public) rx=\(entry.rxBytes, privacy: .public)")
        }
    }

    func addRx(_ bytes: UInt64, signingID: String) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var entry = totals[signingID] ?? .zero
        entry.rxBytes &+= bytes
        entry.signingIdentifiers.insert(signingID)
        totals[signingID] = entry

        if didLogFirstByteFor.insert(signingID).inserted {
            Self.log.notice("first bytes observed: signingID=\(signingID, privacy: .public) tx=\(entry.txBytes, privacy: .public) rx=\(entry.rxBytes, privacy: .public)")
        }
    }

    /// Snapshot the current counters so a flush can write them out without holding the lock
    /// across file IO.
    func snapshot() -> [String: AppTransferEntry] {
        lock.lock()
        defer { lock.unlock() }
        return totals
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        totals.removeAll(keepingCapacity: false)
        unknownSigningIDs.removeAll(keepingCapacity: false)
        didLogFirstByteFor.removeAll(keepingCapacity: false)
    }

    /// Roll signing-identifier-keyed totals up to display-name-keyed entries using the
    /// current `AppRule` list as a fallback for any helper that isn't in the curated map.
    func rollup(rules: [AppRule]) -> [String: AppTransferEntry] {
        let snap = snapshot()
        var rolledUp: [String: AppTransferEntry] = [:]
        var newUnknowns: [String] = []

        for (signingID, entry) in snap {
            let displayName = PerAppIdentityMap.displayName(for: signingID, rules: rules)
                ?? "Other (\(signingID))"

            if PerAppIdentityMap.displayName(for: signingID, rules: rules) == nil {
                lock.lock()
                if unknownSigningIDs.insert(signingID).inserted {
                    newUnknowns.append(signingID)
                }
                lock.unlock()
            }

            var rolled = rolledUp[displayName] ?? .zero
            rolled.txBytes &+= entry.txBytes
            rolled.rxBytes &+= entry.rxBytes
            rolled.signingIdentifiers.formUnion(entry.signingIdentifiers)
            rolledUp[displayName] = rolled
        }

        for id in newUnknowns {
            Self.log.notice("unknown signing identifier observed: \(id, privacy: .public)")
        }

        return rolledUp
    }
}

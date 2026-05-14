import Foundation

/// TTL-aware DNS resolution scheduler. Polls every 30 s and re-resolves expired domain rules.
/// Resolution is de-duplicated: only one in-flight query per domain ID at a time.
@MainActor
final class DomainResolutionCoordinator {
    private weak var ruleStore: DestinationRuleStore?
    private var timerTask: Task<Void, Never>?
    private var inFlightByID: [UUID: Task<Void, Never>] = [:]

    /// Set by AppState when VPN state changes; currently informational (tunnel DNS preference
    /// is handled automatically by the system resolver when the VPN interface is up).
    var isConnected: Bool = false

    private static let pollInterval: TimeInterval = 30

    init(ruleStore: DestinationRuleStore) {
        self.ruleStore = ruleStore
    }

    /// Start the background TTL-poll loop. Idempotent.
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { break }
                self?.resolveExpiredDomains()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        for task in inFlightByID.values { task.cancel() }
        inFlightByID.removeAll()
    }

    /// Re-resolve every enabled domain immediately (e.g. on VPN connect or profile switch).
    func resolveAll() {
        guard let ruleStore else { return }
        for rule in ruleStore.domainRules where rule.isEnabled {
            enqueueResolution(for: rule.id, domain: rule.domain)
        }
    }

    /// Resolves all enabled domains and waits for every in-flight query to finish.
    /// Call this before writing destination-routing.json on VPN connect so the file
    /// is fully populated before the proxy extension reads it.
    func resolveAllAndWait() async {
        // Snapshot the dictionary BEFORE calling resolveAll(). A prior call to
        // resolveAll() (e.g. from installRoutingSnapshot called just before connect)
        // may have already enqueued tasks for every domain. Those tasks remove
        // themselves from inFlightByID via `defer` on completion, so they can vanish
        // before we snapshot — causing resolveAllAndWait to await zero tasks and
        // return while DNS is still in flight. Snapshotting first captures pre-existing
        // tasks; resolveAll() then adds any domains that weren't already in flight;
        // snapshotting again captures the union — keyed by UUID so there are no dupes.
        var tasksByID = inFlightByID
        resolveAll()
        for (id, task) in inFlightByID {
            tasksByID[id] = task
        }
        await withTaskGroup(of: Void.self) { group in
            for task in tasksByID.values {
                group.addTask { await task.value }
            }
        }
    }

    /// Enqueue resolution for a single domain ID. No-op if a query is already in flight for that ID.
    func enqueueResolution(for id: UUID, domain: String) {
        guard inFlightByID[id] == nil else { return }
        ruleStore?.markResolving(id: id)
        let task = Task { @MainActor [weak self] in
            defer { self?.inFlightByID.removeValue(forKey: id) }
            do {
                let result = try await DomainResolver.resolve(domain: domain)
                self?.ruleStore?.applyResolution(id: id, cidrs: result.cidrs, ttl: result.ttl)
            } catch {
                let message: String
                if let e = error as? DomainResolverError {
                    message = e.errorDescription ?? error.localizedDescription
                } else {
                    message = error.localizedDescription
                }
                self?.ruleStore?.applyResolutionFailure(id: id, message: message)
            }
        }
        inFlightByID[id] = task
    }

    /// Cancel any in-flight query for `id` and start a fresh resolution that replaces stored CIDRs.
    func forceResolve(id: UUID, domain: String) {
        inFlightByID[id]?.cancel()
        inFlightByID.removeValue(forKey: id)
        ruleStore?.markResolving(id: id)
        let task = Task { @MainActor [weak self] in
            defer { self?.inFlightByID.removeValue(forKey: id) }
            do {
                let result = try await DomainResolver.resolve(domain: domain)
                self?.ruleStore?.applyResolutionReplacing(id: id, cidrs: result.cidrs, ttl: result.ttl)
            } catch {
                let message: String
                if let e = error as? DomainResolverError {
                    message = e.errorDescription ?? error.localizedDescription
                } else {
                    message = error.localizedDescription
                }
                self?.ruleStore?.applyResolutionFailure(id: id, message: message)
            }
        }
        inFlightByID[id] = task
    }

    private func resolveExpiredDomains() {
        guard let ruleStore else { return }
        for rule in ruleStore.domainRules where rule.isEnabled {
            guard rule.isExpired() else { continue }
            // Use merge semantics on TTL expiry: union new IPs into existing resolvedCidrs
            // (capped at DestinationRuleStore.resolvedCidrCap per rule).
            // Full replacement only happens when the user taps "Refresh resolved IPs".
            enqueueResolution(for: rule.id, domain: rule.domain)
        }
    }
}

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
        resolveAll()
        // Snapshot the tasks *after* resolveAll() so we capture any newly-enqueued ones.
        // Tasks remove themselves from inFlightByID via defer on completion, so we must
        // hold our own references here to avoid a race where a task finishes and removes
        // itself before the withTaskGroup loop adds it.
        let tasks = Array(inFlightByID.values)
        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
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

    private func resolveExpiredDomains() {
        guard let ruleStore else { return }
        for rule in ruleStore.domainRules where rule.isEnabled {
            guard rule.isExpired() else { continue }
            enqueueResolution(for: rule.id, domain: rule.domain)
        }
    }
}

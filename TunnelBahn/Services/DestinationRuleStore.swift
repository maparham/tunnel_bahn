import Foundation

struct DestinationCidrImportResult: Equatable {
    var added: Int
    var skippedInvalid: Int
    var skippedDuplicate: Int
}

private struct DestinationRulesByModePersisted: Codable {
    var include: DestinationModeRuleSet
    var exclude: DestinationModeRuleSet
}

@MainActor
final class DestinationRuleStore: ObservableObject {
    /// The currently edited mode's rules. All published arrays and every mutator refer to
    /// `editedMode`'s set; the other mode's set is parked in `offModeSet`.
    @Published private(set) var customRules: [DestinationCidrRule] = [] { didSet { rulesVersion &+= 1 } }
    @Published private(set) var bulkGroups: [DestinationCidrBulkGroup] = [] { didSet { rulesVersion &+= 1 } }
    @Published private(set) var domainRules: [DestinationDomainRule] = [] { didSet { rulesVersion &+= 1 } }
    @Published private(set) var editedMode: DestinationFilterMode = .include { didSet { rulesVersion &+= 1 } }

    /// The not-currently-edited mode's complete rule set.
    private var offModeSet = DestinationModeRuleSet() { didSet { rulesVersion &+= 1 } }

    /// Bumped on every rule mutation in either mode; keys the derived-value caches below so
    /// they never compare whole rule arrays on the hot path.
    private var rulesVersion: UInt64 = 0

    /// Cache for `enabledValidCidrCount`. The menu bar asks for this on every AppState change,
    /// and parsing thousands of bulk CIDRs each time was measured at ~15% of the idle main thread.
    private var validCidrCountCache: (version: UInt64, mode: DestinationFilterMode, toggles: DestinationSectionToggles, count: Int)?
    /// Number of times the count was actually recomputed (tests assert cache hits).
    private(set) var validCidrCountComputations = 0

    private let defaultsKey = "destinationRulesByMode"
    private let defaults: UserDefaults

    /// Prepared matchers invalidated when `customRules` / `bulkGroups` change — avoids re-preparing bulk CIDRs per stats refresh.
    private var cachedRulesFingerprint: [DestinationCidrRule]?
    private var cachedBulkFingerprint: [DestinationCidrBulkGroup]?
    private var cachedCustomPrepared: [(cidrDisplay: String, ranges: [IPCIDRMatcher.PreparedRange])] = []
    private var cachedBulkPrepared: [(title: String, ranges: [IPCIDRMatcher.PreparedRange])] = []

    init(defaults: UserDefaults = AppGroupStore.defaults) {
        self.defaults = defaults
        load()
    }

    // MARK: - Mode plumbing

    /// Swap the published arrays to `mode`'s set. Pure view-of-data switch; content unchanged, no save().
    func setEditedMode(_ mode: DestinationFilterMode) {
        guard mode != editedMode else { return }
        let outgoing = DestinationModeRuleSet(customRules: customRules, bulkGroups: bulkGroups, domainRules: domainRules)
        let incoming = offModeSet
        offModeSet = outgoing
        editedMode = mode
        customRules = incoming.customRules
        bulkGroups = incoming.bulkGroups
        domainRules = incoming.domainRules
    }

    func ruleSet(for mode: DestinationFilterMode) -> DestinationModeRuleSet {
        mode == editedMode
            ? DestinationModeRuleSet(customRules: customRules, bulkGroups: bulkGroups, domainRules: domainRules)
            : offModeSet
    }

    func addRule(cidr: String) -> Bool {
        let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !IPCIDRMatcher.prepare([trimmed]).isEmpty else { return false }
        if allExistingCidrsTrimmed().contains(trimmed) {
            return false
        }
        customRules.append(DestinationCidrRule(cidr: trimmed))
        save()
        return true
    }

    /// Adds a new bulk list; duplicates any CIDR already present anywhere are skipped.
    /// `countryCode` marks the list as refreshable via `CountryCidrListRefresher`.
    func importCidrLines(
        from plainText: String, bulkTitle: String, countryCode: String? = nil
    ) -> DestinationCidrImportResult {
        let title = bulkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported list"
            : bulkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = DestinationCidrTextParser.candidateStrings(from: plainText)
        var existing = allExistingCidrsTrimmed()
        var seenInBatch = Set<String>()
        var added = 0
        var skippedInvalid = 0
        var skippedDuplicate = 0
        var newCidrs: [String] = []

        for trimmed in candidates {
            if IPCIDRMatcher.prepare([trimmed]).isEmpty {
                skippedInvalid += 1
                continue
            }
            if existing.contains(trimmed) || seenInBatch.contains(trimmed) {
                skippedDuplicate += 1
                continue
            }
            newCidrs.append(trimmed)
            existing.insert(trimmed)
            seenInBatch.insert(trimmed)
            added += 1
        }

        if !newCidrs.isEmpty {
            bulkGroups.append(DestinationCidrBulkGroup(
                title: title, cidrs: newCidrs,
                countryCode: countryCode, refreshedAt: countryCode == nil ? nil : Date()
            ))
            save()
        }

        return DestinationCidrImportResult(
            added: added,
            skippedInvalid: skippedInvalid,
            skippedDuplicate: skippedDuplicate
        )
    }

    func removeRule(ids: IndexSet) {
        for index in ids.sorted(by: >) { customRules.remove(at: index) }
        save()
    }

    func removeRule(id: UUID) {
        customRules.removeAll { $0.id == id }
        save()
    }

    // MARK: - Country lists

    /// Country codes of every country-sourced bulk list in either mode.
    var countryListCodes: Set<String> {
        var codes = Set<String>()
        for mode in [DestinationFilterMode.include, .exclude] {
            for g in ruleSet(for: mode).bulkGroups {
                if let code = g.countryCode { codes.insert(code) }
            }
        }
        return codes
    }

    /// Replaces the prefixes of every bulk list tagged `countryCode`, in both modes, keeping
    /// each list's id, title, enabled state and position. Returns how many lists changed.
    @discardableResult
    func refreshCountryLists(countryCode: String, plainText: String, now: Date = Date()) -> Int {
        var updated = 0
        for mode in [DestinationFilterMode.include, .exclude] {
            let set = ruleSet(for: mode)
            guard let next = Self.refreshingCountryLists(in: set, countryCode: countryCode, plainText: plainText, now: now) else {
                continue
            }
            updated += 1
            replaceRules(for: mode, customRules: next.customRules, bulkGroups: next.bulkGroups, domainRules: next.domainRules)
        }
        return updated
    }

    /// Pure form of `refreshCountryLists` for one rule set (also applied to stored profile
    /// snapshots). nil when the set has no list for `countryCode`. New prefixes are validated
    /// and deduplicated against the set's custom rules and its *other* bulk lists.
    static func refreshingCountryLists(
        in set: DestinationModeRuleSet, countryCode: String, plainText: String, now: Date
    ) -> DestinationModeRuleSet? {
        let indices = set.bulkGroups.indices.filter { set.bulkGroups[$0].countryCode == countryCode }
        guard !indices.isEmpty else { return nil }

        var taken = Set<String>()
        for r in set.customRules { taken.insert(r.cidr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        for (i, g) in set.bulkGroups.enumerated() where !indices.contains(i) {
            for c in g.cidrs { taken.insert(c) }
        }

        var fresh: [String] = []
        for trimmed in DestinationCidrTextParser.candidateStrings(from: plainText) {
            guard !taken.contains(trimmed), !IPCIDRMatcher.prepare([trimmed]).isEmpty else { continue }
            fresh.append(trimmed)
            taken.insert(trimmed)
        }

        var next = set
        // Several lists for one country in a mode is unusual; the first keeps the prefixes and
        // the rest become empty, which is what the duplicate check would have produced anyway.
        for (n, i) in indices.enumerated() {
            next.bulkGroups[i].cidrs = n == 0 ? fresh : []
            next.bulkGroups[i].refreshedAt = now
        }
        return next
    }

    func removeBulkGroup(id: UUID) {
        bulkGroups.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = customRules.firstIndex(where: { $0.id == id }) else { return }
        customRules[index].isEnabled = enabled
        save()
    }

    func setBulkGroupEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = bulkGroups.firstIndex(where: { $0.id == id }) else { return }
        bulkGroups[index].isEnabled = enabled
        save()
    }

    // Domain rules live in two stores (this global store + the per-profile routing snapshot),
    // and `replaceAll` runs on every connect/profile-load. Match the existing live rule by id OR
    // domain and UNION the resolved IPs from both copies so an accumulated set is never lost when
    // one source lags the other (never-remove). Without the union, applying a stale snapshot
    // would shrink the enforced set below what the UI shows — the "displayed ≠ enforced" bug.
    // Now applied per mode.
    func replaceAll(include: DestinationModeRuleSet, exclude: DestinationModeRuleSet) {
        var mergedInclude = include
        mergedInclude.domainRules = Self.mergedDomainRules(
            incoming: include.domainRules, existing: ruleSet(for: .include).domainRules
        )
        var mergedExclude = exclude
        mergedExclude.domainRules = Self.mergedDomainRules(
            incoming: exclude.domainRules, existing: ruleSet(for: .exclude).domainRules
        )
        let surfaced = editedMode == .include ? mergedInclude : mergedExclude
        offModeSet = editedMode == .include ? mergedExclude : mergedInclude
        customRules = surfaced.customRules
        bulkGroups = surfaced.bulkGroups
        domainRules = surfaced.domainRules
        save()
    }

    /// Replaces one mode's set verbatim (no domain merge). Test-URL and reset path.
    func replaceRules(
        for mode: DestinationFilterMode,
        customRules: [DestinationCidrRule],
        bulkGroups: [DestinationCidrBulkGroup],
        domainRules: [DestinationDomainRule]
    ) {
        if mode == editedMode {
            self.customRules = customRules
            self.bulkGroups = bulkGroups
            self.domainRules = domainRules
        } else {
            offModeSet = DestinationModeRuleSet(customRules: customRules, bulkGroups: bulkGroups, domainRules: domainRules)
        }
        save()
    }

    private static func mergedDomainRules(
        incoming: [DestinationDomainRule], existing: [DestinationDomainRule]
    ) -> [DestinationDomainRule] {
        incoming.map { incomingRule in
            guard let match = existing.first(where: { $0.id == incomingRule.id || $0.domain == incomingRule.domain }) else {
                return incomingRule
            }
            var merged = incomingRule
            var combined = match.resolvedCidrs
            for cidr in incomingRule.resolvedCidrs where !combined.contains(cidr) {
                combined.append(cidr)
            }
            merged.resolvedCidrs = combined
            merged.resolvedAt = match.resolvedAt ?? incomingRule.resolvedAt
            merged.resolvedTTL = match.resolvedTTL > 0 ? match.resolvedTTL : incomingRule.resolvedTTL
            merged.status = combined.isEmpty ? incomingRule.status : .resolved(cidrCount: combined.count)
            return merged
        }
    }

    func renameBulkGroup(id: UUID, title: String) {
        guard let index = bulkGroups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bulkGroups[index].title = trimmed
        save()
    }

    // MARK: - Domain rules

    /// Returns false if the domain is blank or already present.
    func addDomainRule(domain: String) -> Bool {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        guard !domainRules.contains(where: { $0.domain == trimmed }) else { return false }
        domainRules.append(DestinationDomainRule(domain: trimmed))
        save()
        return true
    }

    func removeAllDomainRules() {
        domainRules.removeAll()
        save()
    }

    func removeDomainRule(id: UUID) {
        domainRules.removeAll { $0.id == id }
        save()
    }

    func setDomainEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = domainRules.firstIndex(where: { $0.id == id }) else { return }
        domainRules[index].isEnabled = enabled
        save()
    }

    // MARK: - Resolution state mutators (ephemeral — no save())

    func markResolving(id: UUID) {
        guard let index = domainRules.firstIndex(where: { $0.id == id }) else { return }
        domainRules[index].status = .resolving
        objectWillChange.send()
    }

    /// Maximum number of resolved CIDR strings kept per domain rule (merge path only).
    /// Older entries (head of list) are dropped first; newest-added entries survive.
    func applyResolution(id: UUID, cidrs: [String], ttl: TimeInterval) {
        guard let index = domainRules.firstIndex(where: { $0.id == id }) else { return }
        var merged = domainRules[index].resolvedCidrs
        for cidr in cidrs where !merged.contains(cidr) {
            merged.append(cidr)
        }
        // Never evict: once an IP has resolved for a domain it stays in the enforced set for the
        // rest of the session, even as the domain rotates to new IPs. A still-cached connection to
        // an old IP keeps working, and reconnect re-applies the full accumulated set. The list may
        // grow large — that's an accepted trade-off for never silently dropping a still-reachable
        // destination. Only the explicit "Refresh resolved IPs" action (applyResolutionReplacing)
        // resets the set.
        domainRules[index].resolvedCidrs = merged
        domainRules[index].resolvedAt = Date()
        domainRules[index].resolvedTTL = ttl
        domainRules[index].status = .resolved(cidrCount: merged.count)
        save()  // persist so accumulated IPs survive app restarts (never-remove)
        objectWillChange.send()
    }

    /// Like `applyResolution` but replaces the stored CIDRs with the fresh result instead of merging.
    func applyResolutionReplacing(id: UUID, cidrs: [String], ttl: TimeInterval) {
        guard let index = domainRules.firstIndex(where: { $0.id == id }) else { return }
        domainRules[index].resolvedCidrs = cidrs
        domainRules[index].resolvedAt = Date()
        domainRules[index].resolvedTTL = ttl
        domainRules[index].status = .resolved(cidrCount: cidrs.count)
        save()
        objectWillChange.send()
    }

    func applyResolutionFailure(id: UUID, message: String) {
        guard let index = domainRules.firstIndex(where: { $0.id == id }) else { return }
        domainRules[index].status = .failed(message: message)
        objectWillChange.send()
    }

    func updateCidr(_ id: UUID, cidr: String) {
        guard let index = customRules.firstIndex(where: { $0.id == id }) else { return }
        let next = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        customRules[index].cidr = next
        save()
    }

    /// Labels for enabled **custom rules** (the CIDR string) and **bulk groups** (the list title) whose ranges contain `literal`.
    /// Sorted lexicographically for stable UI; non-IP literals yield no matches.
    func matchingDestinationListLabels(forLiteral literal: String) -> [String] {
        refreshPreparedCachesIfNeeded()
        var labels: [String] = []
        var seenCidr = Set<String>()
        for row in cachedCustomPrepared where IPCIDRMatcher.literalMatches(literal, ranges: row.ranges) {
            if seenCidr.insert(row.cidrDisplay).inserted {
                labels.append(row.cidrDisplay)
            }
        }
        var seenTitle = Set<String>()
        for row in cachedBulkPrepared where IPCIDRMatcher.literalMatches(literal, ranges: row.ranges) {
            if seenTitle.insert(row.title).inserted {
                labels.append(row.title)
            }
        }
        return labels.sorted()
    }

    private func refreshPreparedCachesIfNeeded() {
        if cachedRulesFingerprint != customRules {
            cachedRulesFingerprint = customRules
            cachedCustomPrepared = customRules
                .filter(\.isEnabled)
                .compactMap { rule -> (cidrDisplay: String, ranges: [IPCIDRMatcher.PreparedRange])? in
                    let trimmed = rule.cidr.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    let ranges = IPCIDRMatcher.prepare([trimmed])
                    guard !ranges.isEmpty else { return nil }
                    return (cidrDisplay: trimmed, ranges: ranges)
                }
        }
        if cachedBulkFingerprint != bulkGroups {
            cachedBulkFingerprint = bulkGroups
            cachedBulkPrepared = bulkGroups
                .filter(\.isEnabled)
                .map { group in
                    let cidrs = group.cidrs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    return (title: group.title, ranges: IPCIDRMatcher.prepare(cidrs))
                }
        }
    }

    /// Number of enabled, syntactically valid, deduplicated ranges for `mode` under `toggles`.
    /// Cached against the rule version and inputs; cheap to call from per-change refresh paths.
    func enabledValidCidrCount(for mode: DestinationFilterMode, toggles: DestinationSectionToggles) -> Int {
        if let cached = validCidrCountCache,
           cached.version == rulesVersion, cached.mode == mode, cached.toggles == toggles {
            return cached.count
        }
        validCidrCountComputations += 1
        let count = IPCIDRMatcher.prepare(enabledFlattenedCidrs(for: mode, toggles: toggles)).count
        validCidrCountCache = (rulesVersion, mode, toggles, count)
        return count
    }

    /// Enabled entries only — invalid CIDR syntax may be included (extension skips unparsable strings). Order-preserving dedupe.
    /// Section-enabled flags mirror the UI toggles persisted per mode.
    func enabledFlattenedCidrs(for mode: DestinationFilterMode, toggles: DestinationSectionToggles) -> [String] {
        let set = ruleSet(for: mode)
        var seen = Set<String>()
        var out: [String] = []
        func append(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { return }
            out.append(t)
        }
        if toggles.customRanges {
            for rule in set.customRules where rule.isEnabled { append(rule.cidr) }
        }
        if toggles.bulkLists {
            for group in set.bulkGroups where group.isEnabled {
                for c in group.cidrs { append(c) }
            }
        }
        if toggles.domainNames {
            // Include accumulated IPs regardless of transient status (never-remove).
            for rule in set.domainRules where rule.isEnabled {
                for cidr in rule.resolvedCidrs { append(cidr) }
            }
        }
        return out
    }

    /// Enabled domain rules' names (lowercased, deduped, order-preserving) for the proxy's SNI
    /// matcher. Unlike the resolved IPs in `enabledFlattenedCidrs`, these are the *names* — the
    /// proxy compares them against each TCP flow's TLS SNI to route by hostname.
    func enabledDomainNames(for mode: DestinationFilterMode, toggles: DestinationSectionToggles) -> [String] {
        guard toggles.domainNames else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for rule in ruleSet(for: mode).domainRules where rule.isEnabled {
            let name = rule.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    private func allExistingCidrsTrimmed() -> Set<String> {
        var s = Set<String>()
        for r in customRules {
            let t = r.cidr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { s.insert(t) }
        }
        for g in bulkGroups {
            for c in g.cidrs {
                let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { s.insert(t) }
            }
        }
        return s
    }

    private func save() {
        let payload = DestinationRulesByModePersisted(
            include: ruleSet(for: .include),
            exclude: ruleSet(for: .exclude)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let persisted = try? JSONDecoder().decode(DestinationRulesByModePersisted.self, from: data)
        else { return }
        // editedMode is .include at init.
        customRules = persisted.include.customRules
        bulkGroups = persisted.include.bulkGroups
        domainRules = persisted.include.domainRules
        offModeSet = persisted.exclude
    }
}

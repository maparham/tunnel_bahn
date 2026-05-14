import Foundation

struct DestinationCidrImportResult: Equatable {
    var added: Int
    var skippedInvalid: Int
    var skippedDuplicate: Int
}

private struct DestinationRoutingPersisted: Codable {
    var customRules: [DestinationCidrRule]
    var bulkGroups: [DestinationCidrBulkGroup]
    var domainRules: [DestinationDomainRule]

    enum CodingKeys: String, CodingKey {
        case customRules, bulkGroups, domainRules
    }

    init(customRules: [DestinationCidrRule], bulkGroups: [DestinationCidrBulkGroup], domainRules: [DestinationDomainRule]) {
        self.customRules = customRules
        self.bulkGroups = bulkGroups
        self.domainRules = domainRules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customRules = try c.decodeIfPresent([DestinationCidrRule].self, forKey: .customRules) ?? []
        bulkGroups = try c.decodeIfPresent([DestinationCidrBulkGroup].self, forKey: .bulkGroups) ?? []
        domainRules = try c.decodeIfPresent([DestinationDomainRule].self, forKey: .domainRules) ?? []
    }
}

@MainActor
final class DestinationRuleStore: ObservableObject {
    @Published private(set) var customRules: [DestinationCidrRule] = []
    @Published private(set) var bulkGroups: [DestinationCidrBulkGroup] = []
    @Published private(set) var domainRules: [DestinationDomainRule] = []

    private let defaultsKey = "destinationCidrRules"

    /// Prepared matchers invalidated when `customRules` / `bulkGroups` change — avoids re-preparing bulk CIDRs per stats refresh.
    private var cachedRulesFingerprint: [DestinationCidrRule]?
    private var cachedBulkFingerprint: [DestinationCidrBulkGroup]?
    private var cachedCustomPrepared: [(cidrDisplay: String, ranges: [IPCIDRMatcher.PreparedRange])] = []
    private var cachedBulkPrepared: [(title: String, ranges: [IPCIDRMatcher.PreparedRange])] = []

    init() {
        load()
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
    func importCidrLines(from plainText: String, bulkTitle: String) -> DestinationCidrImportResult {
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
            bulkGroups.append(DestinationCidrBulkGroup(title: title, cidrs: newCidrs))
            save()
        }

        return DestinationCidrImportResult(
            added: added,
            skippedInvalid: skippedInvalid,
            skippedDuplicate: skippedDuplicate
        )
    }

    func removeRule(ids: IndexSet) {
        customRules.remove(atOffsets: ids)
        save()
    }

    func removeRule(id: UUID) {
        customRules.removeAll { $0.id == id }
        save()
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

    func replaceAll(
        customRules newCustomRules: [DestinationCidrRule],
        bulkGroups newBulkGroups: [DestinationCidrBulkGroup],
        domainRules newDomainRules: [DestinationDomainRule] = []
    ) {
        customRules = newCustomRules
        bulkGroups = newBulkGroups
        // Carry over in-memory resolution state when domain IDs match.
        domainRules = newDomainRules.map { incoming in
            if let existing = domainRules.first(where: { $0.id == incoming.id }) {
                var merged = incoming
                merged.resolvedCidrs = existing.resolvedCidrs
                merged.resolvedAt = existing.resolvedAt
                merged.resolvedTTL = existing.resolvedTTL
                merged.status = existing.status
                return merged
            }
            return incoming
        }
        save()
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

    func applyResolution(id: UUID, cidrs: [String], ttl: TimeInterval) {
        guard let index = domainRules.firstIndex(where: { $0.id == id }) else { return }
        // Replace rather than union: stale IPs from previous resolutions (e.g. CDN rotation)
        // must not persist across TTL expiry cycles.
        domainRules[index].resolvedCidrs = cidrs
        domainRules[index].resolvedAt = Date()
        domainRules[index].resolvedTTL = ttl
        domainRules[index].status = .resolved(cidrCount: cidrs.count)
        objectWillChange.send()
    }

    func applyResolutionFailure(id: UUID, message: String) {
        guard let index = domainRules.firstIndex(where: { $0.id == id }) else { return }
        domainRules[index].resolvedCidrs = []
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

    /// Enabled entries only — invalid CIDR syntax may be included (extension skips unparsable strings). Order-preserving dedupe.
    /// Section-enabled flags mirror the UI toggles persisted in AppSettings.
    func enabledFlattenedCidrs(
        customRangesEnabled: Bool = true,
        bulkListsEnabled: Bool = true,
        domainNamesEnabled: Bool = true
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func append(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { return }
            out.append(t)
        }
        if customRangesEnabled {
            for rule in customRules where rule.isEnabled {
                append(rule.cidr)
            }
        }
        if bulkListsEnabled {
            for group in bulkGroups where group.isEnabled {
                for c in group.cidrs {
                    append(c)
                }
            }
        }
        if domainNamesEnabled {
            for rule in domainRules where rule.isEnabled {
                for cidr in rule.resolvedCidrs {
                    append(cidr)
                }
            }
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
        let payload = DestinationRoutingPersisted(customRules: customRules, bulkGroups: bulkGroups, domainRules: domainRules)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload) else { return }
        AppGroupStore.defaults.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = AppGroupStore.defaults.data(forKey: defaultsKey) else {
            return
        }
        let decoder = JSONDecoder()
        if let v2 = try? decoder.decode(DestinationRoutingPersisted.self, from: data) {
            customRules = v2.customRules
            bulkGroups = v2.bulkGroups
            domainRules = v2.domainRules
            return
        }
        if let legacy = try? decoder.decode([DestinationCidrRule].self, from: data) {
            let bulkThreshold = 150
            if legacy.count > bulkThreshold {
                let allEnabled = legacy.allSatisfy(\.isEnabled)
                let allDisabled = legacy.allSatisfy { !$0.isEnabled }
                if allEnabled || allDisabled {
                    let cidrs = legacy.map { $0.cidr.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    customRules = []
                    bulkGroups = [
                        DestinationCidrBulkGroup(
                            title: "Migrated list",
                            cidrs: cidrs,
                            isEnabled: allEnabled
                        ),
                    ]
                    save()
                    return
                }
            }
            customRules = legacy
            bulkGroups = []
            save()
            return
        }
    }
}

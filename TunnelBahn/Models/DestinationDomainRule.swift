import Foundation

enum DomainResolutionStatus: Equatable {
    case pending
    case resolving
    case resolved(cidrCount: Int)
    case failed(message: String)
}

struct DestinationDomainRule: Identifiable, Equatable {
    var id: UUID
    /// Lowercased, trimmed domain string as entered by the user, e.g. "x.com".
    var domain: String
    var isEnabled: Bool

    // Resolution state. `resolvedCidrs`/`resolvedAt`/`resolvedTTL` ARE persisted so accumulated IPs
    // survive app restarts (never-remove intent) and are enforced from the next connect without
    // waiting for a fresh resolution. `status` is ephemeral (recomputed on load from the persisted
    // CIDRs); the coordinator still re-resolves on launch/connect to refresh.
    var resolvedCidrs: [String] = []
    var resolvedAt: Date? = nil
    var resolvedTTL: TimeInterval = 0
    var status: DomainResolutionStatus = .pending

    init(id: UUID = UUID(), domain: String, isEnabled: Bool = true) {
        self.id = id
        self.domain = domain
        self.isEnabled = isEnabled
    }

    func isExpired(now: Date = Date()) -> Bool {
        guard let resolvedAt, resolvedTTL > 0 else { return true }
        return now.timeIntervalSince(resolvedAt) >= resolvedTTL
    }
}

extension DestinationDomainRule: Codable {
    enum CodingKeys: String, CodingKey {
        case id, domain, isEnabled, resolvedCidrs, resolvedAt, resolvedTTL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        domain = try c.decode(String.self, forKey: .domain)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        resolvedCidrs = try c.decodeIfPresent([String].self, forKey: .resolvedCidrs) ?? []
        resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        resolvedTTL = try c.decodeIfPresent(TimeInterval.self, forKey: .resolvedTTL) ?? 0
        // Reflect persisted IPs so they're shown as resolved and enforced immediately on launch,
        // while the coordinator re-resolves in the background to refresh/grow the set.
        status = resolvedCidrs.isEmpty ? .pending : .resolved(cidrCount: resolvedCidrs.count)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(domain, forKey: .domain)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(resolvedCidrs, forKey: .resolvedCidrs)
        try c.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try c.encode(resolvedTTL, forKey: .resolvedTTL)
    }
}

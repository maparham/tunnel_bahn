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

    // Resolution state — ephemeral, not persisted. Starts as .pending so coordinator re-resolves on launch.
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
        case id, domain, isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        domain = try c.decode(String.self, forKey: .domain)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(domain, forKey: .domain)
        try c.encode(isEnabled, forKey: .isEnabled)
    }
}

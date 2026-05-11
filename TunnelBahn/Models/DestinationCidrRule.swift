import Foundation

/// User-defined CIDR for destination-based transparent-proxy filtering (literal IPv4/IPv6 only in v1).
struct DestinationCidrRule: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    /// Example: `10.5.0.0/24` or `2001:db8::/32`
    var cidr: String
    var isEnabled: Bool

    init(id: UUID = UUID(), cidr: String, isEnabled: Bool = true) {
        self.id = id
        self.cidr = cidr
        self.isEnabled = isEnabled
    }
}

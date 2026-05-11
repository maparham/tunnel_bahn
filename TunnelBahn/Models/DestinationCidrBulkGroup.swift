import Foundation

/// Many CIDR prefixes imported as one unit (e.g. country zone file). Toggled and removed as a group.
struct DestinationCidrBulkGroup: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var title: String
    /// Trimmed, validated CIDR strings.
    var cidrs: [String]
    var isEnabled: Bool

    init(id: UUID = UUID(), title: String, cidrs: [String], isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.cidrs = cidrs
        self.isEnabled = isEnabled
    }
}

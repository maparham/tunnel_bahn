import Foundation

/// Many CIDR prefixes imported as one unit (e.g. country zone file). Toggled and removed as a group.
struct DestinationCidrBulkGroup: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var title: String
    /// Trimmed, validated CIDR strings.
    var cidrs: [String]
    var isEnabled: Bool
    /// ISO 3166-1 alpha-2 code when the list was downloaded via `CountryCidrListSource`; such
    /// lists can be refreshed in place. nil for file / pasted imports.
    var countryCode: String?
    /// When `cidrs` were last replaced by a country refresh (or first downloaded).
    var refreshedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        cidrs: [String],
        isEnabled: Bool = true,
        countryCode: String? = nil,
        refreshedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.cidrs = cidrs
        self.isEnabled = isEnabled
        self.countryCode = countryCode
        self.refreshedAt = refreshedAt
    }
}

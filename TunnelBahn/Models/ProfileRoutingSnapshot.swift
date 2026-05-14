import Foundation

struct ProfileRoutingSnapshot: Codable {
    var routingMode: AppSettings.RoutingMode
    var enforceDestinationFiltering: Bool
    var bulkListsEnabled: Bool
    var customRangesEnabled: Bool
    var domainNamesEnabled: Bool
    var appRules: [AppRule]
    var customCidrRules: [DestinationCidrRule]
    var bulkGroups: [DestinationCidrBulkGroup]
    var domainRules: [DestinationDomainRule]

    static var `default`: ProfileRoutingSnapshot {
        ProfileRoutingSnapshot(
            routingMode: .fullTunnel,
            enforceDestinationFiltering: false,
            bulkListsEnabled: true,
            customRangesEnabled: true,
            domainNamesEnabled: true,
            appRules: [],
            customCidrRules: [],
            bulkGroups: [],
            domainRules: []
        )
    }

    // Explicit decode so existing snapshots missing new fields default gracefully.
    enum CodingKeys: String, CodingKey {
        case routingMode, enforceDestinationFiltering
        case bulkListsEnabled, customRangesEnabled, domainNamesEnabled
        case appRules, customCidrRules, bulkGroups, domainRules
    }

    init(
        routingMode: AppSettings.RoutingMode,
        enforceDestinationFiltering: Bool,
        bulkListsEnabled: Bool,
        customRangesEnabled: Bool,
        domainNamesEnabled: Bool,
        appRules: [AppRule],
        customCidrRules: [DestinationCidrRule],
        bulkGroups: [DestinationCidrBulkGroup],
        domainRules: [DestinationDomainRule] = []
    ) {
        self.routingMode = routingMode
        self.enforceDestinationFiltering = enforceDestinationFiltering
        self.bulkListsEnabled = bulkListsEnabled
        self.customRangesEnabled = customRangesEnabled
        self.domainNamesEnabled = domainNamesEnabled
        self.appRules = appRules
        self.customCidrRules = customCidrRules
        self.bulkGroups = bulkGroups
        self.domainRules = domainRules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routingMode = try c.decode(AppSettings.RoutingMode.self, forKey: .routingMode)
        enforceDestinationFiltering = try c.decode(Bool.self, forKey: .enforceDestinationFiltering)
        bulkListsEnabled = try c.decodeIfPresent(Bool.self, forKey: .bulkListsEnabled) ?? true
        customRangesEnabled = try c.decodeIfPresent(Bool.self, forKey: .customRangesEnabled) ?? true
        domainNamesEnabled = try c.decodeIfPresent(Bool.self, forKey: .domainNamesEnabled) ?? true
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
        customCidrRules = try c.decodeIfPresent([DestinationCidrRule].self, forKey: .customCidrRules) ?? []
        bulkGroups = try c.decodeIfPresent([DestinationCidrBulkGroup].self, forKey: .bulkGroups) ?? []
        domainRules = try c.decodeIfPresent([DestinationDomainRule].self, forKey: .domainRules) ?? []
    }
}

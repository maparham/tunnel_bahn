import Foundation

struct ProfileRoutingSnapshot: Codable {
    var routingMode: RoutingMode
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

    init(
        routingMode: RoutingMode,
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
}

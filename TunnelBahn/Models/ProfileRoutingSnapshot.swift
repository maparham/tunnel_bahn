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
    var filterMode: DestinationFilterMode
    /// Profile-wide: suppress the tunnel-DNS redirect so routed apps resolve via the
    /// local resolver (better direct/domestic CDN steering; local DNS filtering applies).
    var resolveDNSLocally: Bool

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
        domainRules: [DestinationDomainRule] = [],
        filterMode: DestinationFilterMode = .include,
        resolveDNSLocally: Bool = false
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
        self.filterMode = filterMode
        self.resolveDNSLocally = resolveDNSLocally
    }
}

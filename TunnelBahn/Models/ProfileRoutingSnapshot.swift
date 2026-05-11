import Foundation

struct ProfileRoutingSnapshot: Codable {
    var routingMode: AppSettings.RoutingMode
    var enforceDestinationFiltering: Bool
    var appRules: [AppRule]
    var customCidrRules: [DestinationCidrRule]
    var bulkGroups: [DestinationCidrBulkGroup]

    static var `default`: ProfileRoutingSnapshot {
        ProfileRoutingSnapshot(
            routingMode: .fullTunnel,
            enforceDestinationFiltering: false,
            appRules: [],
            customCidrRules: [],
            bulkGroups: []
        )
    }
}

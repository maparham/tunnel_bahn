import Foundation

struct ProfileRoutingSnapshot: Codable {
    var routingMode: RoutingMode
    var enforceDestinationFiltering: Bool
    var appRules: [AppRule]
    /// "Tunnel only selected destinations" rule set.
    var include: DestinationModeRuleSet
    /// "Tunnel all except selected" rule set.
    var exclude: DestinationModeRuleSet
    var includeToggles: DestinationSectionToggles
    var excludeToggles: DestinationSectionToggles
    var filterMode: DestinationFilterMode
    /// Profile-wide: suppress the tunnel-DNS redirect so routed apps resolve via the
    /// local resolver (better direct/domestic CDN steering; local DNS filtering applies).
    var resolveDNSLocally: Bool

    static var `default`: ProfileRoutingSnapshot {
        ProfileRoutingSnapshot(
            routingMode: .fullTunnel,
            enforceDestinationFiltering: false,
            appRules: [],
            include: DestinationModeRuleSet(),
            exclude: DestinationModeRuleSet(),
            includeToggles: DestinationSectionToggles(),
            excludeToggles: DestinationSectionToggles(),
            filterMode: .include,
            resolveDNSLocally: false
        )
    }
}

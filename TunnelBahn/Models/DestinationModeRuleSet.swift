import Foundation

/// One filtering mode's complete destination rule set. Each `DestinationFilterMode`
/// (include / exclude) owns an independent instance; they never share entries.
struct DestinationModeRuleSet: Codable, Equatable {
    var customRules: [DestinationCidrRule] = []
    var bulkGroups: [DestinationCidrBulkGroup] = []
    var domainRules: [DestinationDomainRule] = []
}

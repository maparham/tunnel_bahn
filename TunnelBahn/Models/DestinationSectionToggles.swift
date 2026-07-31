import Foundation

/// Per-mode enable/disable state of the three destination sections in RoutingView.
/// Stored per `DestinationFilterMode` alongside that mode's rule set.
struct DestinationSectionToggles: Codable, Equatable {
    var bulkLists = true
    var customRanges = true
    var domainNames = true
}

import Foundation

/// Re-downloads country-sourced bulk lists and replaces their prefixes everywhere they occur:
/// the live rule store (both modes) and every stored profile snapshot. One download per country.
@MainActor
final class CountryCidrListRefresher: ObservableObject {
    /// Country codes with a download in flight.
    @Published private(set) var refreshing: Set<String> = []
    /// Last failure per country code; cleared on the next success.
    @Published private(set) var lastError: [String: String] = [:]

    private let ruleStore: DestinationRuleStore
    private let profileRoutingStore: ProfileRoutingStore
    private static let log = AppLog(subsystem: "com.tunnelbahn.mac", category: "CountryLists")

    init(ruleStore: DestinationRuleStore, profileRoutingStore: ProfileRoutingStore) {
        self.ruleStore = ruleStore
        self.profileRoutingStore = profileRoutingStore
    }

    /// Every country that has a list somewhere.
    var knownCountryCodes: Set<String> {
        ruleStore.countryListCodes.union(profileRoutingStore.countryListCodes)
    }

    /// Downloads and applies one country. Returns false (and records `lastError`) on failure.
    @discardableResult
    func refresh(countryCode: String) async -> Bool {
        guard !refreshing.contains(countryCode) else { return false }
        refreshing.insert(countryCode)
        defer { refreshing.remove(countryCode) }
        do {
            let text = try await CountryCidrListSource.fetchListText(forCountryCode: countryCode)
            apply(countryCode: countryCode, plainText: text)
            return true
        } catch {
            lastError[countryCode] = Self.describe(error)
            Self.log.warning("refresh \(countryCode) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Refreshes every known country, sequentially so a dead network fails fast once per list
    /// rather than opening dozens of hanging connections.
    func refreshAll() async {
        for code in knownCountryCodes.sorted() {
            await refresh(countryCode: code)
        }
    }

    /// Replaces the prefixes of every list tagged `countryCode` with the ones in `plainText`.
    func apply(countryCode: String, plainText: String) {
        let now = Date()
        let live = ruleStore.refreshCountryLists(countryCode: countryCode, plainText: plainText, now: now)
        profileRoutingStore.updateAll { snapshot in
            var changed = false
            if let next = DestinationRuleStore.refreshingCountryLists(
                in: snapshot.include, countryCode: countryCode, plainText: plainText, now: now
            ) { snapshot.include = next; changed = true }
            if let next = DestinationRuleStore.refreshingCountryLists(
                in: snapshot.exclude, countryCode: countryCode, plainText: plainText, now: now
            ) { snapshot.exclude = next; changed = true }
            return changed
        }
        lastError[countryCode] = nil
        Self.log.info("refreshed \(countryCode): \(live) live mode set(s) updated")
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "Could not reach GitHub (\(urlError.localizedDescription)). If GitHub is blocked where you are, connect the tunnel and try again."
        }
        return error.localizedDescription
    }
}

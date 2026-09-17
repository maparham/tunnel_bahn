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

    /// Every country that has a list somewhere. Both stores already drop codes that are not
    /// country codes, so nothing here can be turned into an arbitrary URL path.
    var knownCountryCodes: Set<String> {
        ruleStore.countryListCodes.union(profileRoutingStore.countryListCodes)
    }

    /// Downloads and applies one country. Returns false (and records `lastError`) on failure.
    /// A failed download leaves the stored list exactly as it was.
    @discardableResult
    func refresh(countryCode: String) async -> Bool {
        guard !refreshing.contains(countryCode) else { return false }
        refreshing.insert(countryCode)
        defer { refreshing.remove(countryCode) }
        do {
            let cidrs = try await CountryCidrListSource.fetchPrefixes(forCountryCode: countryCode)
            guard !Task.isCancelled else { return false }
            apply(countryCode: countryCode, cidrs: cidrs)
            return true
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            return false
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
            guard !Task.isCancelled else { return }
            await refresh(countryCode: code)
        }
    }

    /// Replaces the prefixes of every list tagged `countryCode`. `cidrs` must be non-empty and
    /// already validated; an empty array is refused so a refresh can never delete a list.
    func apply(countryCode: String, cidrs: [String]) {
        guard !cidrs.isEmpty else { return }
        let now = Date()
        let live = ruleStore.refreshCountryLists(countryCode: countryCode, cidrs: cidrs, now: now)
        profileRoutingStore.updateAll { snapshot in
            var changed = false
            if let next = DestinationRuleStore.refreshingCountryLists(
                in: snapshot.include, countryCode: countryCode, cidrs: cidrs, now: now
            ) { snapshot.include = next; changed = true }
            if let next = DestinationRuleStore.refreshingCountryLists(
                in: snapshot.exclude, countryCode: countryCode, cidrs: cidrs, now: now
            ) { snapshot.exclude = next; changed = true }
            return changed
        }
        lastError[countryCode] = nil
        Self.log.info("refreshed \(countryCode): \(cidrs.count) prefixes, \(live) live mode set(s) updated")
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "Could not reach GitHub (\(urlError.localizedDescription)). If GitHub is blocked where you are, connect the tunnel and try again."
        }
        return error.localizedDescription
    }
}

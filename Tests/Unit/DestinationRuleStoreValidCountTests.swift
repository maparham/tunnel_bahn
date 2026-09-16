import XCTest

/// `enabledValidCidrCount` feeds the menu bar summary, which is refreshed on every AppState
/// change. It must not re-parse the (possibly thousands of) bulk CIDRs unless the rules or the
/// section toggles actually changed.
@MainActor
final class DestinationRuleStoreValidCountTests: XCTestCase {
    private static let suiteName = "DestinationRuleStoreValidCountTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func makeStore() -> DestinationRuleStore {
        DestinationRuleStore(defaults: defaults)
    }

    func testCountsOnlyValidEnabledRanges() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        XCTAssertTrue(store.addRule(cidr: "not-a-cidr"))
        _ = store.importCidrLines(from: "1.1.1.0/24\n2.2.2.0/24\n1.1.1.0/24", bulkTitle: "list")

        let all = DestinationSectionToggles()
        XCTAssertEqual(store.enabledValidCidrCount(for: .include, toggles: all), 3)

        var noBulk = all
        noBulk.bulkLists = false
        XCTAssertEqual(store.enabledValidCidrCount(for: .include, toggles: noBulk), 1)

        XCTAssertEqual(store.enabledValidCidrCount(for: .exclude, toggles: all), 0)
    }

    func testRepeatedQueriesDoNotRecompute() {
        let store = makeStore()
        _ = store.importCidrLines(from: "1.1.1.0/24\n2.2.2.0/24", bulkTitle: "list")
        let toggles = DestinationSectionToggles()

        _ = store.enabledValidCidrCount(for: .include, toggles: toggles)
        let after = store.validCidrCountComputations
        for _ in 0..<10 {
            XCTAssertEqual(store.enabledValidCidrCount(for: .include, toggles: toggles), 2)
        }
        XCTAssertEqual(store.validCidrCountComputations, after, "same inputs must hit the cache")
    }

    func testRuleChangeInvalidatesCache() {
        let store = makeStore()
        let toggles = DestinationSectionToggles()
        XCTAssertEqual(store.enabledValidCidrCount(for: .include, toggles: toggles), 0)

        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        XCTAssertEqual(store.enabledValidCidrCount(for: .include, toggles: toggles), 1)

        let id = store.customRules[0].id
        store.setEnabled(false, for: id)
        XCTAssertEqual(store.enabledValidCidrCount(for: .include, toggles: toggles), 0)

        // Off-mode edits must invalidate too: the summary can ask for either mode.
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.addRule(cidr: "192.168.0.0/16"))
        store.setEditedMode(.include)
        XCTAssertEqual(store.enabledValidCidrCount(for: .exclude, toggles: toggles), 1)
        XCTAssertEqual(store.enabledValidCidrCount(for: .include, toggles: toggles), 0)
    }
}

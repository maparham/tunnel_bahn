import XCTest

@MainActor
final class CountryCidrRefreshTests: XCTestCase {
    private static let suiteName = "CountryCidrRefreshTests"
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

    func testOldPersistedGroupDecodesWithoutCountryFields() throws {
        let json = #"{"id":"6F9B2C6E-5C3A-4B8F-9A1D-2E4F6A8C0B1D","title":"old","cidrs":["10.0.0.0/8"],"isEnabled":true}"#
        let group = try JSONDecoder().decode(DestinationCidrBulkGroup.self, from: Data(json.utf8))
        XCTAssertNil(group.countryCode)
        XCTAssertNil(group.refreshedAt)
        XCTAssertEqual(group.cidrs, ["10.0.0.0/8"])
    }

    func testCountryImportTagsGroup() {
        let store = DestinationRuleStore(defaults: defaults)
        _ = store.importCidrLines(from: "# c\n1.0.0.0/24\n", bulkTitle: "Iran (IR)", countryCode: "IR")
        XCTAssertEqual(store.bulkGroups.first?.countryCode, "IR")
        XCTAssertNotNil(store.bulkGroups.first?.refreshedAt)
        XCTAssertEqual(store.countryListCodes, ["IR"])
    }

    /// A code that is not a country code must never be offered up for a URL, even if it was
    /// persisted (a restored backup carries whatever the file contained).
    func testHostileCountryCodeIsNotSurfacedForRefresh() {
        let store = DestinationRuleStore(defaults: defaults)
        _ = store.importCidrLines(
            from: "1.0.0.0/24", bulkTitle: "evil",
            countryCode: "../../../../attacker/repo/master/evil"
        )
        XCTAssertTrue(store.countryListCodes.isEmpty)
    }

    func testRefreshReplacesPrefixesKeepingIdentity() {
        let store = DestinationRuleStore(defaults: defaults)
        _ = store.importCidrLines(from: "1.0.0.0/24\n2.0.0.0/24", bulkTitle: "Iran (IR)", countryCode: "IR")
        let before = store.bulkGroups[0]
        store.setBulkGroupEnabled(false, for: before.id)
        store.renameBulkGroup(id: before.id, title: "My Iran")
        let then = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(store.refreshCountryLists(countryCode: "IR", cidrs: ["1.0.0.0/24", "3.0.0.0/24"], now: then), 1)

        let after = store.bulkGroups[0]
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.title, "My Iran")
        XCTAssertFalse(after.isEnabled)
        XCTAssertEqual(after.cidrs, ["1.0.0.0/24", "3.0.0.0/24"])
        XCTAssertEqual(after.refreshedAt, then)
    }

    /// The field failure: a block page answers HTTP 200, parses to nothing, and would otherwise
    /// replace thousands of curated prefixes with an empty list in every profile.
    func testEmptyRefreshIsRefusedAndLeavesTheListIntact() {
        let store = DestinationRuleStore(defaults: defaults)
        _ = store.importCidrLines(from: "1.0.0.0/24\n2.0.0.0/24", bulkTitle: "Iran (IR)", countryCode: "IR")
        let stamp = store.bulkGroups[0].refreshedAt

        XCTAssertEqual(store.refreshCountryLists(countryCode: "IR", cidrs: []), 0)

        XCTAssertEqual(store.bulkGroups[0].cidrs, ["1.0.0.0/24", "2.0.0.0/24"])
        XCTAssertEqual(store.bulkGroups[0].refreshedAt, stamp, "a refused refresh must not stamp a fresh date")

        var set = DestinationModeRuleSet()
        set.bulkGroups = [DestinationCidrBulkGroup(title: "Iran (IR)", cidrs: ["1.0.0.0/24"], countryCode: "IR")]
        XCTAssertNil(DestinationRuleStore.refreshingCountryLists(in: set, countryCode: "IR", cidrs: [], now: Date()))
    }

    /// Refresh stores the country's file as downloaded. Suppressing prefixes held by other
    /// lists made a list's contents depend on refresh order and could drop a range that had
    /// moved between two countries the user holds.
    func testRefreshKeepsPrefixesThatOtherListsAlsoHold() {
        let store = DestinationRuleStore(defaults: defaults)
        XCTAssertTrue(store.addRule(cidr: "5.0.0.0/8"))
        _ = store.importCidrLines(from: "9.9.9.0/24", bulkTitle: "other", countryCode: nil)
        _ = store.importCidrLines(from: "1.0.0.0/24", bulkTitle: "Iran (IR)", countryCode: "IR")

        XCTAssertEqual(store.refreshCountryLists(countryCode: "IR", cidrs: ["1.0.0.0/24", "5.0.0.0/8", "9.9.9.0/24"]), 1)

        XCTAssertEqual(store.bulkGroups[1].cidrs, ["1.0.0.0/24", "5.0.0.0/8", "9.9.9.0/24"])
        XCTAssertEqual(store.bulkGroups[0].cidrs, ["9.9.9.0/24"], "other lists are untouched")
        // The enforced set still contains each range once.
        let flattened = store.enabledFlattenedCidrs(for: .include, toggles: DestinationSectionToggles())
        XCTAssertEqual(flattened.count, Set(flattened).count)
    }

    func testRefreshTouchesBothModesAndIgnoresOtherCountries() {
        let store = DestinationRuleStore(defaults: defaults)
        _ = store.importCidrLines(from: "1.0.0.0/24", bulkTitle: "Iran (IR)", countryCode: "IR")
        _ = store.importCidrLines(from: "8.0.0.0/24", bulkTitle: "Germany (DE)", countryCode: "DE")
        store.setEditedMode(.exclude)
        _ = store.importCidrLines(from: "2.0.0.0/24", bulkTitle: "Iran (IR)", countryCode: "IR")
        store.setEditedMode(.include)

        XCTAssertEqual(store.refreshCountryLists(countryCode: "IR", cidrs: ["7.0.0.0/24"]), 2)
        XCTAssertEqual(store.ruleSet(for: .include).bulkGroups.map(\.cidrs), [["7.0.0.0/24"], ["8.0.0.0/24"]])
        XCTAssertEqual(store.ruleSet(for: .exclude).bulkGroups.map(\.cidrs), [["7.0.0.0/24"]])
        XCTAssertEqual(store.refreshCountryLists(countryCode: "FR", cidrs: ["7.0.0.0/24"]), 0)
    }

    func testSnapshotRefreshReturnsNilWithoutCountryList() {
        var set = DestinationModeRuleSet()
        set.bulkGroups = [DestinationCidrBulkGroup(title: "file", cidrs: ["1.0.0.0/24"])]
        XCTAssertNil(DestinationRuleStore.refreshingCountryLists(in: set, countryCode: "IR", cidrs: ["2.0.0.0/24"], now: Date()))
    }
}

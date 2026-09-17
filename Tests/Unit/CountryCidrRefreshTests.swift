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

    func testRefreshReplacesPrefixesKeepingIdentityAndDedupes() {
        let store = DestinationRuleStore(defaults: defaults)
        XCTAssertTrue(store.addRule(cidr: "5.0.0.0/8"))
        _ = store.importCidrLines(from: "9.9.9.0/24", bulkTitle: "other", countryCode: nil)
        _ = store.importCidrLines(from: "1.0.0.0/24\n2.0.0.0/24", bulkTitle: "Iran (IR)", countryCode: "IR")
        let before = store.bulkGroups[1]
        store.setBulkGroupEnabled(false, for: before.id)
        store.renameBulkGroup(id: before.id, title: "My Iran")
        let then = Date(timeIntervalSince1970: 1_000)

        let updated = store.refreshCountryLists(
            countryCode: "IR",
            plainText: "# fresh\n1.0.0.0/24\n3.0.0.0/24\n5.0.0.0/8\n9.9.9.0/24\nnot-a-cidr\n",
            now: then
        )

        XCTAssertEqual(updated, 1)
        let after = store.bulkGroups[1]
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.title, "My Iran")
        XCTAssertFalse(after.isEnabled)
        XCTAssertEqual(after.cidrs, ["1.0.0.0/24", "3.0.0.0/24"], "custom rule and other list's prefixes are skipped")
        XCTAssertEqual(after.refreshedAt, then)
        XCTAssertEqual(store.bulkGroups[0].cidrs, ["9.9.9.0/24"])
    }

    func testRefreshTouchesBothModesAndIgnoresOtherCountries() {
        let store = DestinationRuleStore(defaults: defaults)
        _ = store.importCidrLines(from: "1.0.0.0/24", bulkTitle: "Iran (IR)", countryCode: "IR")
        _ = store.importCidrLines(from: "8.0.0.0/24", bulkTitle: "Germany (DE)", countryCode: "DE")
        store.setEditedMode(.exclude)
        _ = store.importCidrLines(from: "2.0.0.0/24", bulkTitle: "Iran (IR)", countryCode: "IR")
        store.setEditedMode(.include)

        XCTAssertEqual(store.refreshCountryLists(countryCode: "IR", plainText: "7.0.0.0/24"), 2)
        XCTAssertEqual(store.ruleSet(for: .include).bulkGroups.map(\.cidrs), [["7.0.0.0/24"], ["8.0.0.0/24"]])
        XCTAssertEqual(store.ruleSet(for: .exclude).bulkGroups.map(\.cidrs), [["7.0.0.0/24"]])
        XCTAssertEqual(store.refreshCountryLists(countryCode: "FR", plainText: "7.0.0.0/24"), 0)
    }

    func testSnapshotRefreshReturnsNilWithoutCountryList() {
        var set = DestinationModeRuleSet()
        set.bulkGroups = [DestinationCidrBulkGroup(title: "file", cidrs: ["1.0.0.0/24"])]
        XCTAssertNil(DestinationRuleStore.refreshingCountryLists(in: set, countryCode: "IR", plainText: "2.0.0.0/24", now: Date()))
    }
}

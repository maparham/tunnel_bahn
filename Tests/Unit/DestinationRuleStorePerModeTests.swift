import XCTest

@MainActor
final class DestinationRuleStorePerModeTests: XCTestCase {
    private static let suiteName = "DestinationRuleStorePerModeTests"
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

    func testStoreStartsEmptyInIncludeMode() {
        let store = makeStore()
        XCTAssertEqual(store.editedMode, .include)
        XCTAssertTrue(store.customRules.isEmpty)
        XCTAssertTrue(store.bulkGroups.isEmpty)
        XCTAssertTrue(store.domainRules.isEmpty)
    }

    func testAddRuleIsScopedToEditedMode() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.customRules.isEmpty, "exclude set must not see include's rule")
        store.setEditedMode(.include)
        XCTAssertEqual(store.customRules.map(\.cidr), ["10.0.0.0/8"])
    }

    func testSameCidrAllowedInBothModes() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"), "dedup must be scoped per mode")
        XCTAssertFalse(store.addRule(cidr: "10.0.0.0/8"), "dedup still applies within a mode")
    }

    func testImportAndDomainScopedPerMode() {
        let store = makeStore()
        let result = store.importCidrLines(from: "1.1.1.0/24\n2.2.2.0/24", bulkTitle: "listA")
        XCTAssertEqual(result.added, 2)
        XCTAssertTrue(store.addDomainRule(domain: "x.com"))
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.bulkGroups.isEmpty)
        XCTAssertTrue(store.domainRules.isEmpty)
        let result2 = store.importCidrLines(from: "1.1.1.0/24", bulkTitle: "listB")
        XCTAssertEqual(result2.added, 1, "duplicate detection must not cross modes")
        XCTAssertTrue(store.addDomainRule(domain: "x.com"), "domain dedup must not cross modes")
    }

    func testPersistenceRoundTripsBothModes() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        store.setEditedMode(.exclude)
        _ = store.importCidrLines(from: "5.22.0.0/16", bulkTitle: "country-ir")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.editedMode, .include)
        XCTAssertEqual(reloaded.customRules.map(\.cidr), ["10.0.0.0/8"])
        reloaded.setEditedMode(.exclude)
        XCTAssertEqual(reloaded.bulkGroups.map(\.title), ["country-ir"])
        XCTAssertTrue(reloaded.customRules.isEmpty)
    }

    func testEnabledFlattenedCidrsReadsRequestedModeOnly() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.addRule(cidr: "5.22.0.0/16"))

        let toggles = DestinationSectionToggles()
        XCTAssertEqual(store.enabledFlattenedCidrs(for: .include, toggles: toggles), ["10.0.0.0/8"])
        XCTAssertEqual(store.enabledFlattenedCidrs(for: .exclude, toggles: toggles), ["5.22.0.0/16"])

        var noCustom = toggles
        noCustom.customRanges = false
        XCTAssertEqual(store.enabledFlattenedCidrs(for: .include, toggles: noCustom), [])
    }

    func testReplaceAllMergesDomainResolvedCidrsPerMode() {
        let store = makeStore()
        XCTAssertTrue(store.addDomainRule(domain: "x.com"))
        let id = store.domainRules[0].id
        store.applyResolution(id: id, cidrs: ["1.2.3.4/32"], ttl: 30)

        // Incoming snapshot copy of the same rule with a DIFFERENT resolved IP: union, never shrink.
        var incoming = DestinationModeRuleSet()
        var rule = DestinationDomainRule(id: id, domain: "x.com")
        rule.resolvedCidrs = ["5.6.7.8/32"]
        incoming.domainRules = [rule]
        store.replaceAll(include: incoming, exclude: DestinationModeRuleSet())

        XCTAssertEqual(Set(store.domainRules[0].resolvedCidrs), ["1.2.3.4/32", "5.6.7.8/32"])
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.domainRules.isEmpty)
    }

    func testReplaceRulesTargetsRequestedMode() {
        let store = makeStore()
        store.replaceRules(
            for: .exclude,
            customRules: [DestinationCidrRule(cidr: "5.22.0.0/16")],
            bulkGroups: [],
            domainRules: []
        )
        XCTAssertTrue(store.customRules.isEmpty, "include (edited) set untouched")
        store.setEditedMode(.exclude)
        XCTAssertEqual(store.customRules.map(\.cidr), ["5.22.0.0/16"])
    }
}

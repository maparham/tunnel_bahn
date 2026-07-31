import XCTest

final class ProfileRoutingSnapshotCodecTests: XCTestCase {
    func testDefaultSnapshotIsIncludeWithTunnelDNSAndEmptySets() {
        let s = ProfileRoutingSnapshot.default
        XCTAssertEqual(s.filterMode, .include)
        XCTAssertFalse(s.resolveDNSLocally)
        XCTAssertEqual(s.include, DestinationModeRuleSet())
        XCTAssertEqual(s.exclude, DestinationModeRuleSet())
        XCTAssertEqual(s.includeToggles, DestinationSectionToggles())
        XCTAssertEqual(s.excludeToggles, DestinationSectionToggles())
    }

    func testSnapshotRoundTripsBothModeSetsAndToggles() throws {
        var s = ProfileRoutingSnapshot.default
        s.filterMode = .exclude
        s.resolveDNSLocally = true
        s.include.customRules = [DestinationCidrRule(cidr: "10.66.0.0/16")]
        s.exclude.bulkGroups = [DestinationCidrBulkGroup(title: "country-ir", cidrs: ["5.22.0.0/16"])]
        s.exclude.domainRules = [DestinationDomainRule(domain: "digikala.com")]
        s.includeToggles.domainNames = false
        s.excludeToggles.bulkLists = false
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ProfileRoutingSnapshot.self, from: data)
        XCTAssertEqual(decoded.filterMode, .exclude)
        XCTAssertTrue(decoded.resolveDNSLocally)
        XCTAssertEqual(decoded.include, s.include)
        XCTAssertEqual(decoded.exclude, s.exclude)
        XCTAssertEqual(decoded.includeToggles, s.includeToggles)
        XCTAssertEqual(decoded.excludeToggles, s.excludeToggles)
    }
}

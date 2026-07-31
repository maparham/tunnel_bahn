import XCTest

final class ProfileRoutingSnapshotCodecTests: XCTestCase {
    func testDefaultSnapshotIsIncludeWithTunnelDNS() {
        let s = ProfileRoutingSnapshot.default
        XCTAssertEqual(s.filterMode, .include)
        XCTAssertFalse(s.localDNSForExcluded)
    }

    func testSnapshotRoundTripsExcludeAndLocalDNS() throws {
        var s = ProfileRoutingSnapshot.default
        s.filterMode = .exclude
        s.localDNSForExcluded = true
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ProfileRoutingSnapshot.self, from: data)
        XCTAssertEqual(decoded.filterMode, .exclude)
        XCTAssertTrue(decoded.localDNSForExcluded)
    }
}

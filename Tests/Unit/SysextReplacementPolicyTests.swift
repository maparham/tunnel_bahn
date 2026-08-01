import XCTest

/// Replacing a running system extension kills its live NE sessions (connected packet
/// tunnel dies, transparent proxy re-arms and blackholes all flows), so a same-bundle
/// relaunch must keep the running copy; any version or build change must redeploy.
final class SysextReplacementPolicyTests: XCTestCase {
    func testIdenticalVersionAndBuildKeepsRunningCopy() {
        XCTAssertFalse(SysextReplacementPolicy.shouldReplace(
            existingVersion: "1.2.0", existingBuild: "245",
            candidateVersion: "1.2.0", candidateBuild: "245"
        ))
    }

    func testNewerBuildSameVersionReplaces() {
        XCTAssertTrue(SysextReplacementPolicy.shouldReplace(
            existingVersion: "1.2.0", existingBuild: "245",
            candidateVersion: "1.2.0", candidateBuild: "246"
        ))
    }

    func testVersionChangeReplaces() {
        XCTAssertTrue(SysextReplacementPolicy.shouldReplace(
            existingVersion: "1.2.0", existingBuild: "245",
            candidateVersion: "1.3.0", candidateBuild: "245"
        ))
    }

    func testDowngradeStillReplaces() {
        XCTAssertTrue(SysextReplacementPolicy.shouldReplace(
            existingVersion: "1.2.0", existingBuild: "245",
            candidateVersion: "1.1.0", candidateBuild: "200"
        ))
    }
}

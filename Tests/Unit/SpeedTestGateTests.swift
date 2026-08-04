import XCTest

final class SpeedTestGateTests: XCTestCase {
    private func canRun(
        _ path: SpeedTestPath,
        isRunning: Bool = false,
        isConnected: Bool,
        helper: Bool,
        hostApp: Bool
    ) -> Bool {
        SpeedTestGate.canRun(
            path: path,
            isRunning: isRunning,
            isConnected: isConnected,
            helperInternetPathIsTunnel: helper,
            hostAppInternetPathIsTunnel: hostApp
        )
    }

    // MARK: - Tunnel card

    func testTunnelEnabledInFullTunnel() {
        XCTAssertTrue(canRun(.tunnel, isConnected: true, helper: true, hostApp: true))
    }

    /// The two paths are independent inputs: a direct host app (destination split, per-app mode)
    /// must not disable the tunnel card. Whether the helper is really tunneled is decided in
    /// VPNManager; this only asserts the gate does not conflate the two.
    func testTunnelEnabledWhileHostAppPathIsDirect() {
        XCTAssertTrue(canRun(.tunnel, isConnected: true, helper: true, hostApp: false))
    }

    /// Callers pass false when the helper cannot reach the measurement endpoints through the
    /// tunnel (narrowed utun routes, LAN-only profile, or no helper NEAppRule).
    func testTunnelDisabledWhenHelperPathIsNotTunnel() {
        XCTAssertFalse(canRun(.tunnel, isConnected: true, helper: false, hostApp: false))
    }

    func testTunnelDisabledWhenDisconnected() {
        XCTAssertFalse(canRun(.tunnel, isConnected: false, helper: false, hostApp: false))
    }

    // MARK: - Direct card

    func testDirectEnabledWhileDisconnected() {
        XCTAssertTrue(canRun(.direct, isConnected: false, helper: false, hostApp: false))
    }

    func testDirectEnabledWhenHostAppBypassesTunnel() {
        XCTAssertTrue(canRun(.direct, isConnected: true, helper: true, hostApp: false))
    }

    func testDirectDisabledUnderFullTunnel() {
        XCTAssertFalse(canRun(.direct, isConnected: true, helper: true, hostApp: true))
    }

    // MARK: - Run in flight

    func testBothCardsDisabledWhileRunning() {
        XCTAssertFalse(canRun(.tunnel, isRunning: true, isConnected: true, helper: true, hostApp: true))
        XCTAssertFalse(canRun(.direct, isRunning: true, isConnected: false, helper: false, hostApp: false))
    }
}

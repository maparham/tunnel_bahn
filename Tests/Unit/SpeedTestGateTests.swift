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

    /// App-tunnel with a destination filter: the host app stays direct, but the helper carries its
    /// own NEAppRule into a utun that still owns the default route, so the tunnel test is valid.
    func testTunnelEnabledWithDestinationSplitWhileHostAppIsDirect() {
        XCTAssertTrue(canRun(.tunnel, isConnected: true, helper: true, hostApp: false))
    }

    /// Narrowed utun routes (include-mode full-tunnel filter) or a LAN-only profile: the helper
    /// cannot reach the measurement endpoints through the tunnel.
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

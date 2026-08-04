import Foundation

/// Which path the app's own traffic took during a speed test run.
enum SpeedTestPath: String {
    case tunnel
    case direct
}

/// Decides which speed test card can run, given the current traffic-path shape.
/// Pure so the gate is testable without a live VPNManager.
enum SpeedTestGate {
    /// - Parameters:
    ///   - isRunning: a run is already in flight (either card).
    ///   - isConnected: tunnel state is `.connected`.
    ///   - helperInternetPathIsTunnel: the bundled helper's internet traffic traverses the tunnel.
    ///     True whenever the connected profile has a default route and the utun keeps it; the helper
    ///     always carries its own NEAppRule in app-tunnel shapes, so a destination filter that only
    ///     narrows *other* apps does not disqualify it.
    ///   - hostAppInternetPathIsTunnel: TunnelBahn's own (in-process) internet traffic is tunneled.
    static func canRun(
        path: SpeedTestPath,
        isRunning: Bool,
        isConnected: Bool,
        helperInternetPathIsTunnel: Bool,
        hostAppInternetPathIsTunnel: Bool
    ) -> Bool {
        guard !isRunning else { return false }
        switch path {
        case .tunnel:
            return isConnected && helperInternetPathIsTunnel
        case .direct:
            return !isConnected || !hostAppInternetPathIsTunnel
        }
    }
}

/// One point of the throughput-over-time curve captured during a download or upload phase.
struct ThroughputSample: Equatable, Codable {
    /// Seconds since the phase started.
    let offsetSeconds: Double
    let mbps: Double
}

/// Finished speed test run. In-memory only; the latest run per path is kept for the session.
struct SpeedTestResult {
    let path: SpeedTestPath
    /// Connected profile name when `path == .tunnel`; nil for direct runs.
    let profileName: String?
    let downloadMbps: Double
    let uploadMbps: Double
    let medianLatencyMs: Double
    let jitterMs: Double
    let finishedAt: Date
    let downloadSamples: [ThroughputSample]
    let uploadSamples: [ThroughputSample]
}

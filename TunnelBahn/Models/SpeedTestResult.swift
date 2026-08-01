import Foundation

/// Which path the app's own traffic took during a speed test run.
enum SpeedTestPath: String {
    case tunnel
    case direct
}

/// One point of the throughput-over-time curve captured during a download or upload phase.
struct ThroughputSample: Equatable {
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

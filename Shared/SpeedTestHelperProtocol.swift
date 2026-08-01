import Foundation

/// Constants shared by the host app and the bundled speed test helper.
enum SpeedTestHelperConstants {
    /// Executable name inside TunnelBahn.app/Contents/MacOS.
    static let executableName = "SpeedTestHelper"
    /// Code signing identifier used for the helper's NEAppRule.
    static let signingIdentifier = "com.tunnelbahn.mac.speedtesthelper"
}

/// Measurement phases in run order; raw values are the NDJSON wire names.
enum SpeedTestPhaseName: String, Codable {
    case latency, download, upload
}

/// Where the active connection routes app-initiated internet traffic. Raw values are the
/// helper CLI names and the `APPSPLIT_PROBE` log field.
enum TunnelProbePhase: String {
    /// Everything tunnels (default-route profile without per-app selection).
    case fullTunnel = "full_tunnel"
    /// Per-app tunnel; only NEAppRule-listed processes (including the helper) tunnel.
    case appTunnel = "app_tunnel"
}

/// Final measurement payload of one full run. Path-agnostic; the host wraps it
/// into a SpeedTestResult with path and profile name.
struct SpeedTestRunPayload: Codable, Equatable {
    var downloadMbps: Double
    var uploadMbps: Double
    var medianLatencyMs: Double
    var jitterMs: Double
    var downloadSamples: [ThroughputSample]
    var uploadSamples: [ThroughputSample]
}

/// One NDJSON line on the helper's stdout. `event` selects which optional fields are set:
/// "phase" -> phase; "sample" -> readout (plus offsetSeconds/bytes during transfer phases);
/// "latency_summary" -> medianLatencyMs + jitterMs;
/// "result" -> result (helper then exits 0); "error" -> message (helper then exits nonzero).
struct SpeedTestHelperLine: Codable, Equatable {
    var event: String
    var phase: SpeedTestPhaseName? = nil
    var readout: String? = nil
    var offsetSeconds: Double? = nil
    var bytes: Int? = nil
    var medianLatencyMs: Double? = nil
    var jitterMs: Double? = nil
    var result: SpeedTestRunPayload? = nil
    var message: String? = nil
}

extension SpeedTestHelperLine {
    static func decode(_ line: String) -> SpeedTestHelperLine? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SpeedTestHelperLine.self, from: data)
    }

    func encodedLine() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Single JSON object printed by `SpeedTestHelper probe`.
struct SpeedTestHelperProbeOutcome: Codable, Equatable {
    var ok: Bool
    var message: String? = nil
}

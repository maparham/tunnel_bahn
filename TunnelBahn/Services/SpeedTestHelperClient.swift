import Foundation

enum SpeedTestHelperClientError: LocalizedError, Equatable {
    case helperMissing
    case malformedLine(String)
    case helperReported(String)
    case exitedWithoutResult

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            "speed test helper is missing from the app bundle"
        case .malformedLine(let line):
            "unexpected output from the speed test helper: \(line)"
        case .helperReported(let message):
            message
        case .exitedWithoutResult:
            "the speed test helper exited before producing a result"
        }
    }
}

/// Launches the bundled SpeedTestHelper and turns its NDJSON stdout into typed events.
/// The helper's traffic is tunneled by its own NEAppRule in app-tunnel mode, so a run
/// through this client measures the tunnel path regardless of the host app's own path.
final class SpeedTestHelperClient: Sendable {
    static func helperURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/\(SpeedTestHelperConstants.executableName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Pure reducer over one stdout line: emits progress events, returns the payload when the
    /// result line arrives, throws on error/malformed/unknown lines. IO-free for unit testing.
    static func reduce(line: String, onEvent: (SpeedTestEngineEvent) -> Void) throws -> SpeedTestRunPayload? {
        guard let decoded = SpeedTestHelperLine.decode(line) else {
            throw SpeedTestHelperClientError.malformedLine(String(line.prefix(200)))
        }
        switch decoded.event {
        case "phase":
            guard let phase = decoded.phase else {
                throw SpeedTestHelperClientError.malformedLine(String(line.prefix(200)))
            }
            onEvent(.phase(phase))
            return nil
        case "sample":
            guard let readout = decoded.readout else {
                throw SpeedTestHelperClientError.malformedLine(String(line.prefix(200)))
            }
            onEvent(.sample(readout: readout, offsetSeconds: decoded.offsetSeconds, bytes: decoded.bytes))
            return nil
        case "latency_summary":
            guard let median = decoded.medianLatencyMs, let jitter = decoded.jitterMs else {
                throw SpeedTestHelperClientError.malformedLine(String(line.prefix(200)))
            }
            onEvent(.latencySummary(medianMs: median, jitterMs: jitter))
            return nil
        case "exit_ip":
            guard let ip = decoded.exitIP else {
                throw SpeedTestHelperClientError.malformedLine(String(line.prefix(200)))
            }
            onEvent(.exitIP(ip: ip, location: decoded.exitLocation))
            return nil
        case "result":
            guard let payload = decoded.result else {
                throw SpeedTestHelperClientError.malformedLine(String(line.prefix(200)))
            }
            return payload
        case "error":
            throw SpeedTestHelperClientError.helperReported(decoded.message ?? "helper reported an unknown error")
        default:
            throw SpeedTestHelperClientError.malformedLine(String(line.prefix(200)))
        }
    }

    /// Runs a connectivity probe in the helper (whose traffic is tunneled in app-tunnel mode).
    /// Any launch or protocol failure maps to `.failed` so VPNManager surfaces it like a probe miss.
    static func probe(mode: String, phase: TunnelProbePhase) async -> ConnectivityProbeResult {
        guard let url = helperURL() else {
            return .failed("speed test helper is missing from the app bundle")
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["probe", "--mode", mode, "--phase", phase.rawValue]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed("could not launch the probe helper: \(error.localizedDescription)")
        }
        var lastLine: String?
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                lastLine = line
            }
        } catch {
            return .failed("probe helper output unreadable: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard let lastLine,
              let data = lastLine.data(using: .utf8),
              let outcome = try? JSONDecoder().decode(SpeedTestHelperProbeOutcome.self, from: data)
        else {
            return .failed("probe helper produced no result")
        }
        return outcome.ok ? .ok : .failed(outcome.message ?? "No internet response via tunnel (endpoint may be unreachable)")
    }

    /// Runs a full speed test in the helper. Cancellation terminates the helper process.
    func run(onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void) async throws -> SpeedTestRunPayload {
        guard let url = Self.helperURL() else { throw SpeedTestHelperClientError.helperMissing }
        let process = Process()
        process.executableURL = url
        process.arguments = ["run"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        return try await withTaskCancellationHandler {
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    try Task.checkCancellation()
                    if let payload = try Self.reduce(line: line, onEvent: onEvent) {
                        return payload
                    }
                }
                try Task.checkCancellation()
                throw SpeedTestHelperClientError.exitedWithoutResult
            } catch {
                if process.isRunning { process.terminate() }
                throw error
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

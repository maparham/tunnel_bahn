import Foundation
import Security

/// Counts payload bytes across all tasks of one URLSession. Download phases count received
/// body bytes (didReceive), upload phases count sent body bytes (didSendBodyData). Delegate
/// callbacks arrive on the session's queue; the lock makes the running total readable from
/// the main actor's sampler loop.
private final class ByteCountingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes = 0
    /// Replacement factory. While non-nil, a task that finishes before the window closes is
    /// immediately replaced by a fresh one, keeping the streams saturated for the whole window.
    /// Cleared by `stopStreams` so tasks cancelled at window close cannot spawn replacements.
    private var _restart: (() -> URLSessionTask)?
    /// Tasks still in flight (originals plus replacements), so `stopStreams` can cancel them all.
    private var _liveTasks: [URLSessionTask] = []
    /// First non-2xx status seen. A rejected request means the counted bytes are error-page
    /// bodies, not payload, so the phase must fail loudly instead of reporting a bogus rate.
    private var _httpErrorStatus: Int?

    var bytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _bytes
    }

    var httpErrorStatus: Int? {
        lock.lock()
        defer { lock.unlock() }
        return _httpErrorStatus
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        if (200..<300).contains(code) {
            completionHandler(.allow)
            return
        }
        lock.lock()
        _httpErrorStatus = code
        _restart = nil
        lock.unlock()
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        _bytes += data.count
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        lock.lock()
        _bytes += Int(bytesSent)
        lock.unlock()
    }

    /// Enables restarts and launches `count` initial streams from `make`. `resume()` runs outside
    /// the lock: completion callbacks re-enter the delegate on its queue, so holding the lock
    /// across `resume()` would deadlock.
    func startStreams(count: Int, make: @escaping () -> URLSessionTask) {
        lock.lock()
        _restart = make
        var started: [URLSessionTask] = []
        for _ in 0..<count {
            let task = make()
            _liveTasks.append(task)
            started.append(task)
        }
        lock.unlock()
        started.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        _liveTasks.removeAll { $0 === task }
        guard let make = _restart else {
            lock.unlock()
            return
        }
        let replacement = make()
        _liveTasks.append(replacement)
        lock.unlock()
        replacement.resume()
    }

    /// Ends the window. Disables restarts first so the cancellations below cannot spawn
    /// replacements, then cancels every outstanding task.
    func stopStreams() {
        lock.lock()
        _restart = nil
        let live = _liveTasks
        _liveTasks.removeAll()
        lock.unlock()
        live.forEach { $0.cancel() }
    }
}

/// Progress events emitted while a run is in progress. Readouts are preformatted here
/// ("312 Mbps" / "24 ms") so host and helper display identical strings.
enum SpeedTestEngineEvent: Equatable {
    case phase(SpeedTestPhaseName)
    case sample(readout: String, offsetSeconds: Double?, bytes: Int?)
}

struct SpeedTestEngineError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Full-suite speed test (latency, jitter, download, upload) against Cloudflare's speed-test
/// endpoints, measuring whatever path the calling process's traffic takes. Compiled into both
/// the host app (Direct card) and the SpeedTestHelper executable (Tunnel card).
final class SpeedTestEngine: @unchecked Sendable {
    private static let latencyURL = URL(string: "https://speed.cloudflare.com/__down?bytes=0")!
    /// Cloudflare rejects `bytes` requests at or above 100 MB with HTTP 403; 50 MB is safely
    /// inside the cap, and the restart loop keeps streams saturated regardless of request size.
    private static let downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=50000000")!
    private static let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!
    private static let latencyAttempts = 9 // first discarded as connection warmup
    private static let minLatencySuccesses = 5
    private static let downloadStreams = 4
    private static let uploadStreams = 2
    private static let windowSeconds = 8.0
    private static let sampleIntervalSeconds = 0.25
    private static let uploadBodyBytes = 48 * 1024 * 1024

    func run(onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void) async throws -> SpeedTestRunPayload {
        onEvent(.phase(.latency))
        let latency = try await measureLatency(onEvent: onEvent)
        onEvent(.phase(.download))
        let download = try await measureTransferWindow(kind: .download, onEvent: onEvent)
        onEvent(.phase(.upload))
        let upload = try await measureTransferWindow(kind: .upload, onEvent: onEvent)
        return SpeedTestRunPayload(
            downloadMbps: download.mbps,
            uploadMbps: upload.mbps,
            medianLatencyMs: latency.median,
            jitterMs: latency.jitter,
            downloadSamples: download.samples,
            uploadSamples: upload.samples
        )
    }

    /// Dedicated per-phase session: ephemeral (no cache, no cookies) so cached responses can
    /// never inflate numbers, and invalidated after each phase so cancelled tasks are torn down.
    private static func makeSession(delegate: URLSessionDataDelegate?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func measureLatency(onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void) async throws -> (median: Double, jitter: Double) {
        let session = Self.makeSession(delegate: nil)
        defer { session.invalidateAndCancel() }
        var samplesMs: [Double] = []
        var lastError: Error?
        for attempt in 1...Self.latencyAttempts {
            try Task.checkCancellation()
            let t0 = Date()
            do {
                var request = URLRequest(url: Self.latencyURL)
                request.timeoutInterval = 5
                _ = try await session.data(for: request)
                let elapsedMs = Date().timeIntervalSince(t0) * 1000
                // First request pays TLS + connection setup; discard it as warmup.
                if attempt > 1 {
                    samplesMs.append(elapsedMs)
                    onEvent(.sample(readout: "\(Int(elapsedMs)) ms", offsetSeconds: nil, bytes: nil))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Task cancellation surfaces here as URLError(.cancelled), not CancellationError;
                // map it back so an auto-cancel does not exit via the "probes failed" path below.
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        try Task.checkCancellation()
        guard samplesMs.count >= Self.minLatencySuccesses,
              let median = SpeedTestMath.median(samplesMs),
              let jitter = SpeedTestMath.jitter(samplesMs) else {
            throw SpeedTestEngineError(lastError?.localizedDescription ?? "latency probes failed")
        }
        return (median, jitter)
    }

    private enum TransferKind {
        case download, upload
    }

    /// Runs parallel transfer streams for a fixed window, sampling the cumulative byte count
    /// every `sampleIntervalSeconds`. Each fixed-size transfer that finishes before the window
    /// closes is immediately restarted so the streams stay saturated for the full window;
    /// outstanding tasks are cancelled at window end. Throughput is bytes-in-window over elapsed
    /// wall clock.
    private func measureTransferWindow(kind: TransferKind, onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void) async throws -> (mbps: Double, samples: [ThroughputSample]) {
        let delegate = ByteCountingSessionDelegate()
        let session = Self.makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }

        let streamCount: Int
        let make: () -> URLSessionTask
        switch kind {
        case .download:
            streamCount = Self.downloadStreams
            let request = URLRequest(url: Self.downloadURL)
            make = { session.dataTask(with: request) }
        case .upload:
            // Random-ish body: a 4 MiB random block repeated. Cheap to build, incompressible
            // enough that transparent compression cannot inflate the measured rate.
            var block = Data(count: 4 * 1024 * 1024)
            block.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
            }
            var body = Data(capacity: Self.uploadBodyBytes)
            while body.count < Self.uploadBodyBytes { body.append(block) }
            var request = URLRequest(url: Self.uploadURL)
            request.httpMethod = "POST"
            streamCount = Self.uploadStreams
            // The body is immutable and shared, so every restart reuses it with no extra memory.
            make = { session.uploadTask(with: request, from: body) }
        }
        delegate.startStreams(count: streamCount, make: make)

        let start = Date()
        var cumulative: [(offsetSeconds: Double, bytes: Int)] = []
        do {
            while Date().timeIntervalSince(start) < Self.windowSeconds {
                try await Task.sleep(nanoseconds: UInt64(Self.sampleIntervalSeconds * 1_000_000_000))
                let offset = Date().timeIntervalSince(start)
                cumulative.append((offsetSeconds: offset, bytes: delegate.bytes))
                let mbps = SpeedTestMath.throughputMbps(bytes: delegate.bytes, seconds: offset)
                onEvent(.sample(readout: "\(Int(mbps)) Mbps", offsetSeconds: offset, bytes: delegate.bytes))
            }
        } catch is CancellationError {
            delegate.stopStreams()
            throw CancellationError()
        }
        delegate.stopStreams()

        let elapsed = Date().timeIntervalSince(start)
        let totalBytes = delegate.bytes
        if let code = delegate.httpErrorStatus {
            throw SpeedTestEngineError("server rejected the request (HTTP \(code))")
        }
        guard totalBytes > 0 else {
            throw SpeedTestEngineError(kind == .download ? "no data received" : "no data sent")
        }
        return (
            mbps: SpeedTestMath.throughputMbps(bytes: totalBytes, seconds: elapsed),
            samples: SpeedTestMath.throughputSeries(cumulative: cumulative)
        )
    }
}

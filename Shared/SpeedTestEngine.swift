import Foundation
import Security

/// Counts credited payload bytes across all tasks of one URLSession. Download phases count
/// received body bytes (didReceive). Upload phases credit a request's full body size only
/// when the request completes cleanly: a POST completes once the server has read the whole
/// body, so completion is server acknowledgment. Counting didSendBodyData instead would
/// measure how fast bytes enter local socket or tunnel buffers, which over TunnelBahn's own
/// userspace relay inflates upload rates by orders of magnitude. Delegate callbacks arrive
/// on the session's queue; the lock makes the running total readable from the sampler loop.
private final class ByteCountingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Accounting {
        /// Credit bytes as they arrive from the server (download).
        case receivedBytes
        /// Credit a request's body size when the request completes cleanly (upload).
        case completedBodies
    }

    private let accounting: Accounting
    private let lock = NSLock()
    private var _bytes = 0
    /// Replacement factory. While non-nil, a task that finishes before the window closes is
    /// immediately replaced by a fresh one, keeping the streams saturated for the whole window.
    /// The argument is the completed task's body size (nil for initial streams) so upload
    /// replacements can climb the size ladder. Cleared by `stopStreams` so tasks cancelled at
    /// window close cannot spawn replacements.
    private var _restart: ((Int?) -> (task: URLSessionTask, bodyBytes: Int))?
    /// Tasks still in flight (originals plus replacements), so `stopStreams` can cancel them all.
    private var _liveTasks: [URLSessionTask] = []
    /// Body size per in-flight task, for completion crediting and ladder progression.
    private var _taskBodyBytes: [Int: Int] = [:]
    /// First non-2xx status seen. A rejected request means the transferred bytes are error-page
    /// traffic, not payload, so the phase must fail loudly instead of reporting a bogus rate.
    private var _httpErrorStatus: Int?

    init(accounting: Accounting) {
        self.accounting = accounting
    }

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
        guard accounting == .receivedBytes else { return }
        lock.lock()
        _bytes += data.count
        lock.unlock()
    }

    /// Enables restarts and launches `count` initial streams from `make`. `resume()` runs outside
    /// the lock: completion callbacks re-enter the delegate on its queue, so holding the lock
    /// across `resume()` would deadlock.
    func startStreams(count: Int, make: @escaping (Int?) -> (task: URLSessionTask, bodyBytes: Int)) {
        lock.lock()
        _restart = make
        var started: [URLSessionTask] = []
        for _ in 0..<count {
            let (task, bodyBytes) = make(nil)
            _liveTasks.append(task)
            _taskBodyBytes[task.taskIdentifier] = bodyBytes
            started.append(task)
        }
        lock.unlock()
        started.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        _liveTasks.removeAll { $0 === task }
        let completedBodyBytes = _taskBodyBytes.removeValue(forKey: task.taskIdentifier)
        // A clean completion means the server consumed the whole request; a cancelled or
        // failed task earns no credit (its bytes never provably left the local buffers).
        if accounting == .completedBodies, error == nil, _httpErrorStatus == nil,
           let credited = completedBodyBytes {
            _bytes += credited
        }
        guard let make = _restart else {
            lock.unlock()
            return
        }
        let (replacement, bodyBytes) = make(completedBodyBytes)
        _liveTasks.append(replacement)
        _taskBodyBytes[replacement.taskIdentifier] = bodyBytes
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
    /// Emitted once, after the latency phase completes, so the UI can show the
    /// settled median and jitter while the transfer phases run.
    case latencySummary(medianMs: Double, jitterMs: Double)
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
    private static let sampleIntervalSeconds = 0.25

    /// Upload body size ladder. Uploads only earn credit at request completion, so bodies
    /// start small enough that slow paths complete several per window and grow so fast paths
    /// are not request-rate bound. The cap also bounds the prebuilt body's memory footprint.
    private static let uploadBodyLadder = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024]

    static var initialUploadBodyBytes: Int { uploadBodyLadder[0] }

    /// Next rung above the completed size; stays at the cap once reached.
    static func nextUploadBodyBytes(after completed: Int) -> Int {
        uploadBodyLadder.first(where: { $0 > completed }) ?? uploadBodyLadder[uploadBodyLadder.count - 1]
    }

    /// High-RTT paths spend several seconds of the window in TCP slow start, which drags the
    /// whole-window average well below the link's steady rate; a longer window dilutes the ramp.
    static func transferWindowSeconds(forMedianLatencyMs medianLatencyMs: Double) -> Double {
        medianLatencyMs >= 400 ? 16.0 : 8.0
    }

    func run(onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void) async throws -> SpeedTestRunPayload {
        onEvent(.phase(.latency))
        let latency = try await measureLatency(onEvent: onEvent)
        onEvent(.latencySummary(medianMs: latency.median, jitterMs: latency.jitter))
        let windowSeconds = Self.transferWindowSeconds(forMedianLatencyMs: latency.median)
        onEvent(.phase(.download))
        let download = try await measureTransferWindow(kind: .download, windowSeconds: windowSeconds, onEvent: onEvent)
        onEvent(.phase(.upload))
        let upload = try await measureTransferWindow(kind: .upload, windowSeconds: windowSeconds, onEvent: onEvent)
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

    /// Runs parallel transfer streams for a fixed window, sampling the credited byte count
    /// every `sampleIntervalSeconds`. Each transfer that finishes before the window closes is
    /// immediately restarted (uploads with the next ladder size) so the streams stay busy for
    /// the whole window; outstanding tasks are cancelled at window end. Throughput is credited
    /// bytes-in-window over elapsed wall clock. Upload credit lands at request completion, so
    /// its sample series is stepped rather than smooth, and a request still in flight at window
    /// end earns nothing; the ladder keeps that truncation small relative to the window total.
    private func measureTransferWindow(
        kind: TransferKind,
        windowSeconds: Double,
        onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void
    ) async throws -> (mbps: Double, samples: [ThroughputSample]) {
        let delegate: ByteCountingSessionDelegate
        let session: URLSession
        let streamCount: Int
        let make: (Int?) -> (task: URLSessionTask, bodyBytes: Int)
        switch kind {
        case .download:
            delegate = ByteCountingSessionDelegate(accounting: .receivedBytes)
            session = Self.makeSession(delegate: delegate)
            streamCount = Self.downloadStreams
            let request = URLRequest(url: Self.downloadURL)
            make = { _ in (session.dataTask(with: request), 0) }
        case .upload:
            delegate = ByteCountingSessionDelegate(accounting: .completedBodies)
            session = Self.makeSession(delegate: delegate)
            streamCount = Self.uploadStreams
            // Random-ish body at the ladder cap: a 4 MiB random block repeated. Cheap to build,
            // incompressible enough that transparent compression cannot inflate the measured
            // rate. Smaller rungs upload a prefix, so one buffer serves every size.
            let capBytes = Self.uploadBodyLadder[Self.uploadBodyLadder.count - 1]
            var block = Data(count: 4 * 1024 * 1024)
            block.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
            }
            var body = Data(capacity: capBytes)
            while body.count < capBytes { body.append(block) }
            let fullBody = body
            var request = URLRequest(url: Self.uploadURL)
            request.httpMethod = "POST"
            make = { completedBytes in
                let size = completedBytes.map { Self.nextUploadBodyBytes(after: $0) }
                    ?? Self.initialUploadBodyBytes
                return (session.uploadTask(with: request, from: fullBody.prefix(size)), size)
            }
        }
        defer { session.invalidateAndCancel() }
        delegate.startStreams(count: streamCount, make: make)

        let start = Date()
        var cumulative: [(offsetSeconds: Double, bytes: Int)] = []
        do {
            while Date().timeIntervalSince(start) < windowSeconds {
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
            throw SpeedTestEngineError(
                kind == .download
                    ? "no data received"
                    : "no upload completed within the measurement window"
            )
        }
        return (
            mbps: SpeedTestMath.throughputMbps(bytes: totalBytes, seconds: elapsed),
            samples: SpeedTestMath.throughputSeries(cumulative: cumulative)
        )
    }
}

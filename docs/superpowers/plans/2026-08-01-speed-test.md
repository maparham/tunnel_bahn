# In-App Speed Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dedicated Speed Test tab that measures download, upload, latency, and jitter over the app's current traffic path against Cloudflare, storing the latest result per path (Tunnel / Direct) for side-by-side comparison with throughput-over-time sparklines.

**Architecture:** A pure-math helper (`SpeedTestMath`, unit-tested) feeds a `@MainActor` engine (`SpeedTestService`, owned by `AppState` so runs survive tab switches) that runs three phases against `speed.cloudflare.com` over an ephemeral `URLSession`. Path classification comes from a new session-scoped `ConnectionStats` flag set in `VPNManager`'s connect path. A new `SpeedTestView` renders two result cards with Swift Charts sparklines.

**Tech Stack:** Swift 5.10, SwiftUI, Swift Charts (macOS 14 target), URLSession delegate byte counting, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-08-01-speed-test-design.md`

## Global Constraints

- macOS deployment target 14.0; Swift 5.10.
- No persistence, no schema versions, no compat shims (project policy: app is undistributed).
- UI copy: never use em dashes; tooltips via the `.instantTooltip(_:)` idiom (`TunnelBahn/Views/InstantTooltip.swift`), one or two short sentences.
- After editing `project.yml`, run `xcodegen generate` from the repo root before building.
- Test command: `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -only-testing:TunnelBahnUnitTests -destination 'platform=macOS' 2>&1 | tail -20` (expect `** TEST SUCCEEDED **`).
- Build command: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build 2>&1 | tail -5` (expect `** BUILD SUCCEEDED **`).
- Commit after every task with a `feat(speedtest): ...` style message.

---

### Task 1: Result model and pure math with unit tests

**Files:**
- Create: `TunnelBahn/Models/SpeedTestResult.swift`
- Create: `TunnelBahn/Services/SpeedTestMath.swift`
- Test: `Tests/Unit/SpeedTestMathTests.swift`
- Modify: `project.yml` (add the two new source files to the `TunnelBahnUnitTests` target's `sources` list)

**Interfaces:**
- Consumes: nothing.
- Produces (used by Tasks 3 and 4):
  - `enum SpeedTestPath: String { case tunnel, direct }`
  - `struct ThroughputSample: Equatable { let offsetSeconds: Double; let mbps: Double }`
  - `struct SpeedTestResult { let path: SpeedTestPath; let profileName: String?; let downloadMbps: Double; let uploadMbps: Double; let medianLatencyMs: Double; let jitterMs: Double; let finishedAt: Date; let downloadSamples: [ThroughputSample]; let uploadSamples: [ThroughputSample] }`
  - `enum SpeedTestMath` with `median(_:)`, `jitter(_:)`, `throughputMbps(bytes:seconds:)`, `throughputSeries(cumulative:)`, `deltaPercent(tunnel:direct:)` (exact signatures in Step 3).

- [ ] **Step 1: Write the failing test**

Create `Tests/Unit/SpeedTestMathTests.swift`:

```swift
import XCTest

final class SpeedTestMathTests: XCTestCase {
    // MARK: - median

    func testMedianOddCount() {
        XCTAssertEqual(SpeedTestMath.median([30, 10, 20]), 20)
    }

    func testMedianEvenCountAveragesMiddlePair() {
        XCTAssertEqual(SpeedTestMath.median([10, 20, 30, 40]), 25)
    }

    func testMedianEmptyReturnsNil() {
        XCTAssertNil(SpeedTestMath.median([]))
    }

    // MARK: - jitter (mean absolute deviation from the median)

    func testJitterMeanAbsoluteDeviationFromMedian() {
        // median = 20; deviations 10, 0, 10 -> mean 20/3
        XCTAssertEqual(SpeedTestMath.jitter([10, 20, 30])!, 20.0 / 3.0, accuracy: 1e-9)
    }

    func testJitterSingleSampleIsZero() {
        XCTAssertEqual(SpeedTestMath.jitter([42]), 0)
    }

    func testJitterEmptyReturnsNil() {
        XCTAssertNil(SpeedTestMath.jitter([]))
    }

    // MARK: - throughput

    func testThroughputMbps() {
        // 1_000_000 bytes in 2 s = 4 Mbps
        XCTAssertEqual(SpeedTestMath.throughputMbps(bytes: 1_000_000, seconds: 2), 4)
    }

    func testThroughputZeroSecondsIsZero() {
        XCTAssertEqual(SpeedTestMath.throughputMbps(bytes: 1_000_000, seconds: 0), 0)
    }

    // MARK: - throughput series

    func testThroughputSeriesDerivesPerIntervalRates() {
        let series = SpeedTestMath.throughputSeries(cumulative: [
            (offsetSeconds: 0.25, bytes: 250_000),
            (offsetSeconds: 0.50, bytes: 750_000),
        ])
        XCTAssertEqual(series.count, 2)
        // First interval: 250_000 B over 0.25 s = 8 Mbps
        XCTAssertEqual(series[0], ThroughputSample(offsetSeconds: 0.25, mbps: 8))
        // Second interval: 500_000 B over 0.25 s = 16 Mbps
        XCTAssertEqual(series[1], ThroughputSample(offsetSeconds: 0.50, mbps: 16))
    }

    func testThroughputSeriesSkipsNonPositiveIntervals() {
        let series = SpeedTestMath.throughputSeries(cumulative: [
            (offsetSeconds: 0.25, bytes: 250_000),
            (offsetSeconds: 0.25, bytes: 300_000),
        ])
        XCTAssertEqual(series.count, 1)
    }

    // MARK: - delta

    func testDeltaPercent() {
        // tunnel 60 vs direct 100 -> -40%
        XCTAssertEqual(SpeedTestMath.deltaPercent(tunnel: 60, direct: 100), -40)
    }

    func testDeltaPercentNilWhenDirectIsZero() {
        XCTAssertNil(SpeedTestMath.deltaPercent(tunnel: 60, direct: 0))
    }
}
```

Also create `TunnelBahn/Models/SpeedTestResult.swift` (types the test file needs to compile):

```swift
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
```

- [ ] **Step 2: Add sources to the test target and verify the test fails**

In `project.yml`, append to `targets.TunnelBahnUnitTests.sources` (after the existing `- path: Shared/AppGroup.swift` line):

```yaml
      - path: TunnelBahn/Models/SpeedTestResult.swift
      - path: TunnelBahn/Services/SpeedTestMath.swift
```

Run: `xcodegen generate && xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -only-testing:TunnelBahnUnitTests -destination 'platform=macOS' 2>&1 | tail -20`

Expected: build FAILURE with "cannot find 'SpeedTestMath' in scope" (the math file doesn't exist yet; a compile error on the not-yet-written unit is this project's equivalent of a failing test).

- [ ] **Step 3: Write the implementation**

Create `TunnelBahn/Services/SpeedTestMath.swift`:

```swift
import Foundation

/// Pure math for the speed test: no networking, no state. Unit-tested in SpeedTestMathTests.
enum SpeedTestMath {
    /// Standard median; even counts average the middle pair. Nil for empty input.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Jitter as mean absolute deviation from the median. Nil for empty input.
    static func jitter(_ values: [Double]) -> Double? {
        guard let median = median(values) else { return nil }
        let deviations = values.map { abs($0 - median) }
        return deviations.reduce(0, +) / Double(deviations.count)
    }

    /// Megabits per second from a byte count over a wall-clock window. Zero for a non-positive window.
    static func throughputMbps(bytes: Int, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// Converts cumulative (time, bytes) snapshots into per-interval instantaneous rates.
    /// The first interval is measured from (0, 0). Snapshots that do not advance time are skipped.
    static func throughputSeries(
        cumulative: [(offsetSeconds: Double, bytes: Int)]
    ) -> [ThroughputSample] {
        var samples: [ThroughputSample] = []
        var lastTime = 0.0
        var lastBytes = 0
        for point in cumulative {
            let dt = point.offsetSeconds - lastTime
            guard dt > 0 else { continue }
            let mbps = throughputMbps(bytes: point.bytes - lastBytes, seconds: dt)
            samples.append(ThroughputSample(offsetSeconds: point.offsetSeconds, mbps: mbps))
            lastTime = point.offsetSeconds
            lastBytes = point.bytes
        }
        return samples
    }

    /// Signed percentage change of the tunnel value relative to the direct baseline.
    /// Nil when the baseline is zero (undefined).
    static func deltaPercent(tunnel: Double, direct: Double) -> Double? {
        guard direct != 0 else { return nil }
        return (tunnel - direct) / direct * 100
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -only-testing:TunnelBahnUnitTests -destination 'platform=macOS' 2>&1 | tail -20`

Expected: `** TEST SUCCEEDED **` (all pre-existing suites plus `SpeedTestMathTests`).

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Models/SpeedTestResult.swift TunnelBahn/Services/SpeedTestMath.swift Tests/Unit/SpeedTestMathTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(speedtest): result model and pure measurement math with unit tests"
```

---

### Task 2: Session-scoped traffic path flag in ConnectionStats

**Files:**
- Modify: `TunnelBahn/Models/ConnectionStats.swift`
- Modify: `TunnelBahn/Services/VPNManager.swift` (set near line 949 after the `probePhase` computation; clear at the two sites that already do `stats.tunnelHasDefaultRoute = false`, near lines 1365 and 1665)

**Interfaces:**
- Consumes: existing `probePhase` local and `stats.tunnelHasDefaultRoute` in `applySuccessfulConnectPostTunnel`.
- Produces (used by Task 3): `ConnectionStats.hostAppInternetPathIsTunnel: Bool` which is true only while connected AND TunnelBahn's own internet traffic traverses the tunnel.

**Semantics (from the spec):** tunnel iff the probe phase is `.fullTunnel` or `.appTunnelHostIncluded` AND `stats.tunnelHasDefaultRoute` is true. `tunnelHasDefaultRoute` is already computed as `profileOkForAccounting && !destinationSplitActive` (VPNManager.swift:880), which covers the destination-split and LAN-only exclusions. Everything else (host app excluded, disconnected) is direct.

- [ ] **Step 1: Add the field to ConnectionStats**

In `TunnelBahn/Models/ConnectionStats.swift`, after the `destinationFilterAllowedIPsDerived` property (line 83), add:

```swift
    /// True while TunnelBahn's own internet traffic traverses the tunnel: connected with a
    /// default-route profile, no destination split, and (in app-tunnel mode) the host app
    /// included in the NEAppRule list. Drives the speed test's Tunnel/Direct classification.
    /// Not persisted (session-scoped, set at connect).
    var hostAppInternetPathIsTunnel: Bool = false
```

Do NOT add it to `CodingKeys` (the enum's comment says defaulted session-scoped fields are excluded from Codable synthesis; this matches `destinationFilterAllowedIPsDerived`). Do NOT change `static let empty` (defaulted properties are not part of the memberwise call there).

- [ ] **Step 2: Set the flag at connect**

In `TunnelBahn/Services/VPNManager.swift`, directly after the `probePhase` computation closes (the `}()` at line 949), add:

```swift
        // Speed test path classification: TunnelBahn's own internet traffic uses the tunnel only
        // when the tunnel owns the default route (default-route profile, no destination split)
        // and, in app-tunnel mode, the host app is inside the NEAppRule list.
        stats.hostAppInternetPathIsTunnel =
            stats.tunnelHasDefaultRoute && probePhase != .appTunnelHostExcluded
```

- [ ] **Step 3: Clear the flag at disconnect**

At both existing sites that set `stats.tunnelHasDefaultRoute = false` (near lines 1365 and 1665; find them with `grep -n "tunnelHasDefaultRoute = false" TunnelBahn/Services/VPNManager.swift`), add on the next line:

```swift
        stats.hostAppInternetPathIsTunnel = false
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`. (No unit test: VPNManager has no test seam; the flag's inputs are already log-verified via the `[connect]` summary lines, and Task 5 verifies end to end.)

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Models/ConnectionStats.swift TunnelBahn/Services/VPNManager.swift
git commit -m "feat(speedtest): session-scoped host-app traffic path flag in ConnectionStats"
```

---

### Task 3: SpeedTestService engine

**Files:**
- Create: `TunnelBahn/Services/SpeedTestService.swift`
- Modify: `TunnelBahn/AppState.swift` (own the service; bind `objectWillChange`)

**Interfaces:**
- Consumes: `SpeedTestPath`, `ThroughputSample`, `SpeedTestResult`, `SpeedTestMath` (Task 1); `vpnManager.stats.hostAppInternetPathIsTunnel` (Task 2); `VPNManager.$stats` publisher; `ProfileStore.profiles` (`[WireGuardProfile]`, each with `id: UUID`, `name: String`).
- Produces (used by Task 4):
  - `SpeedTestService.Phase` enum: `.idle, .latency, .download, .upload`
  - `@Published private(set) var phase: Phase`
  - `@Published private(set) var liveReadout: String?`
  - `@Published private(set) var errorMessage: String?`
  - `@Published private(set) var statusNote: String?`
  - `@Published private(set) var tunnelResult: SpeedTestResult?`
  - `@Published private(set) var directResult: SpeedTestResult?`
  - `var isRunning: Bool`, `var currentPath: SpeedTestPath`, `var currentPathProfileName: String?`
  - `func run()`, `func cancel()`

- [ ] **Step 1: Write the service**

Create `TunnelBahn/Services/SpeedTestService.swift`:

```swift
import Combine
import Foundation

/// Counts payload bytes across all tasks of one URLSession. Download phases count received
/// body bytes (didReceive), upload phases count sent body bytes (didSendBodyData). Delegate
/// callbacks arrive on the session's queue; the lock makes the running total readable from
/// the main actor's sampler loop.
private final class ByteCountingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes = 0

    var bytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _bytes
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
}

/// Full-suite speed test (latency, jitter, download, upload) against Cloudflare's speed-test
/// endpoints, measuring whatever path TunnelBahn's own traffic currently takes. Owned by
/// AppState so a run survives tab switches; SpeedTestView only observes it.
@MainActor
final class SpeedTestService: ObservableObject {
    enum Phase: Equatable {
        case idle, latency, download, upload
    }

    @Published private(set) var phase: Phase = .idle
    /// Live number for the active phase, pre-formatted ("312 Mbps" / "24 ms").
    @Published private(set) var liveReadout: String?
    @Published private(set) var errorMessage: String?
    /// Non-error notices, e.g. auto-cancel on path change.
    @Published private(set) var statusNote: String?
    @Published private(set) var tunnelResult: SpeedTestResult?
    @Published private(set) var directResult: SpeedTestResult?

    private let vpnManager: VPNManager
    private let profileStore: ProfileStore
    private var runTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private static let latencyURL = URL(string: "https://speed.cloudflare.com/__down?bytes=0")!
    private static let downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=100000000")!
    private static let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!
    private static let latencyAttempts = 9 // first discarded as connection warmup
    private static let minLatencySuccesses = 5
    private static let downloadStreams = 4
    private static let uploadStreams = 2
    private static let windowSeconds = 8.0
    private static let sampleIntervalSeconds = 0.25
    private static let uploadBodyBytes = 48 * 1024 * 1024

    private static let log = AppLog(subsystem: "com.tunnelbahn.mac", category: "SpeedTest")

    var isRunning: Bool { phase != .idle }

    var currentPath: SpeedTestPath {
        let stats = vpnManager.stats
        return (stats.state == .connected && stats.hostAppInternetPathIsTunnel) ? .tunnel : .direct
    }

    /// Connected profile name when the current path is tunnel; nil otherwise.
    var currentPathProfileName: String? {
        guard currentPath == .tunnel, let id = vpnManager.stats.connectedProfileID else { return nil }
        return profileStore.profiles.first(where: { $0.id == id })?.name
    }

    init(vpnManager: VPNManager, profileStore: ProfileStore) {
        self.vpnManager = vpnManager
        self.profileStore = profileStore

        // A mid-run path change (connect, disconnect, reassert) invalidates the measurement:
        // the slot the run started for is no longer the path being measured.
        struct PathSignature: Equatable {
            let state: VPNConnectionState
            let isTunnel: Bool
        }
        vpnManager.$stats
            .map { PathSignature(state: $0.state, isTunnel: $0.hostAppInternetPathIsTunnel) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                Self.log.notice("[APPSPLIT_SPEEDTEST] cancelled: traffic path changed mid-run")
                self.statusNote = "Test cancelled: traffic path changed"
                self.runTask?.cancel()
            }
            .store(in: &cancellables)
    }

    func run() {
        guard !isRunning else { return }
        errorMessage = nil
        statusNote = nil
        let path = currentPath
        let profileName = currentPathProfileName
        Self.log.notice("[APPSPLIT_SPEEDTEST] run begin path=\(path.rawValue)")
        runTask = Task { [weak self] in
            await self?.performRun(path: path, profileName: profileName)
        }
    }

    func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
    }

    // MARK: - Run pipeline

    private func performRun(path: SpeedTestPath, profileName: String?) async {
        defer {
            phase = .idle
            liveReadout = nil
            runTask = nil
        }
        do {
            phase = .latency
            let latency = try await measureLatency()

            phase = .download
            let download = try await measureTransferWindow(kind: .download)

            phase = .upload
            let upload = try await measureTransferWindow(kind: .upload)

            let result = SpeedTestResult(
                path: path,
                profileName: profileName,
                downloadMbps: download.mbps,
                uploadMbps: upload.mbps,
                medianLatencyMs: latency.median,
                jitterMs: latency.jitter,
                finishedAt: Date(),
                downloadSamples: download.samples,
                uploadSamples: upload.samples
            )
            switch path {
            case .tunnel: tunnelResult = result
            case .direct: directResult = result
            }
            Self.log.notice(
                "[APPSPLIT_SPEEDTEST] run ok path=\(path.rawValue) down=\(Int(result.downloadMbps))Mbps up=\(Int(result.uploadMbps))Mbps latency=\(Int(result.medianLatencyMs))ms"
            )
        } catch is CancellationError {
            Self.log.notice("[APPSPLIT_SPEEDTEST] run cancelled path=\(path.rawValue)")
        } catch {
            Self.log.notice("[APPSPLIT_SPEEDTEST] run failed path=\(path.rawValue) error=\(error.localizedDescription)")
            errorMessage = "Speed test failed: \(error.localizedDescription)"
        }
    }

    /// Dedicated per-phase session: ephemeral (no cache, no cookies) so cached responses can
    /// never inflate numbers, and invalidated after each phase so cancelled tasks are torn down.
    private static func makeSession(delegate: URLSessionDataDelegate?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private struct SpeedTestError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func measureLatency() async throws -> (median: Double, jitter: Double) {
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
                    liveReadout = "\(Int(elapsedMs)) ms"
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        guard samplesMs.count >= Self.minLatencySuccesses,
              let median = SpeedTestMath.median(samplesMs),
              let jitter = SpeedTestMath.jitter(samplesMs) else {
            throw SpeedTestError(lastError?.localizedDescription ?? "latency probes failed")
        }
        return (median, jitter)
    }

    private enum TransferKind {
        case download, upload
    }

    /// Runs parallel transfer streams for a fixed window, sampling the cumulative byte count
    /// every `sampleIntervalSeconds`. Outstanding tasks are cancelled at window end; throughput
    /// is bytes-in-window over elapsed wall clock.
    private func measureTransferWindow(kind: TransferKind) async throws -> (mbps: Double, samples: [ThroughputSample]) {
        let delegate = ByteCountingSessionDelegate()
        let session = Self.makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }

        let tasks: [URLSessionTask]
        switch kind {
        case .download:
            tasks = (0..<Self.downloadStreams).map { _ in
                session.dataTask(with: URLRequest(url: Self.downloadURL))
            }
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
            tasks = (0..<Self.uploadStreams).map { _ in
                session.uploadTask(with: request, from: body)
            }
        }
        tasks.forEach { $0.resume() }

        let start = Date()
        var cumulative: [(offsetSeconds: Double, bytes: Int)] = []
        do {
            while Date().timeIntervalSince(start) < Self.windowSeconds {
                try await Task.sleep(nanoseconds: UInt64(Self.sampleIntervalSeconds * 1_000_000_000))
                let offset = Date().timeIntervalSince(start)
                cumulative.append((offsetSeconds: offset, bytes: delegate.bytes))
                let mbps = SpeedTestMath.throughputMbps(bytes: delegate.bytes, seconds: offset)
                liveReadout = "\(Int(mbps)) Mbps"
            }
        } catch is CancellationError {
            tasks.forEach { $0.cancel() }
            throw CancellationError()
        }
        tasks.forEach { $0.cancel() }

        let elapsed = Date().timeIntervalSince(start)
        let totalBytes = delegate.bytes
        guard totalBytes > 0 else {
            throw SpeedTestError(kind == .download ? "no data received" : "no data sent")
        }
        return (
            mbps: SpeedTestMath.throughputMbps(bytes: totalBytes, seconds: elapsed),
            samples: SpeedTestMath.throughputSeries(cumulative: cumulative)
        )
    }
}
```

Note: `SecRandomCopyBytes` needs `import Security` — add it below `import Foundation`.

- [ ] **Step 2: Own the service in AppState**

In `TunnelBahn/AppState.swift`:

1. Add a property after `var logCaptureStore: LogCaptureStore` (line 15):

```swift
    var speedTestService: SpeedTestService
```

2. In `init()`, after `self.logCaptureStore = LogCaptureStore()` (line 51) and before `bindChildStores()`:

```swift
        self.speedTestService = SpeedTestService(vpnManager: vpnManager, profileStore: profileStore)
```

3. In `bindChildStores()`, alongside the other child bindings (e.g. after the `logCaptureStore` sink):

```swift
        speedTestService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`. (The engine's math is covered by Task 1's tests; the network layer is thin and verified end to end in Task 5.)

- [ ] **Step 4: Commit**

```bash
git add TunnelBahn/Services/SpeedTestService.swift TunnelBahn/AppState.swift
git commit -m "feat(speedtest): SpeedTestService engine with path auto-cancel, owned by AppState"
```

---

### Task 4: Speed Test tab and view

**Files:**
- Create: `TunnelBahn/Views/SpeedTestView.swift`
- Modify: `TunnelBahn/Views/ContentView.swift` (new tab case between `status` and `logs`)
- Modify: `CHANGELOG.md` (entry under `## [Unreleased]`, matching the existing entry style)

**Interfaces:**
- Consumes: everything Task 3 produces on `SpeedTestService`; `SpeedTestMath.deltaPercent(tunnel:direct:)`; `.instantTooltip(_:)` from `TunnelBahn/Views/InstantTooltip.swift`.
- Produces: `SpeedTestView(service:)` rendered by `ContentView`.

- [ ] **Step 1: Add the tab**

In `TunnelBahn/Views/ContentView.swift`:

1. In the `Tab` enum, between `case status` and `case logs`:

```swift
        case speedTest = "Speed Test"
```

2. In `var icon`, between the `.status` and `.logs` cases:

```swift
            case .speedTest: "gauge.with.needle"
```

3. In the detail `switch`, between the `.status` and `.logs` cases:

```swift
            case .speedTest: SpeedTestView(service: appState.speedTestService)
```

- [ ] **Step 2: Write the view**

Create `TunnelBahn/Views/SpeedTestView.swift`:

```swift
import Charts
import SwiftUI

struct SpeedTestView: View {
    @ObservedObject var service: SpeedTestService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if service.isRunning {
                    runningSection
                }
                if let errorMessage = service.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if let statusNote = service.statusNote {
                    Text(statusNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    resultCard(
                        title: "Tunnel",
                        result: service.tunnelResult,
                        emptyHint: "Connect a tunnel and run the test to fill this column."
                    )
                    resultCard(
                        title: "Direct",
                        result: service.directResult,
                        emptyHint: "Run the test while the app's traffic is direct to fill this column."
                    )
                }
                deltaRow
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Speed Test")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(pathBadgeText)
                .font(.headline)
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .instantTooltip(
                    "Measures the path TunnelBahn's own traffic takes. Results fill the matching column below."
                )
            Spacer()
            if service.isRunning {
                Button("Cancel") { service.cancel() }
            } else {
                Button("Run Speed Test") { service.run() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var pathBadgeText: String {
        switch service.currentPath {
        case .tunnel:
            if let name = service.currentPathProfileName {
                return "Traffic path: Tunnel (\(name))"
            }
            return "Traffic path: Tunnel"
        case .direct:
            return "Traffic path: Direct"
        }
    }

    // MARK: - Running

    private var runningSection: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(phaseLabel)
                .font(.callout)
            if let liveReadout = service.liveReadout {
                Text(liveReadout)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phaseLabel: String {
        switch service.phase {
        case .idle: ""
        case .latency: "Measuring latency"
        case .download: "Measuring download"
        case .upload: "Measuring upload"
        }
    }

    // MARK: - Result cards

    @ViewBuilder
    private func resultCard(title: String, result: SpeedTestResult?, emptyHint: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    if let profileName = result?.profileName {
                        Text(profileName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider()
                if let result {
                    metricRow(label: "Download", value: String(format: "%.1f Mbps", result.downloadMbps))
                    sparkline(samples: result.downloadSamples)
                    metricRow(label: "Upload", value: String(format: "%.1f Mbps", result.uploadMbps))
                    sparkline(samples: result.uploadSamples)
                    metricRow(label: "Latency", value: String(format: "%.0f ms", result.medianLatencyMs))
                    metricRow(label: "Jitter", value: String(format: "%.1f ms", result.jitterMs))
                    Text("Tested \(result.finishedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(emptyHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
        }
    }

    private func sparkline(samples: [ThroughputSample]) -> some View {
        Chart(samples, id: \.offsetSeconds) { sample in
            AreaMark(
                x: .value("Time", sample.offsetSeconds),
                y: .value("Mbps", sample.mbps)
            )
            .foregroundStyle(Color.accentColor.opacity(0.2))
            LineMark(
                x: .value("Time", sample.offsetSeconds),
                y: .value("Mbps", sample.mbps)
            )
            .foregroundStyle(Color.accentColor)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 60)
    }

    // MARK: - Delta

    @ViewBuilder
    private var deltaRow: some View {
        if let tunnel = service.tunnelResult, let direct = service.directResult {
            HStack(spacing: 16) {
                Text("Tunnel vs direct:")
                if let down = SpeedTestMath.deltaPercent(tunnel: tunnel.downloadMbps, direct: direct.downloadMbps) {
                    Text("Download \(signedPercent(down))")
                }
                if let up = SpeedTestMath.deltaPercent(tunnel: tunnel.uploadMbps, direct: direct.uploadMbps) {
                    Text("Upload \(signedPercent(up))")
                }
                Text("Latency \(signedMs(tunnel.medianLatencyMs - direct.medianLatencyMs))")
                Text("Jitter \(signedMs(tunnel.jitterMs - direct.jitterMs))")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func signedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value)
    }

    private func signedMs(_ value: Double) -> String {
        String(format: "%+.0f ms", value)
    }
}
```

- [ ] **Step 3: Changelog entry**

In `CHANGELOG.md` under `## [Unreleased]`, add (match the existing entry style used there; read the surrounding lines first):

```markdown
- Speed Test tab: full-suite in-app speed test (download, upload, latency, jitter) against Cloudflare, measuring the app's current traffic path. Latest Tunnel and Direct results shown side by side with throughput sparklines and an overhead delta row. Runs continue across tab switches and auto-cancel if the traffic path changes mid-run.
```

- [ ] **Step 4: Build and run unit tests**

Run: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -only-testing:TunnelBahnUnitTests -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Views/SpeedTestView.swift TunnelBahn/Views/ContentView.swift CHANGELOG.md
git commit -m "feat(ui): dedicated Speed Test tab with side-by-side path comparison and sparklines"
```

---

### Task 5: End-to-end verification

**Files:** none created; manual verification of the running app.

**Interfaces:** consumes the complete feature.

- [ ] **Step 1: Launch the app**

Use the project's run tooling (`tools/run-with-logs.sh` if a log-tailing run is wanted, otherwise launch the built Debug app). The Speed Test tab must appear in the sidebar between Monitoring and Logs with a gauge icon.

- [ ] **Step 2: Direct run**

With the VPN disconnected: badge reads "Traffic path: Direct". Run the test. Verify the phases advance (latency, download, upload) with live readouts, and the Direct card fills with four metrics, two sparklines, and a "Tested ... ago" caption. Log check: `log show --last 5m --predicate 'subsystem == "com.tunnelbahn.mac"' | grep APPSPLIT_SPEEDTEST` shows `run begin path=direct` and `run ok path=direct`.

- [ ] **Step 3: Tunnel run and delta**

Connect a full-tunnel default-route profile. Badge flips to "Traffic path: Tunnel (ProfileName)". Run the test; the Tunnel card fills and the delta row appears with signed percentages and ms values. Sanity: tunnel download should be at or below direct download.

- [ ] **Step 4: Mid-run behaviors**

1. Start a run, switch to the Logs tab and back: the run must still be progressing (phase label and live readout advancing).
2. Start a run, then disconnect the tunnel mid-run: the run stops and shows "Test cancelled: traffic path changed"; the previously stored results are untouched.
3. Start a run and press Cancel: returns to idle, previous results untouched, no error text.

- [ ] **Step 5: Record outcome**

If any step fails, fix before proceeding (use superpowers:systematic-debugging). When all pass, report the verification evidence (log lines, observed numbers) and stop; the branch/integration decision is the user's.

# Speed Test Helper Process Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a signed helper executable inside TunnelBahn.app so the Tunnel speed test card runs through the tunnel (via an always-appended NEAppRule for the helper) while the Direct card runs in the host app, making both cards runnable at any time in per-app mode.

**Architecture:** A new `SpeedTestHelper` command-line target shares the measurement engine with the app (same compile-sources-into-multiple-targets pattern as the existing targets) and streams NDJSON progress on stdout. A host-side `SpeedTestHelperClient` launches it with `Process` and parses events. The connectivity probe moves into the helper; the `includeHostAppInPerAppRulesForProbe` setting is deleted.

**Tech Stack:** Swift 5.10, SwiftUI, NetworkExtension, XcodeGen, xcodebuild. Spec: `docs/superpowers/specs/2026-08-01-speedtest-helper-design.md` (read it first).

## Global Constraints

- Commits go directly on `main` (approved repo convention). Commit trailer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- After ANY project.yml edit run: `xcodegen generate`
- Build: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build 2>&1 | tail -5`
- Tests: `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -only-testing:TunnelBahnUnitTests -destination 'platform=macOS' 2>&1 | tail -5`
- No em dashes in any UI string. Tooltips use the `Image(systemName: "questionmark.circle")` + `.instantTooltip(...)` idiom, one or two short sentences.
- No persistence/compat shims/migrations (app is undistributed). Delete dead settings outright.
- Keep engine behavior exactly: 50 MB per download request (Cloudflare returns HTTP 403 at 100 MB or more), any non-2xx fails the run loudly, finished streams restart, 250 ms sampling.
- Do NOT touch or pop `git stash@{0}` (user's own WIP on UDPFlowRelay.swift).
- Signing: team 92G3VZAPVG, hardened runtime, automatic signing (inherited from project.yml root settings).

---

### Task 1: Shared NDJSON protocol types

**Files:**
- Create: `Shared/SpeedTestHelperProtocol.swift`
- Modify: `TunnelBahn/Models/SpeedTestResult.swift` (make `ThroughputSample` Codable)
- Modify: `project.yml` (add new file + `SpeedTestResult.swift` is already in the `TunnelBahnUnitTests` sources; add `Shared/SpeedTestHelperProtocol.swift` to that list)
- Test: `Tests/Unit/SpeedTestHelperProtocolTests.swift`

**Interfaces:**
- Consumes: `ThroughputSample` from `TunnelBahn/Models/SpeedTestResult.swift`.
- Produces (later tasks rely on these exact names): `SpeedTestHelperConstants.executableName: String`, `SpeedTestHelperConstants.signingIdentifier: String`, `enum SpeedTestPhaseName: String, Codable` (cases `latency, download, upload`), `struct SpeedTestRunPayload: Codable, Equatable`, `struct SpeedTestHelperLine: Codable, Equatable` with `static func decode(_ line: String) -> SpeedTestHelperLine?` and `func encodedLine() -> String?`, `struct SpeedTestHelperProbeOutcome: Codable, Equatable`.

- [ ] **Step 1: Make ThroughputSample Codable**

In `TunnelBahn/Models/SpeedTestResult.swift` change:

```swift
struct ThroughputSample: Equatable {
```

to:

```swift
struct ThroughputSample: Equatable, Codable {
```

- [ ] **Step 2: Write the protocol file**

Create `Shared/SpeedTestHelperProtocol.swift`:

```swift
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
/// "result" -> result (helper then exits 0); "error" -> message (helper then exits nonzero).
struct SpeedTestHelperLine: Codable, Equatable {
    var event: String
    var phase: SpeedTestPhaseName? = nil
    var readout: String? = nil
    var offsetSeconds: Double? = nil
    var bytes: Int? = nil
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
```

- [ ] **Step 3: Write the failing tests**

Create `Tests/Unit/SpeedTestHelperProtocolTests.swift`:

```swift
import XCTest
@testable import TunnelBahn

final class SpeedTestHelperProtocolTests: XCTestCase {
    func testPhaseLineRoundTrip() throws {
        let line = SpeedTestHelperLine(event: "phase", phase: .download)
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertFalse(encoded.contains("\n"))
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded), line)
    }

    func testSampleLineRoundTrip() throws {
        let line = SpeedTestHelperLine(event: "sample", readout: "312 Mbps", offsetSeconds: 1.25, bytes: 52_428_800)
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded), line)
    }

    func testResultLineRoundTrip() throws {
        let payload = SpeedTestRunPayload(
            downloadMbps: 512.5,
            uploadMbps: 96.25,
            medianLatencyMs: 24,
            jitterMs: 2.5,
            downloadSamples: [ThroughputSample(offsetSeconds: 0.25, mbps: 480)],
            uploadSamples: [ThroughputSample(offsetSeconds: 0.25, mbps: 90)]
        )
        let line = SpeedTestHelperLine(event: "result", result: payload)
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded)?.result, payload)
    }

    func testErrorLineRoundTrip() throws {
        let line = SpeedTestHelperLine(event: "error", message: "server rejected the request (HTTP 403)")
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded), line)
    }

    func testDecodeMalformedLineReturnsNil() {
        XCTAssertNil(SpeedTestHelperLine.decode("not json"))
        XCTAssertNil(SpeedTestHelperLine.decode("{\"phase\":\"download\"}")) // missing required `event`
    }
}
```

- [ ] **Step 4: Add sources to project.yml and regenerate**

In `project.yml`, in the `TunnelBahnUnitTests` target's `sources` list, add:

```yaml
      - path: Shared/SpeedTestHelperProtocol.swift
```

Run: `xcodegen generate`

- [ ] **Step 5: Run tests, expect pass**

Run the Tests command from Global Constraints. Expected: `** TEST SUCCEEDED **` (the new file plus tests compile together, so there is no red step here; the failing-first cycle is not applicable to pure type declarations).

- [ ] **Step 6: Build the app**

Run the Build command from Global Constraints. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Shared/SpeedTestHelperProtocol.swift TunnelBahn/Models/SpeedTestResult.swift Tests/Unit/SpeedTestHelperProtocolTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(speedtest): shared helper NDJSON protocol types"
```

(Include the commit trailer from Global Constraints on this and every commit.)

---

### Task 2: Extract the measurement engine

**Files:**
- Create: `Shared/SpeedTestEngine.swift`
- Modify: `TunnelBahn/Services/SpeedTestService.swift` (remove everything the engine absorbs; consume the engine)

**Interfaces:**
- Consumes: `SpeedTestPhaseName`, `SpeedTestRunPayload` from Task 1; `SpeedTestMath` (`TunnelBahn/Services/SpeedTestMath.swift`); `AppLog` (`Shared/AppLog.swift`).
- Produces: `enum SpeedTestEngineEvent: Equatable` with cases `phase(SpeedTestPhaseName)` and `sample(readout: String, offsetSeconds: Double?, bytes: Int?)`; `final class SpeedTestEngine` with `func run(onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void) async throws -> SpeedTestRunPayload` and `struct SpeedTestEngineError: LocalizedError`. Task 4's client re-emits `SpeedTestEngineEvent`; Task 5's service consumes it from both engine and client.

This is a behavior-preserving refactor. The engine is `SpeedTestService.swift` lines 1-104 (`ByteCountingSessionDelegate`) plus `measureLatency`, `measureTransferWindow`, `makeSession`, `SpeedTestError`, and the URL/tuning constants, moved verbatim except: no `@MainActor`, no `@Published`, every `liveReadout = ...` assignment becomes an `onEvent(.sample(...))` call, and each phase start emits `onEvent(.phase(...))`.

- [ ] **Step 1: Create Shared/SpeedTestEngine.swift**

Move `ByteCountingSessionDelegate` (whole class, unchanged) to the top of the new file, `private` to the file. Then:

```swift
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
    // measureLatency / measureTransferWindow / makeSession moved here (see below)
}
```

Move `makeSession`, `measureLatency`, `measureTransferWindow`, and the `TransferKind` enum into the class, with these mechanical edits:
- `SpeedTestError` becomes `SpeedTestEngineError`.
- In `measureLatency`, `liveReadout = "\(Int(elapsedMs)) ms"` becomes `onEvent(.sample(readout: "\(Int(elapsedMs)) ms", offsetSeconds: nil, bytes: nil))`; add `onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void` parameter.
- In `measureTransferWindow`, `liveReadout = "\(Int(mbps)) Mbps"` becomes `onEvent(.sample(readout: "\(Int(mbps)) Mbps", offsetSeconds: offset, bytes: delegate.bytes))`; add the same `onEvent` parameter.
- All cancellation checks (`Task.checkCancellation`, the `URLError(.cancelled)` remap comment) move unchanged.
- Imports: `Foundation`, `Security`.

- [ ] **Step 2: Slim SpeedTestService.swift**

Delete `ByteCountingSessionDelegate`, `makeSession`, `SpeedTestError`, `measureLatency`, `measureTransferWindow`, `TransferKind`, and the URL/tuning constants from `SpeedTestService.swift`. Replace the body of `performRun` measurement section with:

```swift
    private func performRun(path: SpeedTestPath, profileName: String?) async {
        defer {
            phase = .idle
            liveReadout = nil
            runTask = nil
            runningPath = nil
        }
        do {
            let payload = try await SpeedTestEngine().run { [weak self] event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            let result = SpeedTestResult(
                path: path,
                profileName: profileName,
                downloadMbps: payload.downloadMbps,
                uploadMbps: payload.uploadMbps,
                medianLatencyMs: payload.medianLatencyMs,
                jitterMs: payload.jitterMs,
                finishedAt: Date(),
                downloadSamples: payload.downloadSamples,
                uploadSamples: payload.uploadSamples
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

    /// Maps engine/helper progress events onto the published UI state. Ignores events
    /// arriving after the run ended (phase == .idle) so a late Task hop cannot resurrect UI.
    private func apply(_ event: SpeedTestEngineEvent) {
        guard phase != .idle || runningPath != nil else { return }
        switch event {
        case .phase(let name):
            switch name {
            case .latency: phase = .latency
            case .download: phase = .download
            case .upload: phase = .upload
            }
        case .sample(let readout, _, _):
            liveReadout = readout
        }
    }
```

Keep `run()`, `cancel()`, `currentPath`, `currentPathProfileName`, the `Phase` enum, the published properties, and the path-change auto-cancel subscription unchanged in this task (Task 5 reworks them).

- [ ] **Step 3: Build and test**

Run the Build command, expect `** BUILD SUCCEEDED **`. Run the Tests command, expect `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Shared/SpeedTestEngine.swift TunnelBahn/Services/SpeedTestService.swift
git commit -m "refactor(speedtest): extract shared SpeedTestEngine from SpeedTestService"
```

---

### Task 3: SpeedTestHelper target with `run` mode

**Files:**
- Create: `SpeedTestHelper/main.swift`
- Modify: `project.yml` (new target, TunnelBahn dependency, embed script, scheme)

**Interfaces:**
- Consumes: `SpeedTestEngine`, `SpeedTestEngineEvent` (Task 2); `SpeedTestHelperLine`, `SpeedTestPhaseName` (Task 1).
- Produces: `TunnelBahn.app/Contents/MacOS/SpeedTestHelper` binary, signing identifier `com.tunnelbahn.mac.speedtesthelper`. CLI: `SpeedTestHelper run` streams NDJSON per the Task 1 protocol; unknown args exit 64. Task 6 adds `probe`.

- [ ] **Step 1: Write SpeedTestHelper/main.swift**

```swift
import Foundation

// NDJSON writer. FileHandle.write is unbuffered, so each event line reaches the host pipe
// immediately (stdout through a pipe is otherwise fully buffered). The lock serializes
// writes from the engine's session queues.
private let emitLock = NSLock()
private func emit(_ line: SpeedTestHelperLine) {
    emitLock.lock()
    defer { emitLock.unlock() }
    guard let encoded = line.encodedLine() else { return }
    FileHandle.standardOutput.write(Data((encoded + "\n").utf8))
}

private func usageExit() -> Never {
    FileHandle.standardError.write(Data("usage: SpeedTestHelper run\n".utf8))
    exit(64)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run":
    do {
        let payload = try await SpeedTestEngine().run { event in
            switch event {
            case .phase(let phase):
                emit(SpeedTestHelperLine(event: "phase", phase: phase))
            case .sample(let readout, let offsetSeconds, let bytes):
                emit(SpeedTestHelperLine(event: "sample", readout: readout, offsetSeconds: offsetSeconds, bytes: bytes))
            }
        }
        emit(SpeedTestHelperLine(event: "result", result: payload))
        exit(0)
    } catch {
        emit(SpeedTestHelperLine(event: "error", message: error.localizedDescription))
        exit(1)
    }
default:
    usageExit()
}
```

Note: top-level `await` is valid in `main.swift` (Swift concurrency top-level code, macOS 14 target).

- [ ] **Step 2: Add the target to project.yml**

Add under `targets:`:

```yaml
  SpeedTestHelper:
    type: tool
    platform: macOS
    sources:
      - path: SpeedTestHelper
      - path: Shared/SpeedTestHelperProtocol.swift
      - path: Shared/SpeedTestEngine.swift
      - path: Shared/AppLog.swift
      - path: Shared/Constants.swift
      - path: Shared/SharedLogWriter.swift
      - path: TunnelBahn/Services/SpeedTestMath.swift
      - path: TunnelBahn/Models/SpeedTestResult.swift
    settings:
      base:
        PRODUCT_NAME: SpeedTestHelper
        PRODUCT_BUNDLE_IDENTIFIER: com.tunnelbahn.mac.speedtesthelper
        SKIP_INSTALL: YES
```

(If the build in Step 4 fails because one of the Shared files needs another Shared file, add that specific file's path to this sources list; the unit-test target's sources list in project.yml shows which Shared files compile standalone together.)

In the `TunnelBahn` target's `dependencies:` add (build ordering only; the tool is copied by script, not linked or embedded):

```yaml
      - target: SpeedTestHelper
        link: false
        embed: false
```

Add to the `TunnelBahn` target (it currently has only `preBuildScripts`):

```yaml
    postBuildScripts:
      - name: Embed SpeedTestHelper
        script: |
          set -euo pipefail
          cp -f "${BUILT_PRODUCTS_DIR}/SpeedTestHelper" "${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/SpeedTestHelper"
        basedOnDependencyAnalysis: false
```

(The helper is signed by its own target with hardened runtime; `cp` preserves the signature, and Xcode seals the app bundle after all build phases, so the copied helper is covered by the app's signature.)

In `schemes: TunnelBahn: build: targets:` add:

```yaml
        SpeedTestHelper: all
```

- [ ] **Step 3: Regenerate and build**

Run: `xcodegen generate` then the Build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify the embedded binary and its signature**

```bash
APP=$(xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')/TunnelBahn.app
ls -l "$APP/Contents/MacOS/SpeedTestHelper"
codesign -dv "$APP/Contents/MacOS/SpeedTestHelper" 2>&1 | grep Identifier
```

Expected: the binary exists; `Identifier=com.tunnelbahn.mac.speedtesthelper`.

- [ ] **Step 5: Smoke-run the helper directly**

```bash
"$APP/Contents/MacOS/SpeedTestHelper" 2>&1; echo "exit=$?"
"$APP/Contents/MacOS/SpeedTestHelper" run | head -4
```

Expected: first command prints the usage line and `exit=64`. Second command streams NDJSON starting with `{"event":"phase","phase":"latency"}` followed by `sample` lines (this performs real transfers on the current network; Ctrl-C or let `head` close the pipe).

- [ ] **Step 6: Commit**

```bash
git add SpeedTestHelper/main.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(speedtest): bundled SpeedTestHelper executable with NDJSON run mode"
```

---

### Task 4: SpeedTestHelperClient

**Files:**
- Create: `TunnelBahn/Services/SpeedTestHelperClient.swift`
- Modify: `project.yml` (add the client file to `TunnelBahnUnitTests` sources)
- Test: `Tests/Unit/SpeedTestHelperClientTests.swift`

**Interfaces:**
- Consumes: `SpeedTestHelperLine`, `SpeedTestRunPayload`, `SpeedTestHelperConstants` (Task 1); `SpeedTestEngineEvent` (Task 2).
- Produces: `enum SpeedTestHelperClientError: LocalizedError` (cases below); `final class SpeedTestHelperClient` with `static func helperURL() -> URL?`, `static func reduce(line: String, onEvent: (SpeedTestEngineEvent) -> Void) throws -> SpeedTestRunPayload?`, `func run(onEvent: @escaping @Sendable (SpeedTestEngineEvent) -> Void) async throws -> SpeedTestRunPayload`. Task 6 adds `static func probe(...)`.

- [ ] **Step 1: Write the failing parser tests**

Create `Tests/Unit/SpeedTestHelperClientTests.swift`:

```swift
import XCTest
@testable import TunnelBahn

final class SpeedTestHelperClientTests: XCTestCase {
    private func line(_ l: SpeedTestHelperLine) -> String { l.encodedLine()! }

    func testPhaseLineEmitsEventAndNoPayload() throws {
        var events: [SpeedTestEngineEvent] = []
        let payload = try SpeedTestHelperClient.reduce(
            line: line(SpeedTestHelperLine(event: "phase", phase: .download))
        ) { events.append($0) }
        XCTAssertNil(payload)
        XCTAssertEqual(events, [.phase(.download)])
    }

    func testSampleLineEmitsEvent() throws {
        var events: [SpeedTestEngineEvent] = []
        _ = try SpeedTestHelperClient.reduce(
            line: line(SpeedTestHelperLine(event: "sample", readout: "312 Mbps", offsetSeconds: 1.0, bytes: 1000))
        ) { events.append($0) }
        XCTAssertEqual(events, [.sample(readout: "312 Mbps", offsetSeconds: 1.0, bytes: 1000)])
    }

    func testResultLineReturnsPayload() throws {
        let expected = SpeedTestRunPayload(
            downloadMbps: 500, uploadMbps: 90, medianLatencyMs: 20, jitterMs: 2,
            downloadSamples: [], uploadSamples: []
        )
        let payload = try SpeedTestHelperClient.reduce(
            line: line(SpeedTestHelperLine(event: "result", result: expected))
        ) { _ in }
        XCTAssertEqual(payload, expected)
    }

    func testErrorLineThrowsWithHelperMessage() {
        XCTAssertThrowsError(
            try SpeedTestHelperClient.reduce(
                line: line(SpeedTestHelperLine(event: "error", message: "server rejected the request (HTTP 403)"))
            ) { _ in }
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "server rejected the request (HTTP 403)"
            )
        }
    }

    func testMalformedLineThrows() {
        XCTAssertThrowsError(try SpeedTestHelperClient.reduce(line: "not json") { _ in })
    }

    func testUnknownEventThrows() {
        XCTAssertThrowsError(
            try SpeedTestHelperClient.reduce(line: #"{"event":"mystery"}"#) { _ in }
        )
    }

    func testResultLineWithoutPayloadThrows() {
        XCTAssertThrowsError(
            try SpeedTestHelperClient.reduce(line: #"{"event":"result"}"#) { _ in }
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the Tests command. Expected: FAIL (SpeedTestHelperClient not defined).

- [ ] **Step 3: Implement the client**

Create `TunnelBahn/Services/SpeedTestHelperClient.swift`:

```swift
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
```

- [ ] **Step 4: Add to test target and regenerate**

In `project.yml`, `TunnelBahnUnitTests` sources, add:

```yaml
      - path: TunnelBahn/Services/SpeedTestHelperClient.swift
```

Run: `xcodegen generate`

- [ ] **Step 5: Run tests to verify they pass**

Run the Tests command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Build and commit**

Run the Build command, expect success, then:

```bash
git add TunnelBahn/Services/SpeedTestHelperClient.swift Tests/Unit/SpeedTestHelperClientTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(speedtest): host-side helper client with tested NDJSON reducer"
```

---

### Task 5: Per-card run mechanisms and UI enablement

**Files:**
- Modify: `TunnelBahn/Services/SpeedTestService.swift`
- Modify: `TunnelBahn/Views/SpeedTestView.swift`

**Interfaces:**
- Consumes: `SpeedTestEngine` (Task 2), `SpeedTestHelperClient` (Task 4), `vpnManager.stats` (`state`, `tunnelHasDefaultRoute`, `hostAppInternetPathIsTunnel`, `connectedProfileID`).
- Produces: `SpeedTestService.canRun(_ path: SpeedTestPath) -> Bool` and `SpeedTestService.run(path: SpeedTestPath)` (replacing `run()`, `currentPath`, `currentPathProfileName`). The view calls only these plus existing published state.

Note: until Task 6 lands, `hostAppInternetPathIsTunnel` still reflects the old host-inclusion logic, so the Direct card in app-tunnel mode only enables after Task 6. That is expected mid-plan state.

- [ ] **Step 1: Rework SpeedTestService entry points**

Replace `currentPath` and `currentPathProfileName` and `run()` with:

```swift
    /// Whether the given card's Run button should be enabled. Tunnel runs go through the
    /// bundled helper, so they only need a connected tunnel that routes internet traffic
    /// (default-route profile, no destination split). Direct runs go through the host app,
    /// so they need the host's own path to be direct.
    func canRun(_ path: SpeedTestPath) -> Bool {
        guard !isRunning else { return false }
        let stats = vpnManager.stats
        switch path {
        case .tunnel:
            return stats.state == .connected && stats.tunnelHasDefaultRoute
        case .direct:
            return stats.state != .connected || !stats.hostAppInternetPathIsTunnel
        }
    }

    /// Connected profile name, for labeling tunnel results.
    private var connectedProfileName: String? {
        guard let id = vpnManager.stats.connectedProfileID else { return nil }
        return profileStore.profiles.first(where: { $0.id == id })?.name
    }

    func run(path: SpeedTestPath) {
        guard canRun(path) else { return }
        // Set the phase synchronously: `isRunning` derives from `phase`, and it is only observed
        // after the spawned Task starts, so two back-to-back `run` calls could both pass the
        // guard and start duplicate runs.
        phase = .latency
        errorMessage = nil
        statusNote = nil
        runningPath = path
        let profileName = path == .tunnel ? connectedProfileName : nil
        Self.log.notice("[APPSPLIT_SPEEDTEST] run begin path=\(path.rawValue) mechanism=\(path == .tunnel ? "helper" : "in-process")")
        runTask = Task { [weak self] in
            await self?.performRun(path: path, profileName: profileName)
        }
    }
```

In `performRun`, select the mechanism:

```swift
            let onEvent: @Sendable (SpeedTestEngineEvent) -> Void = { [weak self] event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            let payload: SpeedTestRunPayload
            switch path {
            case .tunnel:
                payload = try await SpeedTestHelperClient().run(onEvent: onEvent)
            case .direct:
                payload = try await SpeedTestEngine().run(onEvent: onEvent)
            }
```

(The rest of `performRun` from Task 2 is unchanged.)

- [ ] **Step 2: Broaden the auto-cancel signature**

In the `init` subscription, extend `PathSignature` so helper-relevant changes (e.g. destination split toggling `tunnelHasDefaultRoute`) also cancel a mid-flight run:

```swift
        struct PathSignature: Equatable {
            let state: VPNConnectionState
            let isTunnel: Bool
            let tunnelHasDefaultRoute: Bool
        }
        vpnManager.$stats
            .map { PathSignature(state: $0.state, isTunnel: $0.hostAppInternetPathIsTunnel, tunnelHasDefaultRoute: $0.tunnelHasDefaultRoute) }
```

(The sink body is unchanged.)

- [ ] **Step 3: Update SpeedTestView**

In `resultCard`, replace the enablement line and Run action:

```swift
        let isCardRunning = service.runningPath == path
        let canRun = service.canRun(path)
```

and

```swift
                        Button("Run") { service.run(path: path) }
                            .disabled(!canRun)
```

Update the strings at the two `resultCard` call sites (no em dashes, tooltip idiom unchanged):

```swift
                    resultCard(
                        path: .tunnel,
                        title: "Tunnel",
                        result: service.tunnelResult,
                        emptyHint: "Connect a tunnel and run the test to fill this column.",
                        enabledTooltip: "Runs through the connected tunnel using a bundled helper, even in per-app mode.",
                        disabledTooltip: "Connect a tunnel that routes internet traffic to enable this test."
                    )
                    resultCard(
                        path: .direct,
                        title: "Direct",
                        result: service.directResult,
                        emptyHint: "Run while the tunnel is down, or while a per-app tunnel is active, to fill this column.",
                        enabledTooltip: "Measures TunnelBahn's own traffic outside the tunnel.",
                        disabledTooltip: "Disconnect the tunnel to test the direct path. A full tunnel cannot be bypassed."
                    )
```

Also update the stale comment above `let isCardRunning` (it currently claims exactly one button is enabled at a time): replace with

```swift
        // Tunnel runs use the bundled helper, Direct runs use the host app, so in per-app
        // mode both cards can be enabled at once; a running test disables the other card.
```

- [ ] **Step 4: Build and test**

Run the Build command, expect `** BUILD SUCCEEDED **`. Run the Tests command, expect `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Services/SpeedTestService.swift TunnelBahn/Views/SpeedTestView.swift
git commit -m "feat(speedtest): tunnel card runs via helper, per-card enablement"
```

---

### Task 6: Probe migration, helper NEAppRule, setting deletion

**Files:**
- Move: `TunnelBahn/Services/TunnelConnectivityProbe.swift` -> `SpeedTestHelper/TunnelConnectivityProbe.swift` (`git mv`)
- Create: `Shared/ConnectivityProbeResult.swift` (enum moved out of `TunnelBahn/Models/ConnectionStats.swift`)
- Modify: `Shared/SpeedTestHelperProtocol.swift` (add `TunnelProbePhase`), `SpeedTestHelper/main.swift` (probe command), `TunnelBahn/Services/SpeedTestHelperClient.swift` (probe func), `TunnelBahn/Services/VPNManager.swift`, `TunnelBahn/Services/AppSettings.swift`, `TunnelBahn/Views/SettingsView.swift`, `TunnelBahn/AppState.swift`, `TunnelBahn/Services/AppBackup.swift`, `TunnelBahn/Services/BackupService.swift`, `TunnelBahn/Models/ConnectionStats.swift`, `project.yml` (helper sources)

**Interfaces:**
- Consumes: everything above.
- Produces: `enum TunnelProbePhase: String` with cases `fullTunnel = "full_tunnel"`, `appTunnel = "app_tunnel"` (in the protocol file); helper CLI `probe --mode warmup|recheck --phase full_tunnel|app_tunnel` printing one `SpeedTestHelperProbeOutcome` JSON line; `SpeedTestHelperClient.probe(mode: String, phase: TunnelProbePhase) async -> ConnectivityProbeResult`.

- [ ] **Step 1: Move ConnectivityProbeResult to Shared**

Cut the `ConnectivityProbeResult` enum (top of `TunnelBahn/Models/ConnectionStats.swift`, around line 3; verify its exact cases, expected `unknown`, `ok`, `failed(String)`) into a new file `Shared/ConnectivityProbeResult.swift` with `import Foundation`. `ConnectionStats.swift` keeps using it unchanged (Shared is compiled into the app and both extensions, so nothing else moves).

- [ ] **Step 2: Simplify TunnelProbePhase and move it to the protocol file**

In `Shared/SpeedTestHelperProtocol.swift` add:

```swift
/// Where the active connection routes app-initiated internet traffic. Raw values are the
/// helper CLI names and the `APPSPLIT_PROBE` log field.
enum TunnelProbePhase: String {
    /// Everything tunnels (default-route profile without per-app selection).
    case fullTunnel = "full_tunnel"
    /// Per-app tunnel; only NEAppRule-listed processes (including the helper) tunnel.
    case appTunnel = "app_tunnel"
}
```

Delete the old three-case `TunnelProbePhase` from `TunnelConnectivityProbe.swift`.

- [ ] **Step 3: Move and trim TunnelConnectivityProbe**

```bash
git mv TunnelBahn/Services/TunnelConnectivityProbe.swift SpeedTestHelper/TunnelConnectivityProbe.swift
```

Edits inside the file:
- Remove the `comparePublicIP` parameter from `warmup` and `probeIpify` (every live call passes nil). `probeIpify` keeps fetching and logging the ipify IP but drops the `vs_publicIP`/`compare=` fields from its log line.
- Everything else (attempt counts, timeouts, google204, DNS diagnostics, log lines) stays unchanged; it now runs inside the helper process, whose traffic is tunneled, and its `AppLog` lines still reach the in-app Logs view via `SharedLogWriter`.

- [ ] **Step 4: Add the probe command to main.swift**

In `SpeedTestHelper/main.swift`, extend the `switch`:

```swift
case "probe":
    var mode: String?
    var phaseRaw: String?
    var rest = arguments.dropFirst().makeIterator()
    while let flag = rest.next() {
        switch flag {
        case "--mode": mode = rest.next()
        case "--phase": phaseRaw = rest.next()
        default: usageExit()
        }
    }
    guard let mode, ["warmup", "recheck"].contains(mode),
          let phase = TunnelProbePhase(rawValue: phaseRaw ?? "")
    else { usageExit() }
    let result = mode == "warmup"
        ? await TunnelConnectivityProbe.warmup(phase: phase)
        : await TunnelConnectivityProbe.recheck(phase: phase)
    let outcome: SpeedTestHelperProbeOutcome = switch result {
    case .ok: SpeedTestHelperProbeOutcome(ok: true)
    case .failed(let message): SpeedTestHelperProbeOutcome(ok: false, message: message)
    case .unknown: SpeedTestHelperProbeOutcome(ok: false, message: "probe returned no result")
    }
    if let data = try? JSONEncoder().encode(outcome), let s = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    exit(0)
```

Update `usageExit()`'s usage string to `"usage: SpeedTestHelper run | probe --mode warmup|recheck --phase full_tunnel|app_tunnel\n"`. Adjust the case labels to the exact `ConnectivityProbeResult` cases found in Step 1.

- [ ] **Step 5: Add helper sources to project.yml and regenerate**

In the `SpeedTestHelper` target sources add:

```yaml
      - path: Shared/ConnectivityProbeResult.swift
```

(`SpeedTestHelper/TunnelConnectivityProbe.swift` is picked up by the existing `- path: SpeedTestHelper` entry. `Shared/ConnectivityProbeResult.swift` is picked up automatically by targets that compile all of `Shared/`, but the helper lists Shared files individually.)

Run: `xcodegen generate`

- [ ] **Step 6: Add probe to SpeedTestHelperClient**

```swift
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
```

- [ ] **Step 7: Rework VPNManager**

All changes in `TunnelBahn/Services/VPNManager.swift`:

1. Rename `makeHostAppNEAppRule()` (around line 991) to `makeSpeedTestHelperNEAppRule()`:

```swift
    /// The bundled speed test helper is always merged into app-tunnel NEAppRules so tunnel-side
    /// speed tests and connectivity probes run through the tunnel while the host app stays direct.
    private func makeSpeedTestHelperNEAppRule() -> NEAppRule? {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/\(SpeedTestHelperConstants.executableName)").path
        guard FileManager.default.fileExists(atPath: path) else {
            traceLog("speed test helper: binary missing at \(path); no helper NEAppRule")
            return nil
        }
        let requirement: String
        if let designated = NEAppRuleBuilder.designatedRequirementString(forAppAtPath: path, log: traceLog) {
            requirement = designated
        } else {
            requirement = #"anchor apple generic and identifier "\#(SpeedTestHelperConstants.signingIdentifier)""#
            traceLog("speed test helper: designated requirement unavailable; using fallback")
        }
        return NEAppRule(
            signingIdentifier: SpeedTestHelperConstants.signingIdentifier,
            designatedRequirement: requirement
        )
    }
```

2. At all five rule-merge sites (lines ~441, ~462, ~485, ~496, ~507): drop the `settings.includeHostAppInPerAppRulesForProbe` condition and rename the call, e.g. line 441 becomes:

```swift
            if useAppTunnelNEStack, let helperRule = makeSpeedTestHelperNEAppRule() {
                rulesForVPNManager = NEAppRuleBuilder.dedupe(
                    rulesForVPNManager + [helperRule],
                    log: traceLog,
                    verbose: Self.vpnTraceVerbose
                )
                traceLog(
                    "speed test helper: merged helper NEAppRule signingID=\(helperRule.matchSigningIdentifier) totalRules=\(rulesForVPNManager.count)"
                )
            }
```

and the four inner sites become `if let helperRule = makeSpeedTestHelperNEAppRule() { tunnelRules.append(helperRule) }` (they are already inside `useAppTunnelNEStack` branches).

3. Probe phase and classification (lines ~944-954):

```swift
        let probePhase: TunnelProbePhase =
            (useAppTunnelNEStack && hasAppTunnelSelection) ? .appTunnel : .fullTunnel
        // Speed test path classification: TunnelBahn's own internet traffic uses the tunnel only
        // when the tunnel owns the default route AND everything tunnels. In app-tunnel mode the
        // host app is never in the NEAppRule list (only the bundled helper is), so it stays direct.
        stats.hostAppInternetPathIsTunnel =
            stats.tunnelHasDefaultRoute && probePhase == .fullTunnel
```

4. Warmup call (line ~980):

```swift
                let result = await SpeedTestHelperClient.probe(mode: "warmup", phase: probePhase)
```

5. Periodic recheck (line ~1816):

```swift
                let result = await SpeedTestHelperClient.probe(mode: "recheck", phase: phase)
```

- [ ] **Step 8: Delete the setting everywhere**

- `TunnelBahn/Services/AppSettings.swift`: delete the `includeHostAppInPerAppRulesForProbe` published property (lines ~31-33), its `Keys` entry, its `init` line, and its `save()` line.
- `TunnelBahn/Views/SettingsView.swift`: delete the whole `Toggle(isOn: $appState.settings.includeHostAppInPerAppRulesForProbe) { ... }` block including its `.disabled(...)` modifier (lines ~49-57).
- `TunnelBahn/AppState.swift`: delete line ~415 `settings.includeHostAppInPerAppRulesForProbe = true`.
- `TunnelBahn/Services/AppBackup.swift`: delete `var includeHostAppInPerAppRulesForProbe: Bool` from `AppSettingsSnapshot`.
- `TunnelBahn/Services/BackupService.swift`: delete the field from the `AppSettingsSnapshot(...)` initializer (line ~97) and the restore assignment (line ~168). (Old backup files with the extra JSON key still decode; extra keys are ignored by Codable. No shim.)
- Verify zero references remain: `grep -rn includeHostAppInPerAppRulesForProbe TunnelBahn Shared NetworkExtension TransparentProxyExtension Tests` must print nothing.

- [ ] **Step 9: Build and test**

Run the Build command, expect `** BUILD SUCCEEDED **`. Run the Tests command, expect `** TEST SUCCEEDED **`.

- [ ] **Step 10: Smoke-run the helper probe directly**

```bash
APP=$(xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')/TunnelBahn.app
"$APP/Contents/MacOS/SpeedTestHelper" probe --mode recheck --phase full_tunnel
```

Expected: one line, `{"ok":true}` (on a working network).

- [ ] **Step 11: Commit**

```bash
git add -A SpeedTestHelper Shared TunnelBahn project.yml TunnelBahn.xcodeproj Tests
git commit -m "feat(speedtest): probe runs in tunneled helper; delete host-inclusion setting"
```

---

### Task 7: Final verification

**Files:** none created; this is a verification pass.

- [ ] **Step 1: Clean build and full unit tests**

Run the Build command and the Tests command from Global Constraints. Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

- [ ] **Step 2: Confirm helper embedding and rule inputs**

```bash
APP=$(xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')/TunnelBahn.app
codesign -dv "$APP/Contents/MacOS/SpeedTestHelper" 2>&1 | grep -E "Identifier|flags"
codesign --verify --deep --strict "$APP" && echo APP_SIGNATURE_OK
```

Expected: `Identifier=com.tunnelbahn.mac.speedtesthelper`, runtime flag present, `APP_SIGNATURE_OK`.

- [ ] **Step 3: Manual end-to-end checklist (requires the user's VPN profiles; report results, ask the user to exercise what you cannot)**

1. Launch the app. While disconnected: Direct card enabled, Tunnel card disabled with its tooltip.
2. Connect a full-tunnel profile: Tunnel enabled (runs via helper), Direct disabled ("A full tunnel cannot be bypassed" tooltip). Run Tunnel; expect phases, live readout, a result with the profile name, and `[APPSPLIT_SPEEDTEST]` lines in Logs.
3. Connect a per-app profile: BOTH cards enabled. Run Tunnel (helper, tunneled numbers), then Direct (host, direct numbers). While one runs, the other card's Run is disabled.
4. Check Logs for `[APPSPLIT_PROBE]` warmup lines emitted by the helper after connect, and probe status OK in the UI.
5. Cancel a run mid-download: card returns to idle, previous result untouched. Disconnect mid-run: "Test cancelled: traffic path changed".

- [ ] **Step 4: Update the spec status line**

In `docs/superpowers/specs/2026-08-01-speedtest-helper-design.md` change `Status: Approved pending user review` to `Status: Implemented`. Commit:

```bash
git add docs/superpowers/specs/2026-08-01-speedtest-helper-design.md
git commit -m "docs: mark speed test helper spec implemented"
```

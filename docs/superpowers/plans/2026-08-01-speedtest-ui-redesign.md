# Speed Test UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the Speed Test view with hero numbers, live in-place charts during a run, a phase indicator, and a color-coded Tunnel vs Direct comparison strip, per `docs/superpowers/specs/2026-08-01-speedtest-ui-redesign-design.md`.

**Architecture:** `SpeedTestService` (MainActor ObservableObject, owned by AppState) gains a published `LiveRunData` value updated on each sample tick; `SpeedTestView` is rebuilt around a shared throughput-block component used identically for finished and live data, so the card never collapses while running. Delta better/worse classification is pure math in `SpeedTestMath`, unit-tested.

**Tech Stack:** SwiftUI + Swift Charts, XCTest, XcodeGen project (`project.yml`), scheme `TunnelBahn`, unit test target `TunnelBahnUnitTests`.

## Global Constraints

- No compat shims, schemaVersion fields, or migrations; delete replaced code outright (no-legacy-code policy).
- UI explanations use the `questionmark.circle` + `.instantTooltip(...)` idiom, never inline footnotes.
- No em dashes in UI strings; tooltips one or two short sentences.
- All new view code stays in `TunnelBahn/Views/SpeedTestView.swift` (no new files, so no `xcodegen` regeneration needed).
- Build: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug -destination 'platform=macOS' build`
- Unit tests: `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/SpeedTestMathTests`

---

### Task 1: Delta sense classification in SpeedTestMath

**Files:**
- Modify: `TunnelBahn/Services/SpeedTestMath.swift` (append to the enum)
- Test: `Tests/Unit/SpeedTestMathTests.swift` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces: `SpeedTestMath.DeltaSense` (`case better, worse, neutral`) and `SpeedTestMath.deltaSense(_ delta: Double, lowerIsBetter: Bool, neutralBand: Double) -> DeltaSense`. Task 4 calls this to color the comparison strip.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/Unit/SpeedTestMathTests.swift` (inside the class, after the delta percent tests, following the existing `// MARK:` style):

```swift
    // MARK: - delta sense

    func testDeltaSenseHigherIsBetterPositiveDelta() {
        XCTAssertEqual(SpeedTestMath.deltaSense(10, lowerIsBetter: false, neutralBand: 3), .better)
    }

    func testDeltaSenseHigherIsBetterNegativeDelta() {
        XCTAssertEqual(SpeedTestMath.deltaSense(-10, lowerIsBetter: false, neutralBand: 3), .worse)
    }

    func testDeltaSenseLowerIsBetterNegativeDelta() {
        XCTAssertEqual(SpeedTestMath.deltaSense(-10, lowerIsBetter: true, neutralBand: 2), .better)
    }

    func testDeltaSenseLowerIsBetterPositiveDelta() {
        XCTAssertEqual(SpeedTestMath.deltaSense(10, lowerIsBetter: true, neutralBand: 2), .worse)
    }

    func testDeltaSenseInsideNeutralBandIsNeutral() {
        XCTAssertEqual(SpeedTestMath.deltaSense(2.9, lowerIsBetter: false, neutralBand: 3), .neutral)
        XCTAssertEqual(SpeedTestMath.deltaSense(-2.9, lowerIsBetter: false, neutralBand: 3), .neutral)
        XCTAssertEqual(SpeedTestMath.deltaSense(3, lowerIsBetter: false, neutralBand: 3), .neutral)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/SpeedTestMathTests`
Expected: BUILD FAILURE, `deltaSense` and `DeltaSense` not found.

- [ ] **Step 3: Implement**

Append inside `enum SpeedTestMath` in `TunnelBahn/Services/SpeedTestMath.swift`, after `deltaPercent`:

```swift
    /// Whether a signed delta is an improvement, a regression, or noise.
    enum DeltaSense {
        case better, worse, neutral
    }

    /// Classifies a signed delta (tunnel minus direct, or a percent change) for display.
    /// Deltas whose magnitude is at or below `neutralBand` count as noise.
    static func deltaSense(_ delta: Double, lowerIsBetter: Bool, neutralBand: Double) -> DeltaSense {
        guard abs(delta) > neutralBand else { return .neutral }
        let improved = lowerIsBetter ? delta < 0 : delta > 0
        return improved ? .better : .worse
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: TEST SUCCEEDED, all `SpeedTestMathTests` pass.

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Services/SpeedTestMath.swift Tests/Unit/SpeedTestMathTests.swift
git commit -m "feat(speedtest): delta sense classification for comparison coloring"
```

---

### Task 2: Service publishes live run data

> Revised 2026-08-01 after the speed test helper feature landed (commits baa2ffb..2ba0f17): measurement now lives in `Shared/SpeedTestEngine` (compiled into the host app and the `SpeedTestHelper` executable) and streams `SpeedTestEngineEvent`s; tunnel runs arrive over NDJSON via `SpeedTestHelperClient`. The service reconstructs live chart data from those events instead of sampling directly.

**Files:**
- Modify: `Shared/SpeedTestEngine.swift` (new event case + emit)
- Modify: `Shared/SpeedTestHelperProtocol.swift` (two optional fields on `SpeedTestHelperLine`)
- Modify: `SpeedTestHelper/main.swift` (map the new event)
- Modify: `TunnelBahn/Services/SpeedTestHelperClient.swift` (decode the new event)
- Modify: `TunnelBahn/Services/SpeedTestService.swift` (replace `liveReadout` with `liveRun`)
- Modify: `TunnelBahn/Views/SpeedTestView.swift` (minimal compile fix only; Task 3 rewrites this file)
- Modify: `docs/superpowers/specs/2026-08-01-speedtest-ui-redesign-design.md` (one bullet)
- Test: `Tests/Unit/SpeedTestHelperClientTests.swift` (TDD for the reducer change)

**Interfaces:**
- Consumes: `SpeedTestMath.throughputMbps(bytes:seconds:)`, `SpeedTestMath.throughputSeries(cumulative:)`, `ThroughputSample`, `SpeedTestEngineEvent`, `SpeedTestHelperLine` (all existing).
- Produces:
  - `SpeedTestEngineEvent.latencySummary(medianMs: Double, jitterMs: Double)` — emitted once, after the latency phase completes, before the download phase event. NDJSON wire form: `{"event":"latency_summary","medianLatencyMs":<d>,"jitterMs":<d>}`.
  - On `SpeedTestService`: `struct LiveRunData` with `var latencyReadout: String?`, `var latencyMs: Double?`, `var jitterMs: Double?`, `var download: LiveTransfer?`, `var upload: LiveTransfer?`, and nested `struct LiveTransfer { var mbps: Double; var samples: [ThroughputSample] }`; plus `@Published private(set) var liveRun: LiveRunData?` (non-nil exactly while a run is active). `LiveTransfer.mbps` is the whole-window average so far. Task 3's view reads these.
  - `liveReadout` is REMOVED (no-legacy policy).

- [ ] **Step 1: Write the failing reducer test**

Append inside the class in `Tests/Unit/SpeedTestHelperClientTests.swift`:

```swift
    func testLatencySummaryLineEmitsEvent() throws {
        var events: [SpeedTestEngineEvent] = []
        let payload = try SpeedTestHelperClient.reduce(
            line: line(SpeedTestHelperLine(event: "latency_summary", medianLatencyMs: 24.5, jitterMs: 3.1))
        ) { events.append($0) }
        XCTAssertNil(payload)
        XCTAssertEqual(events, [.latencySummary(medianMs: 24.5, jitterMs: 3.1)])
    }

    func testLatencySummaryLineWithoutValuesThrows() {
        XCTAssertThrowsError(
            try SpeedTestHelperClient.reduce(line: #"{"event":"latency_summary"}"#) { _ in }
        )
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/SpeedTestHelperClientTests`
Expected: BUILD FAILURE (`latencySummary` case and `medianLatencyMs:`/`jitterMs:` initializer arguments do not exist yet).

- [ ] **Step 3: Implement the protocol event end to end**

1. `Shared/SpeedTestEngine.swift` — extend the event enum:

```swift
enum SpeedTestEngineEvent: Equatable {
    case phase(SpeedTestPhaseName)
    case sample(readout: String, offsetSeconds: Double?, bytes: Int?)
    /// Emitted once, after the latency phase completes, so the UI can show the
    /// settled median and jitter while the transfer phases run.
    case latencySummary(medianMs: Double, jitterMs: Double)
}
```

In `SpeedTestEngine.run(onEvent:)`, after `let latency = try await measureLatency(onEvent: onEvent)` add:

```swift
        onEvent(.latencySummary(medianMs: latency.median, jitterMs: latency.jitter))
```

2. `Shared/SpeedTestHelperProtocol.swift` — add two optional fields to `SpeedTestHelperLine` (after `bytes`), and extend the doc comment's event list with `"latency_summary" -> medianLatencyMs + jitterMs`:

```swift
    var medianLatencyMs: Double? = nil
    var jitterMs: Double? = nil
```

3. `SpeedTestHelper/main.swift` — add to the `switch event` in the `run` handler:

```swift
            case .latencySummary(let medianMs, let jitterMs):
                emit(SpeedTestHelperLine(event: "latency_summary", medianLatencyMs: medianMs, jitterMs: jitterMs))
```

4. `TunnelBahn/Services/SpeedTestHelperClient.swift` — add to the `switch decoded.event` in `reduce(line:onEvent:)` (before `"result"`):

```swift
        case "latency_summary":
            guard let median = decoded.medianLatencyMs, let jitter = decoded.jitterMs else {
                throw SpeedTestHelperClientError.malformedLine(String(line.prefix(200)))
            }
            onEvent(.latencySummary(medianMs: median, jitterMs: jitter))
            return nil
```

- [ ] **Step 4: Run the reducer tests to verify they pass**

Same command as Step 2. Expected: TEST SUCCEEDED, all `SpeedTestHelperClientTests` pass.

- [ ] **Step 5: Replace `liveReadout` with `liveRun` in the service**

In `TunnelBahn/Services/SpeedTestService.swift`:

1. Replace the `liveReadout` property (`@Published private(set) var liveReadout: String?` and its doc comment) with:

```swift
    /// In-flight run data for the UI, filled in as events arrive; nil while idle.
    /// `LiveTransfer.mbps` is the whole-window average so far, so it converges to the
    /// final figure; `samples` are per-interval instantaneous rates for the live chart.
    struct LiveRunData {
        /// Ticking text during the latency phase ("24 ms"); superseded by `latencyMs`.
        var latencyReadout: String?
        var latencyMs: Double?
        var jitterMs: Double?
        var download: LiveTransfer?
        var upload: LiveTransfer?

        struct LiveTransfer {
            var mbps: Double
            var samples: [ThroughputSample]
        }
    }

    @Published private(set) var liveRun: LiveRunData?
```

2. Add a private accumulator property next to `runTask`:

```swift
    /// Cumulative (offset, bytes) points of the transfer phase currently running; reset on
    /// each phase event. Kept host-side so live charts work identically for helper runs.
    private var transferCumulative: [(offsetSeconds: Double, bytes: Int)] = []
```

3. In `run(path:)`, after `runningPath = path`, add:

```swift
        liveRun = LiveRunData()
```

4. In `performRun`'s `defer` block, replace `liveReadout = nil` with:

```swift
            liveRun = nil
            transferCumulative = []
```

5. Replace the whole `apply(_ event:)` method with:

```swift
    /// Maps engine/helper progress events onto the published UI state. Ignores events
    /// arriving after the run ended (phase == .idle) so a late Task hop cannot resurrect UI.
    private func apply(_ event: SpeedTestEngineEvent) {
        guard phase != .idle || runningPath != nil else { return }
        switch event {
        case .phase(let name):
            transferCumulative = []
            switch name {
            case .latency: phase = .latency
            case .download: phase = .download
            case .upload: phase = .upload
            }
        case .latencySummary(let medianMs, let jitterMs):
            liveRun?.latencyMs = medianMs
            liveRun?.jitterMs = jitterMs
        case .sample(let readout, let offsetSeconds, let bytes):
            guard let offsetSeconds, let bytes else {
                liveRun?.latencyReadout = readout
                return
            }
            transferCumulative.append((offsetSeconds: offsetSeconds, bytes: bytes))
            let transfer = LiveRunData.LiveTransfer(
                mbps: SpeedTestMath.throughputMbps(bytes: bytes, seconds: offsetSeconds),
                samples: SpeedTestMath.throughputSeries(cumulative: transferCumulative)
            )
            switch phase {
            case .download: liveRun?.download = transfer
            case .upload: liveRun?.upload = transfer
            case .latency, .idle: break
            }
        }
    }
```

- [ ] **Step 6: Minimal view compile fix**

`TunnelBahn/Views/SpeedTestView.swift` reads `service.liveReadout` in the running-state block. Replace that `if let liveReadout = service.liveReadout { ... }` binding with a stand-in so the target still builds (Task 3 deletes it):

```swift
                        if let liveReadout = service.liveRun?.latencyReadout {
                            Text(liveReadout)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
```

- [ ] **Step 7: Update the spec bullet**

In `docs/superpowers/specs/2026-08-01-speedtest-ui-redesign-design.md`, replace the service-change section's bullets with:

```markdown
- `SpeedTestEngine` emits a new `latencySummary` event after the latency phase (NDJSON `latency_summary` line from the helper), carrying the settled median and jitter.
- `liveReadout` is replaced by `SpeedTestService.liveRun: LiveRunData?`, reconstructed host-side from engine/helper events: the latency ticking text, the settled latency median and jitter, and per transfer phase the whole-window average Mbps (the hero number, converging to the final figure) plus the instantaneous sample series (the live chart). Number and chart come from the same tick, so they always agree.
```

- [ ] **Step 8: Build and grep for leftovers**

Run: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. Then `grep -rn liveReadout TunnelBahn Shared SpeedTestHelper` must return only the engine's event `readout:` parameter usages, no `liveReadout` property references (the identifier should not appear at all).

- [ ] **Step 9: Commit**

```bash
git add Shared/SpeedTestEngine.swift Shared/SpeedTestHelperProtocol.swift SpeedTestHelper/main.swift TunnelBahn/Services/SpeedTestHelperClient.swift TunnelBahn/Services/SpeedTestService.swift TunnelBahn/Views/SpeedTestView.swift Tests/Unit/SpeedTestHelperClientTests.swift docs/superpowers/specs/2026-08-01-speedtest-ui-redesign-design.md
git commit -m "feat(speedtest): latency summary event; service publishes live run data"
```

---

### Task 3: Rebuild the result card (hero numbers, live blocks, phase indicator)

**Files:**
- Modify: `TunnelBahn/Views/SpeedTestView.swift` (full rewrite of card internals; header/Run/Cancel logic and the surrounding scroll layout keep their current behavior)

**Interfaces:**
- Consumes: `service.liveRun` (Task 2), `service.phase`, `service.runningPath`, `service.canRun(_:)`, `service.run(path:)`, `SpeedTestResult`, `.instantTooltip(_:)`.
- Produces: private view helpers used only within this file: `throughputBlock(label:icon:tint:mbps:samples:isLive:)`, `sparkline(samples:tint:)`, `latencyFooter(latency:jitter:caption:)`, `smallMetric(label:value:)`, `phaseIndicator`, `runningBody(live:)`, `finishedBody(result:)`. Task 4 relies on the top-level `body` still containing the `deltaRow` slot below the two cards.

- [ ] **Step 1: Rewrite the card internals**

Replace everything in `SpeedTestView` from `phaseLabel` through `sparkline(samples:)` (keep `deltaRow`, `signedPercent`, `signedMs` for now; Task 4 replaces them). The `body`'s outer structure (ScrollView, error/status texts, two-card HStack, `deltaRow`, padding, navigation title) is unchanged. Add these constants at the top of the struct:

```swift
    private static let downloadTint = Color.blue
    private static let uploadTint = Color.green
    /// Keeps empty, running, and filled card bodies the same height so the columns align.
    private static let cardBodyMinHeight: CGFloat = 280
```

New card and helpers:

```swift
    // MARK: - Result cards

    @ViewBuilder
    private func resultCard(
        path: SpeedTestPath,
        title: String,
        result: SpeedTestResult?,
        emptyHint: String,
        enabledTooltip: String,
        disabledTooltip: String
    ) -> some View {
        // Tunnel runs use the bundled helper, Direct runs use the host app, so in per-app
        // mode both cards can be enabled at once; a running test disables the other card.
        let isCardRunning = service.runningPath == path
        let canRun = service.canRun(path)
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    if let profileName = result?.profileName {
                        Text(profileName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .instantTooltip(canRun || isCardRunning ? enabledTooltip : disabledTooltip)
                    Spacer()
                    if isCardRunning {
                        Button("Cancel") { service.cancel() }
                    } else {
                        Button("Run") { service.run(path: path) }
                            .disabled(!canRun)
                    }
                }
                Divider()
                Group {
                    if isCardRunning, let live = service.liveRun {
                        runningBody(live: live)
                    } else if let result {
                        finishedBody(result: result)
                    } else {
                        Text(emptyHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.cardBodyMinHeight, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runningBody(live: SpeedTestService.LiveRunData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            phaseIndicator
            throughputBlock(
                label: "Download",
                icon: "arrow.down",
                tint: Self.downloadTint,
                mbps: live.download?.mbps,
                samples: live.download?.samples ?? [],
                isLive: service.phase == .download
            )
            throughputBlock(
                label: "Upload",
                icon: "arrow.up",
                tint: Self.uploadTint,
                mbps: live.upload?.mbps,
                samples: live.upload?.samples ?? [],
                isLive: service.phase == .upload
            )
            latencyFooter(
                latency: live.latencyMs.map { String(format: "%.0f ms", $0) } ?? live.latencyReadout,
                jitter: live.jitterMs.map { String(format: "%.1f ms", $0) },
                caption: nil
            )
        }
    }

    private func finishedBody(result: SpeedTestResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            throughputBlock(
                label: "Download",
                icon: "arrow.down",
                tint: Self.downloadTint,
                mbps: result.downloadMbps,
                samples: result.downloadSamples,
                isLive: false
            )
            throughputBlock(
                label: "Upload",
                icon: "arrow.up",
                tint: Self.uploadTint,
                mbps: result.uploadMbps,
                samples: result.uploadSamples,
                isLive: false
            )
            latencyFooter(
                latency: String(format: "%.0f ms", result.medianLatencyMs),
                jitter: String(format: "%.1f ms", result.jitterMs),
                caption: "Tested \(result.finishedAt.formatted(.relative(presentation: .named)))"
            )
        }
    }

    // MARK: - Building blocks

    /// One metric section: colored caption row, hero number, sparkline. A nil `mbps`
    /// renders dimmed placeholders so the card height stays stable while phases pend.
    private func throughputBlock(
        label: String,
        icon: String,
        tint: Color,
        mbps: Double?,
        samples: [ThroughputSample],
        isLive: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
                if isLive {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(mbps.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(mbps == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                Text("Mbps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if samples.isEmpty {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.4))
                    .frame(height: 56)
            } else {
                sparkline(samples: samples, tint: tint)
            }
        }
    }

    private func sparkline(samples: [ThroughputSample], tint: Color) -> some View {
        let average = samples.map(\.mbps).reduce(0, +) / Double(samples.count)
        return Chart {
            ForEach(samples, id: \.offsetSeconds) { sample in
                AreaMark(
                    x: .value("Time", sample.offsetSeconds),
                    y: .value("Mbps", sample.mbps)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", sample.offsetSeconds),
                    y: .value("Mbps", sample.mbps)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Average", average))
                .foregroundStyle(tint.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 56)
    }

    private func latencyFooter(latency: String?, jitter: String?, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 24) {
                smallMetric(label: "Latency", value: latency)
                smallMetric(label: "Jitter", value: jitter)
                Spacer()
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func smallMetric(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "--")
                .font(.callout.monospacedDigit())
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
    }

    // MARK: - Phase indicator

    private var phaseIndicator: some View {
        HStack(spacing: 14) {
            phaseStep("Latency", .latency)
            phaseStep("Download", .download)
            phaseStep("Upload", .upload)
            Spacer()
        }
    }

    private func phaseStep(_ label: String, _ step: SpeedTestService.Phase) -> some View {
        HStack(spacing: 4) {
            if Self.phaseOrder(service.phase) > Self.phaseOrder(step) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if service.phase == step {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.quaternary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(service.phase == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
    }

    /// Position of a phase in the run pipeline; `.idle` sorts last so a finished
    /// run shows every step checked.
    private static func phaseOrder(_ phase: SpeedTestService.Phase) -> Int {
        switch phase {
        case .latency: 0
        case .download: 1
        case .upload: 2
        case .idle: 3
        }
    }
```

Delete the old `phaseLabel` property, the old running-state spinner block, the old `metricRow`, and the old `sparkline(samples:)`.

- [ ] **Step 2: Build**

Run: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add TunnelBahn/Views/SpeedTestView.swift
git commit -m "feat(speedtest): hero numbers, live in-place charts, phase indicator"
```

---

### Task 4: Color-coded comparison strip

**Files:**
- Modify: `TunnelBahn/Views/SpeedTestView.swift` (replace `deltaRow` and its helpers)

**Interfaces:**
- Consumes: `SpeedTestMath.deltaPercent(tunnel:direct:)`, `SpeedTestMath.deltaSense(_:lowerIsBetter:neutralBand:)` (Task 1), `service.tunnelResult` / `service.directResult`.
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Replace the delta row**

In `SpeedTestView.body`, rename the `deltaRow` slot usage to `comparisonStrip`. Delete `deltaRow` and replace with (keep `signedPercent`/`signedMs`):

```swift
    // MARK: - Comparison

    /// Neutral bands: throughput deltas within 3 percent and timing deltas within
    /// 2 ms count as run-to-run noise and stay gray.
    private static let throughputNeutralBandPercent = 3.0
    private static let timingNeutralBandMs = 2.0

    @ViewBuilder
    private var comparisonStrip: some View {
        if let tunnel = service.tunnelResult, let direct = service.directResult {
            GroupBox {
                HStack(alignment: .top, spacing: 24) {
                    Text("Tunnel vs Direct")
                        .font(.callout.weight(.semibold))
                        .padding(.top, 2)
                    if let down = SpeedTestMath.deltaPercent(tunnel: tunnel.downloadMbps, direct: direct.downloadMbps) {
                        deltaItem(
                            label: "Download",
                            value: signedPercent(down),
                            sense: SpeedTestMath.deltaSense(down, lowerIsBetter: false, neutralBand: Self.throughputNeutralBandPercent)
                        )
                    }
                    if let up = SpeedTestMath.deltaPercent(tunnel: tunnel.uploadMbps, direct: direct.uploadMbps) {
                        deltaItem(
                            label: "Upload",
                            value: signedPercent(up),
                            sense: SpeedTestMath.deltaSense(up, lowerIsBetter: false, neutralBand: Self.throughputNeutralBandPercent)
                        )
                    }
                    deltaItem(
                        label: "Latency",
                        value: signedMs(tunnel.medianLatencyMs - direct.medianLatencyMs),
                        sense: SpeedTestMath.deltaSense(tunnel.medianLatencyMs - direct.medianLatencyMs, lowerIsBetter: true, neutralBand: Self.timingNeutralBandMs)
                    )
                    deltaItem(
                        label: "Jitter",
                        value: signedMs(tunnel.jitterMs - direct.jitterMs),
                        sense: SpeedTestMath.deltaSense(tunnel.jitterMs - direct.jitterMs, lowerIsBetter: true, neutralBand: Self.timingNeutralBandMs)
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func deltaItem(label: String, value: String, sense: SpeedTestMath.DeltaSense) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(deltaColor(sense))
        }
    }

    private func deltaColor(_ sense: SpeedTestMath.DeltaSense) -> AnyShapeStyle {
        switch sense {
        case .better: AnyShapeStyle(Color.green)
        case .worse: AnyShapeStyle(Color.red)
        case .neutral: AnyShapeStyle(.secondary)
        }
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add TunnelBahn/Views/SpeedTestView.swift
git commit -m "feat(speedtest): color-coded tunnel vs direct comparison strip"
```

---

### Task 5: End-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Run full unit suite**

Run: `xcodebuild test -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests`
Expected: TEST SUCCEEDED.

- [ ] **Step 2: Manual visual check**

Launch the app (project `run` conventions; the TunnelBahn scheme's Debug build). In the Speed Test tab verify:
1. Empty cards are equal height, hints centered.
2. Press Run on the active card: card keeps its layout; phase indicator steps Latency, Download, Upload; download hero number ticks and the blue chart grows in place; upload block shows dimmed "--" until its phase; latency footer ticks then settles.
3. Cancel mid-run restores the previous result (or empty hint) without layout jumps.
4. After tunnel and direct runs both finish, the comparison strip appears with green/red/gray deltas matching better/worse.
5. Sparklines: blue download, green upload, gradient fill, dashed average rule.

- [ ] **Step 3: Report findings** to the user with a screenshot if possible; fix anything broken before claiming done.

import Charts
import SwiftUI

struct SpeedTestView: View {
    @ObservedObject var service: SpeedTestService

    private static let downloadTint = Color.blue
    private static let uploadTint = Color.green
    /// Keeps empty, running, and filled card bodies the same height so the columns align.
    private static let cardBodyMinHeight: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                        path: .tunnel,
                        title: "Tunnel",
                        result: service.tunnelResult,
                        emptyHint: "Run the test with a tunnel that carries internet traffic to fill this column.",
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
                }
                comparisonStrip
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Speed Test")
    }

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

    private func signedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value)
    }

    private func signedMs(_ value: Double) -> String {
        String(format: "%+.0f ms", value)
    }
}

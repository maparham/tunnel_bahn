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

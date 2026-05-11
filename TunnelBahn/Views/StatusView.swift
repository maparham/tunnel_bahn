import SwiftUI

private struct SystemResourceTableRow: Identifiable {
    let id: String
    let title: String
    let cpuPercent: Double
    let memoryBytes: UInt64
}

struct StatusView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAllPerAppStats = false

    private let perAppStatsTopN = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Connection Status")
                    .font(.title2.bold())
                Spacer()
                statusBadge
            }

            GroupBox("Session") {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Backend", backendLabel)
                    infoRow("State", appState.vpnManager.stats.state.rawValue.capitalized)
                    infoRow("Tunnel Mode", tunnelModeLabel)
                    infoRow("Endpoint", appState.vpnManager.stats.endpoint ?? "Not connected")
                    infoRow("Connected At", formatDate(appState.vpnManager.stats.connectedAt))
                    infoRow("Tunnel In", "\(formatRate(appState.vpnManager.stats.rxBytesPerSecond)) (Total \(formatBytes(appState.vpnManager.stats.bytesIn)))")
                    infoRow("Tunnel Out", "\(formatRate(appState.vpnManager.stats.txBytesPerSecond)) (Total \(formatBytes(appState.vpnManager.stats.bytesOut)))")
                    if appState.vpnManager.stats.perAppSplitTunnelActive {
                        infoRow("App-Tunnel Split", "Active")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("System Resources") {
                Table(systemResourceTableRows) {
                    TableColumn("Component") { row in
                        Text(row.title)
                    }
                    .width(min: 100, ideal: 140)
                    TableColumn("CPU") { row in
                        Text(String(format: "%.1f%%", row.cpuPercent))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(ideal: 72)
                    TableColumn("Memory") { row in
                        Text(formatBytes(row.memoryBytes))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(ideal: 100)
                }
                .frame(maxWidth: .infinity, minHeight: CGFloat(systemResourceTableRows.count) * 22 + 28)
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }

            if appState.vpnManager.stats.perAppStatsCollectionActive {
                perAppTrafficSection
            }

            if let error = appState.vpnManager.stats.lastError {
                GroupBox("Last Error") {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Button("Disconnect") {
                    appState.vpnManager.disconnect()
                }
                .buttonStyle(.bordered)
                .disabled(appState.vpnManager.isBusy)
            }
            Spacer()
        }
        .padding()
        .onChange(of: appState.vpnManager.stats.perAppStatsCollectionActive) { _, active in
            if !active { showAllPerAppStats = false }
        }
    }

    private var perAppTrafficSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                let stats = appState.vpnManager.stats
                HStack(alignment: .center, spacing: 8) {
                    Text("App-Tunnel Traffic")
                        .font(.headline)
                    Spacer(minLength: 8)
                    directionalThroughputCaption(
                        down: formatRate(stats.perAppAggregateRxBytesPerSecond),
                        up: formatRate(stats.perAppAggregateTxBytesPerSecond)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Total rate: receive \(formatRate(stats.perAppAggregateRxBytesPerSecond)), send \(formatRate(stats.perAppAggregateTxBytesPerSecond))"
                    )
                }
                if sortedPerAppStats.count > perAppStatsTopN {
                    Button(showAllPerAppStats ? "Show top \(perAppStatsTopN) only" : "Show all (\(sortedPerAppStats.count))") {
                        showAllPerAppStats.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                Divider()
                if displayedPerAppStats.isEmpty {
                    Text("Waiting for app-tunnel traffic…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedPerAppStats, id: \.key) { app, entry in
                        HStack(alignment: .center, spacing: 8) {
                            Text(app)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            directionalThroughputCaption(
                                down: formatBytes(entry.rxBytes),
                                up: formatBytes(entry.txBytes)
                            )
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Received \(formatBytes(entry.rxBytes)), sent \(formatBytes(entry.txBytes))")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var systemResourceTableRows: [SystemResourceTableRow] {
        let s = appState.vpnManager.stats
        var rows: [SystemResourceTableRow] = [
            SystemResourceTableRow(
                id: "app",
                title: "Application",
                cpuPercent: s.appCPUUsage,
                memoryBytes: s.appMemoryUsage
            )
        ]
        if s.state == .connected {
            rows.append(
                contentsOf: [
                    SystemResourceTableRow(
                        id: "packetTunnel",
                        title: "Packet Tunnel",
                        cpuPercent: s.packetTunnelCPUUsage,
                        memoryBytes: s.packetTunnelMemoryUsage
                    ),
                    SystemResourceTableRow(
                        id: "transparentProxy",
                        title: "Transparent Proxy",
                        cpuPercent: s.transparentProxyCPUUsage,
                        memoryBytes: s.transparentProxyMemoryUsage
                    )
                ]
            )
        }
        return rows
    }

    private var displayedPerAppStats: [(key: String, value: AppTransferEntry)] {
        if showAllPerAppStats || sortedPerAppStats.count <= perAppStatsTopN {
            return sortedPerAppStats
        }
        return Array(sortedPerAppStats.prefix(perAppStatsTopN))
    }

    private var sortedPerAppStats: [(key: String, value: AppTransferEntry)] {
        appState.vpnManager.stats.perAppStats
            .sorted { lhs, rhs in
                let lTotal = lhs.value.rxBytes &+ lhs.value.txBytes
                let rTotal = rhs.value.rxBytes &+ rhs.value.txBytes
                if lTotal != rTotal { return lTotal > rTotal }
                return lhs.key < rhs.key
            }
            .map { ($0.key, $0.value) }
    }

    private var statusBadge: some View {
        Text(appState.vpnManager.stats.state.rawValue.uppercased())
            .font(.caption.bold())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(appState.vpnManager.stats.state == .connected ? .green.opacity(0.2) : .secondary.opacity(0.2))
            .clipShape(Capsule())
    }

    private var tunnelModeLabel: String {
        let selectedRoutedApps = appState.appRuleStore.rules.filter { $0.action == .routeVPN }.count
        let planned: String = {
            switch appState.settings.routingMode {
            case .fullTunnel:
                return "Full Tunnel (all traffic)"
            case .appTunnel:
                // Option A: App-tunnel mode with zero selected apps behaves like Full Tunnel.
                return selectedRoutedApps > 0 ? "App-Tunnel (selected apps only)" : "Full Tunnel (all traffic)"
            }
        }()
        let active = appState.vpnManager.stats.perAppSplitTunnelActive ? "App-Tunnel (selected apps only)" : "Full Tunnel (all traffic)"
        switch appState.vpnManager.stats.state {
        case .connected, .connecting, .reconnecting, .disconnecting:
            return active
        case .disconnected, .error:
            return planned
        }
    }

    private func directionalThroughputCaption(down: String, up: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                Text(down)
            }
            HStack(spacing: 3) {
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.semibold))
                Text(up)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        let rounded = Int64(max(0, bytesPerSecond.rounded()))
        if rounded == 0 {
            return "0 KB/s"
        }
        if rounded < 1024 {
            return "\(rounded) B/s"
        }
        return "\(ByteCountFormatter.string(fromByteCount: rounded, countStyle: .binary))/s"
    }

    private var backendLabel: String {
        "Network Extension"
    }
}

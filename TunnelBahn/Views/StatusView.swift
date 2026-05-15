import SwiftUI

private struct SystemResourceTableRow: Identifiable {
    let id: String
    let title: String
    let cpuPercent: Double
    let memoryBytes: UInt64
}

/// Shared GroupBox chrome: bold title row, optional control next to title, optional trailing accessory, divider, body.
private struct MonitoringGroupBox<TitleAccessory: View, TrailingAccessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var titleAccessory: () -> TitleAccessory
    @ViewBuilder var trailingAccessory: () -> TrailingAccessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    titleAccessory()
                    Spacer(minLength: 8)
                    trailingAccessory()
                }
                Divider()
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MonitoringGroupBox where TitleAccessory == EmptyView, TrailingAccessory == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, titleAccessory: { EmptyView() }, trailingAccessory: { EmptyView() }, content: content)
    }
}

extension MonitoringGroupBox where TitleAccessory == EmptyView {
    init(
        title: String,
        @ViewBuilder trailingAccessory: @escaping () -> TrailingAccessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, titleAccessory: { EmptyView() }, trailingAccessory: trailingAccessory, content: content)
    }
}

struct StatusView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var reverseDNS = ReverseDNSResolver()
    @State private var showAllPerAppStats = false
    /// App display names with expanded TCP destination subtree (custom disclosure — clearer than default `DisclosureGroup` chrome).
    @State private var expandedAppTrafficApps: Set<String> = []
    @State private var hoveredAppTrafficRow: String?
    @State private var hoveredDestinationRow: String?
    @State private var copiedApp: String?

    private let perAppStatsTopN = 10
    /// Caps vertical growth of the app rows; list scrolls when expanded nodes exceed this.
    private let perAppTrafficListMaxHeight: CGFloat = 380
    /// Keeps empty / startup state readable so the Tunnel Monitor body is not vertically collapsed.
    private let perAppTrafficListMinHeight: CGFloat = 120

    /// Tooltip + VoiceOver helper for Tunnel Monitor naming (deliberately short).
    private static let tunnelTrafficMonitorHelpText =
        "Counted TCP IPs. Prefix Reverse-DNs; brackets = matched routing lists. “Other traffic” is everything else summed for this app."

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MonitoringGroupBox(title: "Connection Status", trailingAccessory: { statusBadge }) {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Backend", backendLabel)
                    infoRow("State", appState.vpnManager.stats.state.rawValue.capitalized)
                    infoRow("Tunnel Mode", tunnelModeLabel)
                    infoRow("Endpoint", appState.vpnManager.stats.endpoint ?? "Not connected")
                    if let connectedAt = appState.vpnManager.stats.connectedAt {
                        TimelineView(.periodic(from: connectedAt, by: 1)) { _ in
                            infoRow("Duration", formatDuration(since: connectedAt))
                        }
                    } else {
                        infoRow("Duration", "n/a")
                    }
                    infoRow("Last Receive", formatRelativeDate(appState.vpnManager.stats.lastInboundAt))
                    infoRow("Tunnel In", "\(formatRate(appState.vpnManager.stats.rxBytesPerSecond)) (Total \(formatBytes(appState.vpnManager.stats.bytesIn)))")
                    infoRow("Tunnel Out", "\(formatRate(appState.vpnManager.stats.txBytesPerSecond)) (Total \(formatBytes(appState.vpnManager.stats.bytesOut)))")
                    if appState.vpnManager.stats.perAppSplitTunnelActive {
                        infoRow("App-Tunnel Split", "Active")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if appState.vpnManager.stats.perAppStatsCollectionActive {
                perAppTrafficSection
            }

            if let error = appState.vpnManager.stats.lastError {
                MonitoringGroupBox(title: "Last Error") {
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

            MonitoringGroupBox(title: "Resource Monitor") {
                systemResourcesInsetList
            }

            Spacer()
        }
        .padding()
        .onChange(of: appState.vpnManager.stats.perAppStatsCollectionActive) { _, active in
            if !active {
                showAllPerAppStats = false
                expandedAppTrafficApps = []
                hoveredAppTrafficRow = nil
                hoveredDestinationRow = nil
                copiedApp = nil
            }
        }
    }

    private var perAppTrafficSection: some View {
        MonitoringGroupBox(
            title: "Tunnel Monitor",
            titleAccessory: {
                Image(systemName: "questionmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .instantTooltip(Self.tunnelTrafficMonitorHelpText)
                    .accessibilityLabel("How listed traffic addresses are interpreted")
                    .accessibilityHint(Self.tunnelTrafficMonitorHelpText)
            },
            trailingAccessory: {
                let stats = appState.vpnManager.stats
                directionalThroughputCaption(
                    down: formatRate(stats.perAppAggregateRxBytesPerSecond),
                    up: formatRate(stats.perAppAggregateTxBytesPerSecond)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Total rate: receive \(formatRate(stats.perAppAggregateRxBytesPerSecond)), send \(formatRate(stats.perAppAggregateTxBytesPerSecond))"
                )
            }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if allAppsSorted.count > perAppStatsTopN {
                    Button(showAllPerAppStats ? "Show top \(perAppStatsTopN) only" : "Show all (\(allAppsSorted.count))") {
                        showAllPerAppStats.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                ScrollView {
                    if displayedApps.isEmpty {
                        Text("Waiting for app-tunnel traffic…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: perAppTrafficListMinHeight, alignment: .topLeading)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(displayedApps, id: \.0) { app, entry in
                                let destRows = destinationsByApp[app] ?? []
                                let residual = residualBytes(parent: entry, tcpDestinations: destRows)
                                let isExpanded = expandedAppTrafficApps.contains(app)
                                let isHovered = hoveredAppTrafficRow == app
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .center, spacing: 8) {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                if isExpanded {
                                                    expandedAppTrafficApps.remove(app)
                                                } else {
                                                    expandedAppTrafficApps.insert(app)
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: "chevron.right")
                                                    .font(.headline.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 18, alignment: .center)
                                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                                Text(app)
                                                    .font(.headline)
                                                    .lineLimit(1)
                                                    .foregroundStyle(.primary)
                                                Spacer(minLength: 8)
                                                directionalThroughputCaption(
                                                    down: formatBytes(entry.rxBytes),
                                                    up: formatBytes(entry.txBytes)
                                                )
                                                .accessibilityElement(children: .combine)
                                                .accessibilityLabel(
                                                    "Received \(formatBytes(entry.rxBytes)), sent \(formatBytes(entry.txBytes))"
                                                )
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(app)
                                        .accessibilityHint(
                                            isExpanded ? "Collapse TCP destination details" : "Expand to show TCP destination details"
                                        )

                                        trafficAppSubtreeCopyButton(
                                            app: app,
                                            destRows: destRows,
                                            residual: residual
                                        )
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .background {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
                                    }
                                    .animation(.easeInOut(duration: 0.12), value: isHovered)
                                    .onHover { hovering in
                                        if hovering {
                                            hoveredAppTrafficRow = app
                                        } else if hoveredAppTrafficRow == app {
                                            hoveredAppTrafficRow = nil
                                        }
                                    }

                                    if isExpanded {
                                        appTrafficExpandedContent(
                                            destRows: destRows,
                                            residual: residual
                                        )
                                        .padding(.leading, 26)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(minHeight: perAppTrafficListMinHeight, maxHeight: perAppTrafficListMaxHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func appTrafficExpandedContent(
        destRows: [PerDestinationTransferRow],
        residual: (rxBytes: UInt64, txBytes: UInt64)
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(destRows) { row in
                let isDestHovered = hoveredDestinationRow == row.remoteLiteral
                HStack(alignment: .center, spacing: 8) {
                    DestinationLiteralLabel(
                        literal: row.remoteLiteral,
                        destinationListLabels: appState.destinationRuleStore.matchingDestinationListLabels(
                            forLiteral: row.remoteLiteral
                        ),
                        resolver: reverseDNS
                    )
                    Spacer(minLength: 8)
                    directionalThroughputCaption(
                        down: formatBytes(row.rxBytes),
                        up: formatBytes(row.txBytes)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Received \(formatBytes(row.rxBytes)), sent \(formatBytes(row.txBytes))"
                    )
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isDestHovered ? 0.07 : 0))
                }
                .animation(.easeInOut(duration: 0.12), value: isDestHovered)
                .onHover { hovering in
                    if hovering {
                        hoveredDestinationRow = row.remoteLiteral
                    } else if hoveredDestinationRow == row.remoteLiteral {
                        hoveredDestinationRow = nil
                    }
                }
            }
            if residual.rxBytes > 0 || residual.txBytes > 0 {
                let isResidualHovered = hoveredDestinationRow == "__other_traffic__"
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("Other traffic")
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        directionalThroughputCaption(
                            down: formatBytes(residual.rxBytes),
                            up: formatBytes(residual.txBytes)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Other traffic: received \(formatBytes(residual.rxBytes)), sent \(formatBytes(residual.txBytes))"
                        )
                        trafficOtherResidualCopyButton()
                    }
                    Text("UDP, TCP without IP literals, etc.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isResidualHovered ? 0.07 : 0))
                }
                .animation(.easeInOut(duration: 0.12), value: isResidualHovered)
                .onHover { hovering in
                    if hovering {
                        hoveredDestinationRow = "__other_traffic__"
                    } else if hoveredDestinationRow == "__other_traffic__" {
                        hoveredDestinationRow = nil
                    }
                }
            }
            if destRows.isEmpty && residual.rxBytes == 0 && residual.txBytes == 0 {
                Text("No relayed payload counted yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationsByApp: [String: [PerDestinationTransferRow]] {
        Dictionary(grouping: appState.vpnManager.stats.perDestinationStats, by: \.appDisplayName)
            .mapValues { rows in
                rows.sorted { lhs, rhs in
                    let lTotal = lhs.rxBytes &+ lhs.txBytes
                    let rTotal = rhs.rxBytes &+ rhs.txBytes
                    if lTotal != rTotal { return lTotal > rTotal }
                    return lhs.remoteLiteral < rhs.remoteLiteral
                }
            }
    }

    private func parentEntry(for app: String) -> AppTransferEntry {
        let stats = appState.vpnManager.stats
        if let entry = stats.perAppStats[app] { return entry }
        let rows = destinationsByApp[app] ?? []
        let rx = rows.reduce(UInt64(0)) { $0 &+ $1.rxBytes }
        let tx = rows.reduce(UInt64(0)) { $0 &+ $1.txBytes }
        return AppTransferEntry(txBytes: tx, rxBytes: rx, signingIdentifiers: [])
    }

    private var allAppsSorted: [(String, AppTransferEntry)] {
        let stats = appState.vpnManager.stats
        let keys = Set(stats.perAppStats.keys).union(destinationsByApp.keys)
        return keys.map { ($0, parentEntry(for: $0)) }
            .sorted { lhs, rhs in
                let lTotal = lhs.1.rxBytes &+ lhs.1.txBytes
                let rTotal = rhs.1.rxBytes &+ rhs.1.txBytes
                if lTotal != rTotal { return lTotal > rTotal }
                return lhs.0 < rhs.0
            }
    }

    private var displayedApps: [(String, AppTransferEntry)] {
        if showAllPerAppStats || allAppsSorted.count <= perAppStatsTopN {
            return allAppsSorted
        }
        return Array(allAppsSorted.prefix(perAppStatsTopN))
    }

    private func residualBytes(parent: AppTransferEntry, tcpDestinations: [PerDestinationTransferRow]) -> (
        rxBytes: UInt64, txBytes: UInt64
    ) {
        let sumRx = tcpDestinations.reduce(UInt64(0)) { $0 &+ $1.rxBytes }
        let sumTx = tcpDestinations.reduce(UInt64(0)) { $0 &+ $1.txBytes }
        let rx = parent.rxBytes > sumRx ? parent.rxBytes &- sumRx : 0
        let tx = parent.txBytes > sumTx ? parent.txBytes &- sumTx : 0
        return (rx, tx)
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

    /// SwiftUI `Table` treats vertical space flexibly and draws filler rows; use a tight grid so
    /// height tracks real rows (no clipping, no scrolling for normal row counts).
    private var systemResourcesInsetList: some View {
        let rows = systemResourceTableRows
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Component")
                    .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                Text("CPU")
                    .frame(width: 72, alignment: .trailing)
                Text("Memory")
                    .frame(width: 100, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)

            Divider()

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.title)
                        .lineLimit(1)
                        .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.1f%%", row.cpuPercent))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                    Text(formatBytes(row.memoryBytes))
                        .monospacedDigit()
                        .frame(width: 100, alignment: .trailing)
                }
                .font(.callout)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(index.isMultiple(of: 2) ? Color.primary.opacity(0.045) : Color.clear)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.title), CPU \(String(format: "%.1f", row.cpuPercent)) percent, memory \(formatBytes(row.memoryBytes))")
            }
        }
        .environment(\.controlSize, .small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBadge: some View {
        let stats = appState.vpnManager.stats
        let probeFailMessage: String? = {
            guard stats.state == .connected, case .failed(let msg) = stats.connectivityProbeResult else { return nil }
            return msg
        }()
        let badgeColor: Color = stats.state == .connected
            ? (probeFailMessage != nil ? .orange : .green)
            : .secondary
        return HStack(spacing: 4) {
            Text(stats.state.rawValue.uppercased())
                .font(.caption.bold())
            if let msg = probeFailMessage {
                Image(systemName: "questionmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .instantTooltip(msg)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(badgeColor.opacity(0.2))
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

    private func formatDuration(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start).rounded()))
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func formatRelativeDate(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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

    private func copySubtreeToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    private func trafficAppSubtreeCopyButton(
        app: String,
        destRows: [PerDestinationTransferRow],
        residual: (rxBytes: UInt64, txBytes: UInt64)
    ) -> some View {
        let isCopied = copiedApp == app
        return Button {
            let ips = destRows.map(\.remoteLiteral).joined(separator: "\n")
            copySubtreeToPasteboard(ips)
            copiedApp = app
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedApp == app { copiedApp = nil }
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(isCopied ? .green : .secondary)
                .animation(.easeInOut(duration: 0.15), value: isCopied)
        }
        .buttonStyle(.borderless)
        .help(isCopied ? "Copied!" : "Copy IP list")
        .accessibilityLabel(isCopied ? "Copied" : "Copy IP list for \(app)")
    }

    private func trafficOtherResidualCopyButton() -> some View {
        Button {
            copySubtreeToPasteboard(
                [
                    "Other traffic",
                    "UDP, TCP without IP literals, etc.",
                ].joined(separator: "\n")
            )
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy Other traffic line")
        .accessibilityLabel("Copy Other traffic")
    }

    private var backendLabel: String {
        "Network Extension"
    }
}

private struct DestinationLiteralLabel: View {
    let literal: String
    let destinationListLabels: [String]
    @ObservedObject var resolver: ReverseDNSResolver

    /// Split suffix must stay aligned with `ReverseDNSResolver` (`hostname · literal`).
    private static let dnsHostnameSeparator = " · "

    private var listBracketSuffix: String? {
        guard !destinationListLabels.isEmpty else { return nil }
        return "[\(destinationListLabels.joined(separator: ", "))]"
    }

    /// Non-empty hostname when PTR resolved (`hostname · literal`).
    private var hostnamePrefixIncludingSeparator: String? {
        let full = resolver.displayLabel(for: literal)
        guard let range = full.range(of: Self.dnsHostnameSeparator) else { return nil }
        let ipSuffix = String(full[range.upperBound...])
        guard ipSuffix == literal else { return nil }
        let host = String(full[..<range.lowerBound])
        guard !host.isEmpty else { return nil }
        return host + Self.dnsHostnameSeparator
    }

    private var accessibilitySummary: String {
        let core = resolver.accessibilityLabel(for: literal)
        guard !destinationListLabels.isEmpty else { return core }
        return core + ". Matches lists \(destinationListLabels.joined(separator: ", "))"
    }

    var body: some View {
        HStack(spacing: 6) {
            if let hostnamePrefixIncludingSeparator {
                Text(hostnamePrefixIncludingSeparator)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.disabled)
            }
            Text(literal)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if let listBracketSuffix {
                Text(listBracketSuffix)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.disabled)
            }
        }
        .task(id: literal) { await resolver.resolve(literal) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }
}

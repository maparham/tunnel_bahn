import SwiftUI

struct ProfileDetailView: View {
    let profile: WireGuardProfile
    let isActive: Bool
    let isBusy: Bool
    let connectionState: VPNConnectionState
    let tunnelModeLabel: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    let rxBytesPerSecond: Double
    let txBytesPerSecond: Double
    let lastError: String?
    let splitTunnelWarnings: [String]
    let onEdit: () -> Void
    let onRename: (String) -> Void

    @FocusState private var nameFieldFocused: Bool
    @State private var editingName = false
    @State private var nameDraft = ""

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                GroupBox("Interface") {
                    VStack(alignment: .leading, spacing: 10) {
                        DetailRow(
                            label: "Private key",
                            value: profile.interface.privateKeyRef,
                            monospaced: true,
                            copyable: true
                        )
                        DetailRow(
                            label: "Addresses",
                            value: profile.interface.addresses.joined(separator: ", ")
                        )
                        if let mtu = profile.interface.mtu {
                            DetailRow(label: "MTU", value: "\(mtu)")
                        }
                        if !profile.interface.dnsServers.isEmpty {
                            DetailRow(
                                label: "DNS servers",
                                value: profile.interface.dnsServers.joined(separator: ", ")
                            )
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Transfer") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Text("")
                                .frame(width: 150, alignment: .trailing)
                            Text("Rate")
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            Text("Total")
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            Spacer(minLength: 0)
                        }
                        transferRow(label: "RX", rate: rxBytesPerSecond, total: bytesIn)
                        transferRow(label: "TX", rate: txBytesPerSecond, total: bytesOut)
                    }
                    .padding(.top, 4)
                }

                ForEach(profile.peers) { peer in
                    GroupBox("Peer") {
                        VStack(alignment: .leading, spacing: 10) {
                            DetailRow(
                                label: "Public key",
                                value: peer.publicKey,
                                monospaced: true,
                                copyable: true
                            )
                            if peer.presharedKeyRef != nil {
                                DetailRow(
                                    label: "Preshared key",
                                    value: "(set)",
                                    monospaced: true
                                )
                            }
                            DetailRow(label: "Endpoint", value: peer.endpoint)
                            DetailRow(
                                label: "Allowed IPs",
                                value: peer.allowedIPs.joined(separator: ", ")
                            )
                            if let keepalive = peer.persistentKeepalive {
                                DetailRow(
                                    label: "Persistent keepalive",
                                    value: "every \(keepalive) seconds"
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                if !splitTunnelWarnings.isEmpty {
                    splitTunnelWarningBanner
                }
            }
            .padding(20)
        }
    }

    private var splitTunnelWarningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Privacy & IP Leak Risk")
                    .font(.headline)
                    .foregroundStyle(.primary)
                ForEach(splitTunnelWarnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(warning)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Privacy warning: " + splitTunnelWarnings.joined(separator: " "))
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                if editingName {
                    TextField("", text: $nameDraft)
                        .font(.title2.bold())
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focused($nameFieldFocused)
                        .accessibilityLabel("Profile name")
                        .onSubmit { commitNameEdit() }
                        .onExitCommand { cancelNameEdit() }
                        .onChange(of: nameFieldFocused) { _, focused in
                            if editingName, !focused { commitNameEdit() }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                                }
                        }
                } else {
                    Text(profile.name)
                        .font(.title2.bold())
                        .help("Double-click to rename")
                        .onTapGesture(count: 2) { beginNameEdit() }

                    Button(action: beginNameEdit) {
                        Image(systemName: "square.and.pencil")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename profile")

                    Text(tunnelModeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let lastError, !lastError.isEmpty, connectionState != .disconnected {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()
                StatusBadge(
                    title: statusTitle,
                    color: statusColor
                )

                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                    .disabled(isBusy || isActive)
            }
            .onChange(of: profile.id) {
                cancelNameEdit()
            }
        }
    }

    private func beginNameEdit() {
        guard !isBusy else { return }
        nameDraft = profile.name
        editingName = true
        nameFieldFocused = true
    }

    private func cancelNameEdit() {
        editingName = false
        nameFieldFocused = false
    }

    private func commitNameEdit() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == profile.name {
            cancelNameEdit()
            return
        }
        onRename(trimmed)
        editingName = false
        nameFieldFocused = false
    }

    private var statusTitle: String {
        guard isActive else { return "Inactive" }
        switch connectionState {
        case .connected:
            return "Active"
        case .connecting, .reconnecting:
            return "Connecting"
        case .disconnecting:
            return "Disconnecting"
        case .error:
            return "Error"
        case .disconnected:
            return "Inactive"
        }
    }

    private var statusColor: Color {
        guard isActive else { return .gray }
        switch connectionState {
        case .connected:
            return .green
        case .connecting, .disconnecting, .reconnecting:
            return .orange
        case .error:
            return .red
        case .disconnected:
            return .gray
        }
    }

    private func formatBytes(_ value: UInt64) -> String {
        Self.byteFormatter.string(fromByteCount: Int64(value))
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        let rounded = Int64(max(0, bytesPerSecond.rounded()))
        if rounded == 0 {
            return "0 KB/s"
        }
        if rounded < 1024 {
            return "\(rounded) B/s"
        }
        return "\(Self.byteFormatter.string(fromByteCount: rounded))/s"
    }

    private func transferRow(label: String, rate: Double, total: UInt64) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            Text(formatRate(rate))
                .monospacedDigit()
                .frame(width: 130, alignment: .leading)
            Text(formatBytes(total))
                .monospacedDigit()
                .frame(width: 130, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var copyable: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            valueText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var valueText: some View {
        if copyable {
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        } else {
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
        }
    }
}

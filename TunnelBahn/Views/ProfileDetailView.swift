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
    let onActivate: () -> Void
    let onDeactivate: () -> Void
    let onEdit: () -> Void

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
            }
            .padding(20)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(profile.name)
                    .font(.title2.bold())
                Spacer()
                StatusBadge(
                    title: statusTitle,
                    color: statusColor
                )
            }

            HStack(spacing: 12) {
                Button {
                    if isActive {
                        onDeactivate()
                    } else {
                        onActivate()
                    }
                } label: {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(isActive ? "Deactivate" : "Activate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)

                Button("Edit…", action: onEdit)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)

                if connectionState != .disconnected {
                    Text(tunnelModeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var statusTitle: String {
        if connectionState == .connected {
            return isActive ? "Active" : "Inactive"
        }
        switch connectionState {
        case .connected:
            return isActive ? "Active" : "Inactive"
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
        if connectionState == .connected {
            return isActive ? .green : .gray
        }
        switch connectionState {
        case .connected:
            return isActive ? .green : .gray
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

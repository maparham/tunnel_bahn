import SwiftUI
import AppKit

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
    let competingProxySigningIDs: [String]
    let splitTunnelWarnings: [String]
    let onToggleTunnel: () -> Void
    let onEdit: () -> Void
    let onRename: (String) -> Void
    let onExport: () -> Void

    @FocusState private var nameFieldFocused: Bool
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var showQRPopover = false
    @State private var qrImage: NSImage? = nil
    @State private var qrError: String? = nil
    @State private var leakRiskDismissed: Bool = false

    private var leakRiskDefaultsKey: String { "leakRiskAcknowledged_\(profile.id)" }

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

                if !splitTunnelWarnings.isEmpty && !leakRiskDismissed {
                    splitTunnelWarningBanner
                }
            }
            .padding(20)
        }
        .onAppear {
            leakRiskDismissed = UserDefaults.standard.bool(forKey: leakRiskDefaultsKey)
        }
    }

    private var splitTunnelWarningBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            Button {
                UserDefaults.standard.set(true, forKey: leakRiskDefaultsKey)
                withAnimation(.easeOut(duration: 0.2)) {
                    leakRiskDismissed = true
                }
            } label: {
                Text("Don't show again")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
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
                        .maxLength($nameDraft, WireGuardProfile.maxNameLength)
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
                        .instantTooltip("Double-click to rename")
                        .onTapGesture(count: 2) { beginNameEdit() }

                    Button(action: beginNameEdit) {
                        Image(systemName: "square.and.pencil")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .instantTooltip("Rename profile")

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
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .instantTooltip("Export as .conf")

                Button {
                    generateQRImage()
                    showQRPopover = true
                } label: {
                    Image(systemName: "qrcode")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .instantTooltip("Show QR code")
                .popover(isPresented: $showQRPopover, arrowEdge: .bottom) {
                    qrPopoverContent
                }

                Button(action: onEdit) {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .instantTooltip("Edit profile")
                .disabled(isBusy || isActive)
                Button(action: onToggleTunnel) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isActive ? "power.circle.fill" : "power.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(isActive ? Color.green : Color.primary)
                    }
                }
                .buttonStyle(.plain)
                .instantTooltip(isActive ? "Disconnect \"\(profile.name)\"" : "Connect \"\(profile.name)\"")
                .disabled(isBusy)
            }
            .onChange(of: profile.id) {
                cancelNameEdit()
                qrImage = nil
                qrError = nil
                showQRPopover = false
                leakRiskDismissed = UserDefaults.standard.bool(forKey: leakRiskDefaultsKey)
            }

            if !competingProxySigningIDs.isEmpty, connectionState != .disconnected {
                Text(competingProxyWarningText(for: competingProxySigningIDs))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var qrPopoverContent: some View {
        Group {
            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(16)
            } else {
                Text(qrError ?? "Generating…")
                    .foregroundStyle(.secondary)
                    .padding(32)
            }
        }
    }

    private func generateQRImage() {
        do {
            let config = try WireGuardConfigRenderer.renderFullConfigString(profile: profile)
            if let img = WireGuardConfigRenderer.makeQRCodeImage(from: config) {
                qrImage = img
                qrError = nil
            } else {
                qrError = "Config too large for QR code"
            }
        } catch {
            qrError = error.localizedDescription
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

    private func competingProxyWarningText(for ids: [String]) -> String {
        let names = ids.map(displayNameForSigningID(_:))
        let label: String
        switch names.count {
        case 1:
            label = names[0]
        case 2:
            label = "\(names[0]) and \(names[1])"
        default:
            label = names.prefix(2).joined(separator: ", ") + ", and others"
        }
        return "Selected apps may not be using the VPN. Another proxy extension (\(label)) may be intercepting traffic. Quit it to fix."
    }

    /// Best-effort human-readable name from a signing identifier. Drops common reverse-DNS
    /// prefixes and proxy-extension suffixes, then title-cases the remaining slug.
    /// Example: "com.tunnelbahn.netmeter.proxy" → "Netmeter".
    private func displayNameForSigningID(_ id: String) -> String {
        let parts = id.split(separator: ".").map(String.init)
        let suffixesToDrop: Set<String> = [
            "proxy", "transparentproxy", "appproxy", "networkextension", "appex", "extension", "helper",
        ]
        var meaningful = parts.filter { !suffixesToDrop.contains($0.lowercased()) }
        // Drop obvious reverse-DNS prefixes ("com", "net", "org", "io"...) and vendor tokens that
        // tend to repeat ("apple", "google"). Keep the most-specific token, which is usually last.
        let genericPrefixes: Set<String> = ["com", "net", "org", "io", "co", "app"]
        while let first = meaningful.first, genericPrefixes.contains(first.lowercased()), meaningful.count > 1 {
            meaningful.removeFirst()
        }
        guard let raw = meaningful.last, !raw.isEmpty else { return id }
        return raw.prefix(1).uppercased() + raw.dropFirst()
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

struct StatusBadge: View {
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

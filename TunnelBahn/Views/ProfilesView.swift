import SwiftUI
import UniformTypeIdentifiers
import AppKit

private enum ProfileDetailTab {
    case overview, apps, routing
}

struct ProfilesView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var vpnManager: VPNManager
    @ObservedObject var settings: AppSettings
    let appRuleStore: AppRuleStore
    let destinationRuleStore: DestinationRuleStore
    @State private var profileActionError: String?
    @State private var isPasteSheetPresented = false
    @State private var pastedProfileName = ""
    @State private var pastedConfig = ""
    @State private var editingProfile: WireGuardProfile?
    @State private var deleteConfirmationProfile: WireGuardProfile?
    @State private var isDeleteConfirmationPresented = false
    @State private var overwriteConfirmation: (existing: WireGuardProfile, new: WireGuardProfile)?
    @State private var isOverwriteConfirmationPresented = false
    @State private var profileDetailTab: ProfileDetailTab = .overview
    @State private var confirmDisconnectActiveTunnel = false
    @State private var pendingToggleProfileID: UUID?
    private let parser = WireGuardConfigParser()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPanel
        }
        .alert("Error", isPresented: .constant(profileActionError != nil), actions: {
            Button("OK") { profileActionError = nil }
        }, message: {
            Text(profileActionError ?? "Unknown error")
        })
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(
                original: profile,
                onSave: { updated in
                    disconnectIfUsingProfile(id: updated.id)
                    // Upsert: `update` only mutates an existing row, so a from-scratch profile (e.g.
                    // "New SSH Profile") must go through `add`. Using `add` for existing edits is
                    // avoided because it runs keychain cleanup that would delete a still-referenced key.
                    if profileStore.profiles.contains(where: { $0.id == updated.id }) {
                        profileStore.update(updated)
                    } else {
                        profileStore.add(updated)
                    }
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil }
            )
        }
        .sheet(isPresented: $isPasteSheetPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste WireGuard Config")
                    .font(.title3.bold())

                TextField("Profile name (optional)", text: $pastedProfileName)
                    .textFieldStyle(.roundedBorder)
                    .maxLength($pastedProfileName, WireGuardProfile.maxNameLength)

                TextEditor(text: $pastedConfig)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary, lineWidth: 1)
                    )

                HStack {
                    Spacer()
                    Button("Cancel") {
                        resetPasteState()
                        isPasteSheetPresented = false
                    }
                    Button("Import") {
                        importPastedProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pastedConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(minWidth: 560, minHeight: 420)
        }
        .alert("Delete Profile?", isPresented: $isDeleteConfirmationPresented) {
            Button("Cancel", role: .cancel) {
                deleteConfirmationProfile = nil
            }
            Button("Delete", role: .destructive) {
                if let profile = deleteConfirmationProfile {
                    deleteProfile(id: profile.id)
                }
                deleteConfirmationProfile = nil
            }
        } message: {
            let name = deleteConfirmationProfile?.name ?? "this profile"
            Text("This will delete “\(name)”. You can’t undo this.")
        }
        .alert("Replace Existing Profile?", isPresented: $isOverwriteConfirmationPresented) {
            Button("Cancel", role: .cancel) {
                overwriteConfirmation = nil
            }
            Button("Replace", role: .destructive) {
                if let confirmation = overwriteConfirmation {
                    profileStore.replaceExisting(id: confirmation.existing.id, with: confirmation.new)
                }
                overwriteConfirmation = nil
            }
        } message: {
            let name = overwriteConfirmation?.existing.name ?? "a profile"
            Text("A profile named \"\(name)\" already exists. Replacing it will permanently delete the existing profile and its configuration.")
        }
        .onChange(of: vpnManager.isBusy) { _, busy in
            if !busy { pendingToggleProfileID = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profiles")
                .font(.title3.bold())
                .padding(.horizontal, 16)
                .padding(.top, 16)

            HStack(spacing: 8) {
                Button("Import .conf") {
                    importProfile()
                }
                .buttonStyle(.bordered)

                Button("Paste Config") {
                    isPasteSheetPresented = true
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)

            Button {
                editingProfile = makeNewSSHProfile()
            } label: {
                Label("New SSH Profile", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .instantTooltip("Create an SSH port-forwarding profile from scratch.")
            .padding(.horizontal, 16)

            if profileStore.profiles.isEmpty {
                ContentUnavailableView(
                    "No Profiles",
                    systemImage: "doc.badge.plus",
                    description: Text("Import a WireGuard .conf profile to get started.")
                )
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
            } else {
                ProfileListView(
                    profiles: profileStore.profiles,
                    selectedProfileID: profileStore.selectedProfileID,
                    connectedProfileID: vpnManager.stats.connectedProfileID,
                    isBusy: vpnManager.isBusy,
                    onSelect: { profileStore.select(id: $0) },
                    onMove: profileStore.move,
                    rowContent: { profile in
                        profileRowNSView(profile, connectedProfileID: vpnManager.stats.connectedProfileID)
                    },
                    onContextMenu: { profile in
                        profileContextMenu(profile, connectedProfileID: vpnManager.stats.connectedProfileID)
                    }
                )
            }
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let selectedProfile = profileStore.selectedProfile {
            let selectedRoutedApps = appRuleStore.rules.filter { $0.action == .routeVPN }.count
            let plannedModeLabel: String = {
                switch settings.routingMode {
                case .fullTunnel:
                    return "Full Tunnel (all traffic)"
                case .appTunnel:
                    return selectedRoutedApps > 0 ? "App-Tunnel (selected apps only)" : "Full Tunnel (all traffic)"
                }
            }()
            let modeLabel = plannedModeLabel

            let appTunnelSplitActive = settings.routingMode == .appTunnel && selectedRoutedApps > 0
            let splitTunnelWarnings: [String] = {
                var w: [String] = []
                if appTunnelSplitActive {
                    w.append("App-Tunnel mode: traffic from apps not in your selection bypasses the VPN and exposes your real IP address.")
                }
                if settings.enforceDestinationFiltering {
                    w.append("Destination routing is enabled: traffic to addresses outside your configured CIDRs and domains bypasses the VPN and exposes your real IP address.")
                }
                return w
            }()

            VStack(spacing: 0) {
                // Segment tabs + activate/deactivate on one row
                HStack(alignment: .center, spacing: 12) {
                    Picker("", selection: $profileDetailTab) {
                        Text("Overview").tag(ProfileDetailTab.overview)
                        Text("Apps").tag(ProfileDetailTab.apps)
                        Text("Advanced").tag(ProfileDetailTab.routing)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    Spacer(minLength: 0)

                    if vpnManager.stats.state == .connected {
                        if !vpnManager.stats.tunnelHasDefaultRoute {
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                                .instantTooltip("Internet may not be reachable")
                                .accessibilityLabel("Internet may not be reachable")
                        } else {
                            switch vpnManager.stats.connectivityProbeResult {
                            case .ok:
                                Image(systemName: "wifi")
                                    .foregroundStyle(.green)
                                    .instantTooltip("Internet reachable via tunnel")
                                    .accessibilityLabel("Internet reachable via tunnel")
                            case .failed(let message):
                                Image(systemName: "wifi.slash")
                                    .foregroundStyle(.orange)
                                    .instantTooltip(message)
                                    .accessibilityLabel("No internet via tunnel: \(message)")
                            case .unknown:
                                EmptyView()
                            }
                        }
                    }

                    if let connectedAt = vpnManager.stats.connectedAt {
                        TimelineView(.periodic(from: connectedAt, by: 1)) { _ in
                            Text(formatDuration(since: connectedAt))
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                        }
                    }

                    if vpnManager.stats.state == .disconnected || vpnManager.stats.state == .error {
                        StatusBadge(
                            title: connectionStatusTitle(
                                isActive: false,
                                state: vpnManager.stats.state,
                                probeResult: vpnManager.stats.connectivityProbeResult
                            ),
                            color: connectionStatusColor(
                                isActive: false,
                                state: vpnManager.stats.state,
                                probeResult: vpnManager.stats.connectivityProbeResult
                            )
                        )
                        .instantTooltip("No tunnel is active")
                    }

                    if vpnManager.stats.state == .connected && !splitTunnelWarnings.isEmpty {
                        SplitTunnelWarningIcon(warnings: splitTunnelWarnings)
                    }

                    if vpnManager.isBusy || (vpnManager.stats.state != .disconnected && vpnManager.stats.state != .error) {
                        let activeName = vpnManager.stats.connectedProfileID
                            .flatMap { id in profileStore.profiles.first { $0.id == id } }?.name
                        Button {
                            confirmDisconnectActiveTunnel = true
                        } label: {
                            Image(systemName: "power")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .instantTooltip("Disconnect \"\(activeName ?? "tunnel")\"")
                        .confirmationDialog(
                            "Disconnect \"\(activeName ?? "tunnel")\"?",
                            isPresented: $confirmDisconnectActiveTunnel
                        ) {
                            Button("Disconnect", role: .destructive) {
                                vpnManager.disconnect()
                            }
                        }
                    }

                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider()

                switch profileDetailTab {
                case .overview:
                    ProfileDetailView(
                        profile: selectedProfile,
                        isActive: isSelectedProfileActive,
                        isBusy: vpnManager.isBusy,
                        connectionState: vpnManager.stats.state,
                        tunnelModeLabel: modeLabel,
                        bytesIn: isSelectedProfileActive ? vpnManager.stats.bytesIn : 0,
                        bytesOut: isSelectedProfileActive ? vpnManager.stats.bytesOut : 0,
                        rxBytesPerSecond: isSelectedProfileActive ? vpnManager.stats.rxBytesPerSecond : 0,
                        txBytesPerSecond: isSelectedProfileActive ? vpnManager.stats.txBytesPerSecond : 0,
                        lastError: isSelectedProfileActive ? vpnManager.stats.lastError : nil,
                        competingProxySigningIDs: isSelectedProfileActive ? vpnManager.stats.competingProxySigningIDs : [],
                        splitTunnelWarnings: splitTunnelWarnings,
                        onToggleTunnel: {
                            if isSelectedProfileActive {
                                vpnManager.disconnect()
                            } else {
                                Task { await appState.connectProfile(selectedProfile) }
                            }
                        },
                        onEdit: {
                            editingProfile = profileStore.selectedProfile
                        },
                        onRename: { newName in
                            var updated = selectedProfile
                            updated.name = newName
                            profileStore.update(updated)
                        },
                        onExport: {
                            exportProfileAsConf(selectedProfile)
                        },
                        onResetHostKey: {
                            resetHostKeyTrust(for: selectedProfile)
                        }
                    )
                case .apps:
                    AppsView()
                case .routing:
                    RoutingView()
                }
            }

        } else {
            ContentUnavailableView(
                "No Profile Selected",
                systemImage: "sidebar.left",
                description: Text("Select a profile from the sidebar to view details.")
            )
        }
    }

    private func profileRowNSView(_ profile: WireGuardProfile, connectedProfileID: UUID?) -> NSView {
        let isConnected = profile.id == connectedProfileID
        // Show spinner on the row the user clicked, or on the connected row (covers tray-triggered disconnects).
        let isPendingToggle = pendingToggleProfileID == profile.id
        let isBusyForThisProfile = vpnManager.isBusy && (isPendingToggle || isConnected)
        let view = NSHostingView(rootView:
            profileRow(profile, isConnected: isConnected, isBusy: isBusyForThisProfile, onToggle: {
                pendingToggleProfileID = profile.id
                if vpnManager.stats.connectedProfileID == profile.id {
                    vpnManager.disconnect()
                } else {
                    Task { await appState.connectProfile(profile) }
                }
            })
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func profileContextMenu(_ profile: WireGuardProfile, connectedProfileID: UUID?) -> NSMenu {
        let isConnected = profile.id == connectedProfileID
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(makeMenuItem(
            title: isConnected ? "Turn Off" : "Turn On",
            symbolName: isConnected ? "power.circle.fill" : "power.circle"
        ) {
            if isConnected {
                vpnManager.disconnect()
            } else {
                Task { await appState.connectProfile(profile) }
            }
        })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Edit", symbolName: "pencil") {
            editingProfile = profile
        })
        menu.addItem(makeMenuItem(title: "Copy", symbolName: "doc.on.doc") {
            copyProfileConfigToClipboard(profile)
            showCopiedToast()
        })
        menu.addItem(makeMenuItem(title: "Export…", symbolName: "square.and.arrow.up") {
            exportProfileAsConf(profile)
        })
        menu.addItem(makeMenuItem(title: "Show QR Code", symbolName: "qrcode") {
            showQRCodePanel(for: profile)
        })
        menu.addItem(.separator())
        let deleteItem = makeMenuItem(title: "Delete", symbolName: "trash") {
            deleteConfirmationProfile = profile
            isDeleteConfirmationPresented = true
        }
        deleteItem.attributedTitle = NSAttributedString(
            string: "Delete",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(deleteItem)
        return menu
    }

    private func makeMenuItem(title: String, symbolName: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let target = MenuItemActionTarget(action: action)
        item.target = target
        item.action = #selector(MenuItemActionTarget.invoke)
        item.isEnabled = true
        objc_setAssociatedObject(item, &menuItemTargetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return item
    }

    private func profileRow(_ profile: WireGuardProfile, isConnected: Bool, isBusy: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray.opacity(0.35))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(profileSubtitle(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onToggle) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isConnected ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isConnected ? Color.green : Color.primary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            .instantTooltip(isConnected ? "Turn off" : "Turn on")
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let profile = try parser.parse(fileURL: url)
            addProfileWithOverwriteCheck(profile)
        } catch {
            profileActionError = error.localizedDescription
        }
    }

    private func importPastedProfile() {
        let trimmedName = pastedProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName = trimmedName.isEmpty ? "Pasted Profile" : trimmedName

        do {
            let profile = try parser.parse(rawConfig: pastedConfig, profileName: profileName)
            addProfileWithOverwriteCheck(profile)
            resetPasteState()
            isPasteSheetPresented = false
        } catch {
            profileActionError = error.localizedDescription
        }
    }

    private func resetPasteState() {
        pastedProfileName = ""
        pastedConfig = ""
    }

    /// Sidebar subtitle: the SSH host for SSH-transport profiles, otherwise the WireGuard endpoint.
    /// Driven by the stored `profile.transport`, never by live connection state (no-flicker rule).
    private func profileSubtitle(_ profile: WireGuardProfile) -> String {
        if profile.transport == .ssh {
            let host = profile.ssh?.host ?? ""
            return host.isEmpty ? "SSH" : host
        }
        return profile.peers.first?.endpoint ?? "No endpoint"
    }

    /// A blank SSH-transport template to open in the editor. `ssh` is deliberately `nil` so the editor
    /// shows empty fields and requires a private key (a non-nil ref with no stored key would falsely
    /// read as "a key is already stored"). The real `ssh` value + Keychain write happen on Save.
    private func makeNewSSHProfile() -> WireGuardProfile {
        WireGuardProfile(
            name: "New SSH Profile",
            interface: WireGuardInterface(privateKeyRef: "", addresses: [], dnsServers: [], mtu: nil),
            peers: [],
            transport: .ssh,
            ssh: nil
        )
    }

    /// Clears the pinned SSH host-key trust: the profile's surfaced pin (persisted) and the app-side
    /// TOFU store entry. Best-effort — the authoritative pin held by the root extension in its own
    /// App Group container is out of reach across the uid boundary (see host/extension uid boundary).
    private func resetHostKeyTrust(for profile: WireGuardProfile) {
        guard var ssh = profile.ssh else { return }
        SSHHostKeyStore(backing: UserDefaultsHostKeyBacking()).clearPin(forHost: ssh.host)
        ssh.hostKeyFingerprint = nil
        var updated = profile
        updated.ssh = ssh
        profileStore.update(updated)
    }

    private func disconnectIfUsingProfile(id: UUID) {
        if vpnManager.stats.connectedProfileID == id {
            vpnManager.disconnect()
        }
    }

    private func deleteProfile(id: UUID) {
        disconnectIfUsingProfile(id: id)
        profileStore.delete(id: id)
    }

    private func deleteProfiles(at offsets: IndexSet) {
        let ids = offsets.map { profileStore.profiles[$0].id }
        for id in ids {
            deleteProfile(id: id)
        }
    }

    private var isSelectedProfileActive: Bool {
        guard let selected = profileStore.selectedProfile else {
            return false
        }
        return isConnectedProfile(selected)
    }

    private func isConnectedProfile(_ profile: WireGuardProfile) -> Bool {
        guard vpnManager.stats.state == .connected else {
            return false
        }
        guard let connectedProfileID = vpnManager.stats.connectedProfileID else {
            return false
        }
        return profile.id == connectedProfileID
    }

    private func copyProfileConfigToClipboard(_ profile: WireGuardProfile) {
        do {
            let config = try WireGuardConfigRenderer.renderFullConfigString(profile: profile)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(config, forType: .string)
        } catch {
            profileActionError = error.localizedDescription
        }
    }

    private func exportProfileAsConf(_ profile: WireGuardProfile) {
        do {
            let config = try WireGuardConfigRenderer.renderFullConfigString(profile: profile)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
            panel.nameFieldStringValue = "\(profile.name).conf"
            panel.title = "Export WireGuard Profile"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try config.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            profileActionError = error.localizedDescription
        }
    }

    private func showQRCodePanel(for profile: WireGuardProfile) {
        let content: AnyView
        do {
            let config = try WireGuardConfigRenderer.renderFullConfigString(profile: profile)
            if let qrImage = WireGuardConfigRenderer.makeQRCodeImage(from: config) {
                content = AnyView(
                    VStack(spacing: 8) {
                        Text(profile.name).font(.headline)
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                    }
                    .padding(16)
                )
            } else {
                content = AnyView(
                    Text("Config is too large to encode as a QR code.")
                        .foregroundStyle(.secondary)
                        .padding(32)
                )
            }
        } catch {
            content = AnyView(
                Text("Could not read profile: \(error.localizedDescription)")
                    .foregroundStyle(.red)
                    .padding(32)
            )
        }

        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = .preferredContentSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 272, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // NSPanel defaults to isReleasedWhenClosed == true; with no strong reference held,
        // the close button would over-release the panel under ARC and crash.
        panel.isReleasedWhenClosed = false
        panel.title = "QR Code — \(profile.name)"
        panel.contentView = hosting
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func addProfileWithOverwriteCheck(_ profile: WireGuardProfile) {
        // Check if a profile with the same name already exists
        if let existing = profileStore.profiles.first(where: { $0.name == profile.name && $0.id != profile.id }) {
            overwriteConfirmation = (existing: existing, new: profile)
            isOverwriteConfirmationPresented = true
        } else {
            profileStore.add(profile)
        }
    }

    private func formatDuration(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start).rounded()))
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func connectionStatusTitle(isActive: Bool, state: VPNConnectionState, probeResult: ConnectivityProbeResult) -> String {
        guard isActive else { return "Inactive" }
        switch state {
        case .connected:
            if case .failed = probeResult { return "No Internet" }
            return "Active"
        case .connecting, .reconnecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .error: return "Error"
        case .disconnected: return "Inactive"
        }
    }

    private func connectionStatusColor(isActive: Bool, state: VPNConnectionState, probeResult: ConnectivityProbeResult) -> Color {
        guard isActive else { return .gray }
        switch state {
        case .connected:
            if case .failed = probeResult { return .orange }
            return .green
        case .connecting, .disconnecting, .reconnecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private func showCopiedToast() {
        let label = NSTextField(labelWithString: "Config copied to clipboard")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.contentView = container

        let size = label.intrinsicContentSize
        let panelSize = NSSize(width: size.width + 24, height: size.height + 16)
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x - panelSize.width / 2, y: mouse.y + 12)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        panel.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
    }
}

private struct SplitTunnelWarningIcon: View {
    let warnings: [String]
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .instantTooltip("Privacy & IP Leak Risk")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Privacy & IP Leak Risk")
                        .font(.headline)
                }
                ForEach(warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(warning)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            .padding(14)
            .frame(maxWidth: 340)
        }
    }
}

private var menuItemTargetKey: UInt8 = 0

private final class MenuItemActionTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}


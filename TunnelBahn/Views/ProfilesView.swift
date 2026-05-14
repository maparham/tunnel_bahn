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
    @State private var importError: String?
    @State private var isPasteSheetPresented = false
    @State private var pastedProfileName = ""
    @State private var pastedConfig = ""
    @State private var editingProfile: WireGuardProfile?
    @State private var deleteConfirmationProfile: WireGuardProfile?
    @State private var isDeleteConfirmationPresented = false
    @State private var overwriteConfirmation: (existing: WireGuardProfile, new: WireGuardProfile)?
    @State private var isOverwriteConfirmationPresented = false
    @State private var profileDetailTab: ProfileDetailTab = .overview
    private let parser = WireGuardConfigParser()
    private let keychainService = KeychainService.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPanel
        }
        .alert("Import Failed", isPresented: .constant(importError != nil), actions: {
            Button("OK") { importError = nil }
        }, message: {
            Text(importError ?? "Unknown error")
        })
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(
                original: profile,
                onSave: { updated in
                    disconnectIfUsingProfile(id: updated.id)
                    profileStore.update(updated)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WireGuard Profiles")
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
            let activeModeLabel = vpnManager.stats.perAppSplitTunnelActive ? "App-Tunnel (selected apps only)" : "Full Tunnel (all traffic)"
            let modeLabel: String = {
                switch vpnManager.stats.state {
                case .connected, .connecting, .reconnecting, .disconnecting:
                    return activeModeLabel
                case .disconnected, .error:
                    return plannedModeLabel
                }
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

                    Button {
                        if isSelectedProfileActive {
                            vpnManager.disconnect()
                        } else {
                            Task { await connectSelectedProfile() }
                        }
                    } label: {
                        if vpnManager.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(isSelectedProfileActive ? "Deactivate" : "Activate")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vpnManager.isBusy)
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
                        bytesIn: vpnManager.stats.bytesIn,
                        bytesOut: vpnManager.stats.bytesOut,
                        rxBytesPerSecond: vpnManager.stats.rxBytesPerSecond,
                        txBytesPerSecond: vpnManager.stats.txBytesPerSecond,
                        lastError: vpnManager.stats.lastError,
                        onEdit: {
                            editingProfile = profileStore.selectedProfile
                        },
                        onRename: { newName in
                            var updated = selectedProfile
                            updated.name = newName
                            profileStore.update(updated)
                        }
                    )
                case .apps:
                    AppsView()
                case .routing:
                    RoutingView()
                }
            }
            .onChange(of: profileStore.selectedProfileID) {
                profileDetailTab = .overview
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
        let view = NSHostingView(rootView:
            profileRow(profile, isConnected: isConnected, onToggle: {
                if vpnManager.stats.connectedProfileID == profile.id {
                    vpnManager.disconnect()
                } else {
                    profileStore.select(id: profile.id)
                    Task { await appState.connectSelectedProfile() }
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
                profileStore.select(id: profile.id)
                Task { await appState.connectSelectedProfile() }
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

    private func profileRow(_ profile: WireGuardProfile, isConnected: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray.opacity(0.35))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(profile.peers.first?.endpoint ?? "No endpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onToggle) {
                Image(systemName: isConnected ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isConnected ? Color.green : Color.primary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(isConnected ? "Turn off" : "Turn on")
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
            importError = error.localizedDescription
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
            importError = error.localizedDescription
        }
    }

    private func resetPasteState() {
        pastedProfileName = ""
        pastedConfig = ""
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

    private func connectSelectedProfile() async {
        await appState.connectSelectedProfile()
    }

    private func copyProfileConfigToClipboard(_ profile: WireGuardProfile) {
        do {
            let config = try renderFullConfig(profile: profile)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(config, forType: .string)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func renderFullConfig(profile: WireGuardProfile) throws -> String {
        let privateKey = try keychainService.read(account: profile.interface.privateKeyRef)

        var lines: [String] = [
            "[Interface]",
            "PrivateKey = \(privateKey)",
        ]

        if !profile.interface.addresses.isEmpty {
            lines.append("Address = \(profile.interface.addresses.joined(separator: ", "))")
        }
        if !profile.interface.dnsServers.isEmpty {
            lines.append("DNS = \(profile.interface.dnsServers.joined(separator: ", "))")
        }
        if let mtu = profile.interface.mtu {
            lines.append("MTU = \(mtu)")
        }

        for peer in profile.peers {
            lines.append("")
            lines.append("[Peer]")
            lines.append("PublicKey = \(peer.publicKey)")
            if let presharedKeyRef = peer.presharedKeyRef {
                let psk = try keychainService.read(account: presharedKeyRef)
                lines.append("PresharedKey = \(psk)")
            }
            lines.append("AllowedIPs = \(peer.allowedIPs.joined(separator: ", "))")
            lines.append("Endpoint = \(peer.endpoint)")
            if let keepalive = peer.persistentKeepalive {
                lines.append("PersistentKeepalive = \(keepalive)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
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

private var menuItemTargetKey: UInt8 = 0

private final class MenuItemActionTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}


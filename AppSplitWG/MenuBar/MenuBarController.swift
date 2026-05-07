import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, ObservableObject, NSMenuDelegate {
    private static let rateFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private var statusItem: NSStatusItem?
    private var connectProfileHandler: ((UUID) -> Void)?
    private var disconnectHandler: (() -> Void)?
    private var openHandler: (() -> Void)?
    private var menuRefreshTimer: Timer?
    private var isMenuOpen = false
    private weak var tunnelRatesMenuItem: NSMenuItem?
    private var currentState: VPNConnectionState = .disconnected
    private var currentEndpoint: String?
    private var currentPublicIP: String?
    private var currentPublicIPLocation: String?
    private var currentRxRate: Double = 0
    private var currentTxRate: Double = 0
    private var currentTunnelModeLabel: String = "Full Tunnel"
    private var profiles: [WireGuardProfile] = []
    private var selectedProfileID: UUID?
    private var activeProfileID: UUID?
    private var isBusy = false

    func configure(
        onConnectProfile: @escaping (UUID) -> Void,
        onDisconnect: @escaping () -> Void,
        onOpen: @escaping () -> Void
    ) {
        debugLog("configure called")
        connectProfileHandler = onConnectProfile
        disconnectHandler = onDisconnect
        openHandler = onOpen

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        statusItem?.button?.image = statusBarCompositeImage()
        statusItem?.button?.toolTip = "AppSplit WG"
        statusItem?.button?.title = ""
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        statusItem?.menu = buildMenu()
        debugLog("menu configured")
    }

    func update(
        connectionState: VPNConnectionState,
        endpoint: String?,
        publicIP: String?,
        publicIPLocation: String?,
        rxBytesPerSecond: Double,
        txBytesPerSecond: Double,
        tunnelModeLabel: String
    ) {
        let previousState = currentState
        currentState = connectionState
        currentEndpoint = endpoint
        currentPublicIP = publicIP
        currentPublicIPLocation = publicIPLocation
        currentRxRate = rxBytesPerSecond
        currentTxRate = txBytesPerSecond
        currentTunnelModeLabel = tunnelModeLabel
        let isConnected = connectionState == .connected
        if previousState != connectionState {
            debugLog("update connection state=\(connectionState.rawValue)")
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: isConnected ? "checkmark.shield.fill" : "shield.lefthalf.filled",
            accessibilityDescription: "AppSplit WG"
        ) // keep SF symbol loaded to avoid first-use hitch
        statusItem?.button?.image = statusBarCompositeImage()
        statusItem?.button?.title = ""
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        if isMenuOpen {
            refreshLiveRatesItem()
            if currentState == .connected || currentState == .reconnecting {
                startMenuRefreshTimerIfNeeded()
            } else {
                stopMenuRefreshTimer()
            }
        } else {
            statusItem?.menu = buildMenu()
        }
    }

    func updateProfiles(
        _ profiles: [WireGuardProfile],
        selectedProfileID: UUID?,
        activeProfileID: UUID?,
        isBusy: Bool
    ) {
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.activeProfileID = activeProfileID
        self.isBusy = isBusy
        if !isMenuOpen {
            statusItem?.menu = buildMenu()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        tunnelRatesMenuItem = nil

        let open = NSMenuItem(title: "Open UI", action: #selector(openTapped), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        if let tunnelItems = tunnelStatusItems() {
            tunnelItems.forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }

        let connectHeader = NSMenuItem(title: "Connect Profile", action: nil, keyEquivalent: "")
        connectHeader.isEnabled = false
        menu.addItem(connectHeader)

        if profiles.isEmpty {
            let noProfiles = NSMenuItem(title: "No profiles available", action: nil, keyEquivalent: "")
            noProfiles.isEnabled = false
            menu.addItem(noProfiles)
        } else {
            for profile in sortedProfiles() {
                let item = NSMenuItem(title: titleForProfileItem(profile), action: #selector(connectProfileTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id.uuidString
                item.isEnabled = !isBusy
                item.state = .off
                menu.addItem(item)
            }
        }

        let canDisconnect = currentState == .connected || currentState == .connecting || currentState == .reconnecting
        if canDisconnect {
            menu.addItem(.separator())
            let disconnect = NSMenuItem(title: "Disconnect", action: #selector(disconnectTapped), keyEquivalent: "")
            disconnect.target = self
            disconnect.isEnabled = !isBusy
            menu.addItem(disconnect)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func sortedProfiles() -> [WireGuardProfile] {
        profiles.sorted { lhs, rhs in
            profileSortRank(lhs.id) < profileSortRank(rhs.id) ||
                (profileSortRank(lhs.id) == profileSortRank(rhs.id) && lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending)
        }
    }

    private func profileSortRank(_ id: UUID) -> Int {
        // Keep the last-used (selected) profile at the top.
        if id == selectedProfileID { return 0 }
        if id == activeProfileID { return 1 }
        return 2
    }

    private func titleForProfileItem(_ profile: WireGuardProfile) -> String {
        if profile.id == activeProfileID {
            return "\(profile.name) ✓"
        }
        if profile.id == selectedProfileID {
            return "\(profile.name) *"
        }
        return profile.name
    }

    private func tunnelStatusItems() -> [NSMenuItem]? {
        let statusTitle: String
        switch currentState {
        case .connected:
            statusTitle = "Tunnel: Connected"
        case .connecting:
            statusTitle = "Tunnel: Connecting\(statusProfileSuffix())..."
        case .reconnecting:
            statusTitle = "Tunnel: Reconnecting\(statusProfileSuffix())..."
        case .disconnecting:
            statusTitle = "Tunnel: Disconnecting..."
        case .disconnected, .error:
            return nil
        }

        var items: [NSMenuItem] = []
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        items.append(statusItem)

        let modeItem = NSMenuItem(title: "Mode: \(currentTunnelModeLabel)", action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        items.append(modeItem)

        if currentState == .connected || currentState == .reconnecting {
            let ratesItem = NSMenuItem(
                title: "↑ \(formatRate(currentTxRate))  ↓ \(formatRate(currentRxRate))",
                action: nil,
                keyEquivalent: ""
            )
            ratesItem.isEnabled = false
            tunnelRatesMenuItem = ratesItem
            items.append(ratesItem)
        }

        if let currentPublicIP, !currentPublicIP.isEmpty {
            let ipItem = NSMenuItem(title: "Public IP: \(currentPublicIP)", action: nil, keyEquivalent: "")
            ipItem.isEnabled = false
            items.append(ipItem)
            if let currentPublicIPLocation, !currentPublicIPLocation.isEmpty {
                let locationItem = NSMenuItem(title: "Location: \(currentPublicIPLocation)", action: nil, keyEquivalent: "")
                locationItem.isEnabled = false
                items.append(locationItem)
            }
        } else if currentState == .connected || currentState == .reconnecting {
            let loadingItem = NSMenuItem(title: "Public IP: Detecting...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            items.append(loadingItem)
        } else if let endpoint = currentEndpoint, !endpoint.isEmpty {
            let endpointItem = NSMenuItem(title: "Endpoint: \(endpoint)", action: nil, keyEquivalent: "")
            endpointItem.isEnabled = false
            items.append(endpointItem)
        }

        return items
    }

    private func statusProfileSuffix() -> String {
        let preferredID = activeProfileID ?? selectedProfileID
        guard let preferredID,
              let profile = profiles.first(where: { $0.id == preferredID })
        else {
            return ""
        }
        return " \(profile.name)"
    }

    @objc private func connectProfileTapped(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let profileID = UUID(uuidString: rawID)
        else {
            debugLog("menu action: connect profile failed (invalid represented object)")
            return
        }
        debugLog("menu action: connect profile id=\(profileID.uuidString)")
        connectProfileHandler?(profileID)
    }

    @objc private func disconnectTapped() {
        debugLog("menu action: disconnect")
        disconnectHandler?()
    }

    @objc private func openTapped() {
        debugLog("menu action: open app")
        openHandler?()
    }

    @objc private func quitTapped() {
        debugLog("menu action: quit")
        NSApp.terminate(nil)
    }

    private func debugLog(_ message: String) {
        print("[DEBUG][MenuBar] \(message)")
    }

    func menuWillOpen(_: NSMenu) {
        isMenuOpen = true
        refreshLiveRatesItem()
        startMenuRefreshTimerIfNeeded()
    }

    func menuDidClose(_: NSMenu) {
        isMenuOpen = false
        stopMenuRefreshTimer()
    }

    private func startMenuRefreshTimerIfNeeded() {
        guard menuRefreshTimer == nil else { return }
        guard currentState == .connected || currentState == .reconnecting else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLiveRatesItem()
            }
        }
        menuRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMenuRefreshTimer() {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    private func refreshLiveRatesItem() {
        guard isMenuOpen else { return }
        guard let tunnelRatesMenuItem else { return }
        guard currentState == .connected || currentState == .reconnecting else { return }
        let title = "↑ \(formatRate(currentTxRate))  ↓ \(formatRate(currentRxRate))"
        if tunnelRatesMenuItem.title != title {
            tunnelRatesMenuItem.title = title
        }
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        let amount = Int64(max(0, bytesPerSecond.rounded()))
        if amount == 0 {
            return "0 KB/s"
        }
        return "\(Self.rateFormatter.string(fromByteCount: amount))/s"
    }

    private func statusBarRatesTitle() -> String {
        guard currentState == .connected || currentState == .reconnecting else { return "" }
        return "\(formatRate(currentTxRate)) ↑\n\(formatRate(currentRxRate)) ↓"
    }

    private func statusBarCompositeImage() -> NSImage {
        let text = statusBarRatesTitle()
        let iconName = (currentState == .connected) ? "checkmark.shield.fill" : "shield.lefthalf.filled"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let iconAreaWidth: CGFloat = 20
        let rightPadding: CGFloat = 2
        let measuredTextWidth = maxLineWidth(for: text, font: font)
        let dynamicWidth = text.isEmpty
            ? iconAreaWidth
            : ceil(iconAreaWidth + measuredTextWidth + rightPadding)
        let size = NSSize(width: max(iconAreaWidth, dynamicWidth), height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            if let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: "AppSplit WG")?
                .withSymbolConfiguration(iconConfig)
            {
                let iconRect = NSRect(x: 2, y: (rect.height - 14) / 2, width: 14, height: 14)
                icon.draw(in: iconRect)
            }

            guard !text.isEmpty else { return true }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byClipping
            paragraph.lineSpacing = -1
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let textRect = NSRect(x: iconAreaWidth, y: 1, width: rect.width - iconAreaWidth, height: rect.height - 1)
            text.draw(in: textRect, withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func maxLineWidth(for text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.reduce(0) { currentMax, line in
            let width = NSString(string: line).size(withAttributes: [.font: font]).width
            return max(currentMax, width)
        }
    }
}

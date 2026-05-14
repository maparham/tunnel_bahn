import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, ObservableObject, NSMenuDelegate {
    private enum RoutingModeMenuTag: Int {
        case fullTunnel = 40_001
        case appTunnel = 40_002
    }

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
    private var selectRoutingModeHandler: ((AppSettings.RoutingMode) -> Void)?
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
    private var routingMode: AppSettings.RoutingMode = .fullTunnel
    private var canEnableAppTunnelRouting = false
    private var vpnShowsAsOn = false
    private var destinationFilterSummary: String?
    private var showTrafficRates = true
    private var appStateCancellable: AnyCancellable?

    /// Asset name: `TunnelBahn/Resources/Assets.xcassets/MenuBarTunnel.imageset`
    private static let menuBarTunnelAssetName = "MenuBarTunnel"
    private static let menuBarTunnelBaseImage: NSImage? = NSImage(named: menuBarTunnelAssetName)

    func configure(
        onConnectProfile: @escaping (UUID) -> Void,
        onDisconnect: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onSelectRoutingMode: @escaping (AppSettings.RoutingMode) -> Void
    ) {
        debugLog("configure called")
        connectProfileHandler = onConnectProfile
        disconnectHandler = onDisconnect
        openHandler = onOpen
        selectRoutingModeHandler = onSelectRoutingMode

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        statusItem?.button?.image = statusBarCompositeImage()
        statusItem?.button?.toolTip = vpnToolTipText()
        statusItem?.button?.title = ""
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        statusItem?.menu = buildMenu()
        debugLog("menu configured")
    }

    /// Subscribe to `appState` changes via Combine so the tray updates even when the window is closed.
    func bindAppState(_ appState: AppState, refreshMenuBar: @escaping @MainActor () -> Void) {
        appStateCancellable = appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self != nil else { return }
                // objectWillChange fires *before* the mutation; defer one runloop turn so
                // all @Published values have already been committed when we read them.
                DispatchQueue.main.async {
                    refreshMenuBar()
                }
            }
    }

    func update(
        connectionState: VPNConnectionState,
        endpoint: String?,
        publicIP: String?,
        publicIPLocation: String?,
        rxBytesPerSecond: Double,
        txBytesPerSecond: Double,
        tunnelModeLabel: String,
        routingMode: AppSettings.RoutingMode,
        canEnableAppTunnelRouting: Bool,
        destinationFilterSummary: String? = nil,
        showTrafficRates: Bool = true
    ) {
        let previousState = currentState
        currentState = connectionState
        currentEndpoint = endpoint
        currentPublicIP = publicIP
        currentPublicIPLocation = publicIPLocation
        currentRxRate = rxBytesPerSecond
        currentTxRate = txBytesPerSecond
        currentTunnelModeLabel = tunnelModeLabel
        self.routingMode = routingMode
        self.canEnableAppTunnelRouting = canEnableAppTunnelRouting
        self.destinationFilterSummary = destinationFilterSummary
        self.showTrafficRates = showTrafficRates
        vpnShowsAsOn = Self.vpnIsActive(connectionState)
        if previousState != connectionState {
            debugLog("update connection state=\(connectionState.rawValue)")
        }
        _ = Self.menuBarTunnelBaseImage // keep asset decoded to reduce first-paint hitch
        statusItem?.button?.image = statusBarCompositeImage()
        statusItem?.button?.title = ""
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        statusItem?.button?.toolTip = vpnToolTipText()
        if isMenuOpen {
            refreshLiveRatesItem()
            syncRoutingModeMenuItems()
            syncProfileMenuItems()
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
        if isMenuOpen {
            syncRoutingModeMenuItems()
            syncProfileMenuItems()
        } else {
            statusItem?.menu = buildMenu()
        }
        statusItem?.button?.toolTip = vpnToolTipText()
    }

    private static func vpnIsActive(_ state: VPNConnectionState) -> Bool {
        state == .connected || state == .reconnecting
    }

    /// Full-tunnel / app-tunnel must not change while the Network Extension session is up or in transition.
    private func routingModeControlsDisabled() -> Bool {
        isBusy
            || currentState == .connected
            || currentState == .connecting
            || currentState == .reconnecting
            || currentState == .disconnecting
    }

    private func syncRoutingModeMenuItems() {
        guard let menu = statusItem?.menu else { return }
        let locked = routingModeControlsDisabled()
        let appTunnelSelectable = AppConstants.isPerAppSplitTunnelEnabled && canEnableAppTunnelRouting
        if let item = menu.item(withTag: RoutingModeMenuTag.fullTunnel.rawValue) {
            item.isEnabled = !locked
            item.state = routingMode == .fullTunnel ? .on : .off
        }
        if let item = menu.item(withTag: RoutingModeMenuTag.appTunnel.rawValue) {
            item.isEnabled = !locked && appTunnelSelectable
            item.state = routingMode == .appTunnel ? .on : .off
        }
    }

    private func syncProfileMenuItems() {
        guard let menu = statusItem?.menu else { return }
        let connectAction = #selector(connectProfileTapped(_:))
        for item in menu.items {
            guard item.action == connectAction,
                  let idString = item.representedObject as? String,
                  let id = UUID(uuidString: idString),
                  let profile = profiles.first(where: { $0.id == id })
            else {
                continue
            }
            applyProfileMenuItemPresentation(item, profile: profile)
        }
    }

    private func applyProfileMenuItemPresentation(_ item: NSMenuItem, profile: WireGuardProfile) {
        let text = titleForProfileItem(profile)
        item.title = text
        let isConnectedProfile = profile.id == activeProfileID
        let baseMenuFont = NSFont.menuFont(ofSize: 0)
        let font = isConnectedProfile
            ? NSFontManager.shared.convert(baseMenuFont, toHaveTrait: .boldFontMask)
            : NSFontManager.shared.convert(baseMenuFont, toHaveTrait: .unboldFontMask)
        let enabled = !isBusy
        let color: NSColor = enabled ? .labelColor : .disabledControlTextColor
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        item.isEnabled = enabled
    }

    private func vpnToolTipText() -> String {
        vpnShowsAsOn ? "TunnelBahn — VPN on" : "TunnelBahn — VPN off"
    }

    private func vpnAccessibilityDescription() -> String {
        vpnShowsAsOn ? "TunnelBahn, VPN on" : "TunnelBahn, VPN off"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Otherwise AppKit re-validates items with actions and overrides `isEnabled` (e.g. routing mode while connected).
        menu.autoenablesItems = false
        menu.delegate = self
        tunnelRatesMenuItem = nil

        let canDisconnect = currentState == .connected || currentState == .connecting || currentState == .reconnecting
        if canDisconnect {
            let disconnect = NSMenuItem(title: "Disconnect", action: #selector(disconnectTapped), keyEquivalent: "")
            disconnect.target = self
            disconnect.isEnabled = !isBusy
            menu.addItem(disconnect)
        }

        let settings = NSMenuItem(title: "Settings", action: #selector(openTapped), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let routingLocked = routingModeControlsDisabled()

        let fullTunnelItem = NSMenuItem(
            title: "Full-Tunnel Mode",
            action: #selector(selectFullTunnelMode(_:)),
            keyEquivalent: ""
        )
        fullTunnelItem.target = self
        fullTunnelItem.tag = RoutingModeMenuTag.fullTunnel.rawValue
        fullTunnelItem.state = routingMode == .fullTunnel ? .on : .off
        fullTunnelItem.isEnabled = !routingLocked
        menu.addItem(fullTunnelItem)

        let appTunnelItem = NSMenuItem(
            title: "App-Tunnel Mode",
            action: #selector(selectAppTunnelMode(_:)),
            keyEquivalent: ""
        )
        appTunnelItem.target = self
        appTunnelItem.tag = RoutingModeMenuTag.appTunnel.rawValue
        appTunnelItem.state = routingMode == .appTunnel ? .on : .off
        let appTunnelSelectable = AppConstants.isPerAppSplitTunnelEnabled && canEnableAppTunnelRouting
        appTunnelItem.isEnabled = !routingLocked && appTunnelSelectable
        menu.addItem(appTunnelItem)

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
            for profile in profiles {
                let item = NSMenuItem(title: "", action: #selector(connectProfileTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id.uuidString
                item.state = .off
                applyProfileMenuItemPresentation(item, profile: profile)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
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

        if let destinationFilterSummary, !destinationFilterSummary.isEmpty {
            let destItem = NSMenuItem(title: destinationFilterSummary, action: nil, keyEquivalent: "")
            destItem.isEnabled = false
            items.append(destItem)
        }

        if showTrafficRates, currentState == .connected || currentState == .reconnecting {
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
        debugLog("menu action: settings")
        openHandler?()
    }

    @objc private func selectFullTunnelMode(_: NSMenuItem) {
        guard !routingModeControlsDisabled() else { return }
        debugLog("menu action: routing full tunnel")
        selectRoutingModeHandler?(.fullTunnel)
    }

    @objc private func selectAppTunnelMode(_: NSMenuItem) {
        guard !routingModeControlsDisabled() else { return }
        debugLog("menu action: routing app tunnel")
        guard AppConstants.isPerAppSplitTunnelEnabled, canEnableAppTunnelRouting else { return }
        selectRoutingModeHandler?(.appTunnel)
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
        syncRoutingModeMenuItems()
        syncProfileMenuItems()
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
        if amount < 1024 {
            return "\(amount) B/s"
        }
        return "\(Self.rateFormatter.string(fromByteCount: amount))/s"
    }

    private func statusBarRatesTitle() -> String {
        guard showTrafficRates else { return "" }
        guard currentState == .connected || currentState == .reconnecting else { return "" }
        return "\(formatRate(currentTxRate)) ↑\n\(formatRate(currentRxRate)) ↓"
    }

    /// Same tunnel artwork for on/off; inactive is the same pixels at lower opacity (option 1 — no tint fill).
    private static func drawMenuBarTunnelIcon(in iconRect: NSRect, active: Bool) {
        guard let base = menuBarTunnelBaseImage else { return }
        let sourceSize = base.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let scale = min(iconRect.width / sourceSize.width, iconRect.height / sourceSize.height)
        let w = sourceSize.width * scale
        let h = sourceSize.height * scale
        let drawn = NSRect(
            x: iconRect.midX - w / 2,
            y: iconRect.midY - h / 2,
            width: w,
            height: h
        )
        let opacity: CGFloat = active ? 1 : 0.62
        base.draw(
            in: drawn,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: opacity
        )
    }

    private func statusBarCompositeImage() -> NSImage {
        let text = statusBarRatesTitle()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let iconSide: CGFloat = 22
        let iconLeading: CGFloat = 2
        let iconAreaWidth = iconLeading + iconSide + 4
        let rightPadding: CGFloat = 2
        let measuredTextWidth = maxLineWidth(for: text, font: font)
        let dynamicWidth = text.isEmpty
            ? iconAreaWidth
            : ceil(iconAreaWidth + measuredTextWidth + rightPadding)
        let barHeight: CGFloat = max(22, iconSide + 2)
        let size = NSSize(width: max(iconAreaWidth, dynamicWidth), height: barHeight)
        let showsVPNOn = vpnShowsAsOn
        let image = NSImage(size: size, flipped: false) { rect in
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setBlendMode(.copy)
                ctx.clear(rect)
                ctx.restoreGState()
            }
            let iconRect = NSRect(x: iconLeading, y: (rect.height - iconSide) / 2, width: iconSide, height: iconSide)
            Self.drawMenuBarTunnelIcon(in: iconRect, active: showsVPNOn)

            guard !text.isEmpty else { return true }
            
            // Two-column layout: numbers left-aligned, arrows right-aligned
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let lineHeight = font.pointSize + 2
            let textAreaX = iconAreaWidth
            let textAreaWidth = rect.width - iconAreaWidth - rightPadding
            
            let leftParagraph = NSMutableParagraphStyle()
            leftParagraph.alignment = .left
            leftParagraph.lineBreakMode = .byClipping
            
            let rightParagraph = NSMutableParagraphStyle()
            rightParagraph.alignment = .right
            rightParagraph.lineBreakMode = .byClipping
            
            let leftAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: leftParagraph,
            ]
            
            let rightAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: rightParagraph,
            ]
            
            for (index, line) in lines.enumerated() {
                let yPos = rect.height - 2 - CGFloat(index + 1) * lineHeight
                let lineRect = NSRect(x: textAreaX, y: yPos, width: textAreaWidth, height: lineHeight)
                
                // Split at arrow: e.g. "15 B/s ↑" -> ["15 B/s", "↑"]
                if let arrowRange = line.range(of: "[↑↓]", options: .regularExpression) {
                    let rateText = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let arrowText = String(line[arrowRange])
                    
                    // Draw rate left-aligned
                    rateText.draw(in: lineRect, withAttributes: leftAttributes)
                    
                    // Draw arrow right-aligned
                    arrowText.draw(in: lineRect, withAttributes: rightAttributes)
                } else {
                    // Fallback: draw entire line left-aligned
                    line.draw(in: lineRect, withAttributes: leftAttributes)
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = vpnAccessibilityDescription()
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

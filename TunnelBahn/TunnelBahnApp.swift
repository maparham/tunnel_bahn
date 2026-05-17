import SwiftUI
import AppKit
import OSLog

@MainActor
private struct MenuBarRefreshInputs: Equatable {
    let vpnState: VPNConnectionState
    let endpoint: String?
    let publicIP: String?
    let publicIPLocation: String?
    let rxBytesPerSecond: Double
    let txBytesPerSecond: Double
    let perAppSplitTunnelActive: Bool
    let isBusy: Bool
    let profiles: [WireGuardProfile]
    let selectedProfileID: UUID?
    let appRules: [AppRule]
    let routingMode: AppSettings.RoutingMode
    let destinationFilterMenuSummary: String?

    init(appState: AppState) {
        vpnState = appState.vpnManager.stats.state
        endpoint = appState.vpnManager.stats.endpoint
        publicIP = appState.vpnManager.stats.publicIP
        publicIPLocation = appState.vpnManager.stats.publicIPLocation
        rxBytesPerSecond = appState.vpnManager.stats.rxBytesPerSecond
        txBytesPerSecond = appState.vpnManager.stats.txBytesPerSecond
        perAppSplitTunnelActive = appState.vpnManager.stats.perAppSplitTunnelActive
        isBusy = appState.vpnManager.isBusy
        profiles = appState.profileStore.profiles
        selectedProfileID = appState.profileStore.selectedProfileID
        appRules = appState.appRuleStore.rules
        routingMode = appState.settings.routingMode
        destinationFilterMenuSummary = Self.makeDestinationFilterSummary(appState: appState)
    }

    private static func makeDestinationFilterSummary(appState: AppState) -> String? {
        let state = appState.vpnManager.stats.state
        guard state == .connected || state == .reconnecting else { return nil }
        guard appState.settings.enforceDestinationFiltering else { return nil }
        let cidrs = appState.destinationRuleStore.enabledFlattenedCidrs(
                customRangesEnabled: appState.settings.destinationCustomRangesEnabled,
                bulkListsEnabled: appState.settings.destinationBulkListsEnabled,
                domainNamesEnabled: appState.settings.destinationDomainNamesEnabled
            )
            .filter { !IPCIDRMatcher.prepare([$0]).isEmpty }
        if cidrs.isEmpty {
            return "Dest filter (no valid ranges)"
        }
        return "Dest filter: \(cidrs.count) range\(cidrs.count == 1 ? "" : "s")"
    }
}

@main
struct TunnelBahnApp: App {
    private static let osLog = Logger(subsystem: "com.tunnelbahn.mac", category: "App")

    @StateObject private var appState = AppState()
    @StateObject private var menuBarController = MenuBarController()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var autoReconnectTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup("TunnelBahn") {
            ContentView()
                .environmentObject(appState)
                .task {
                    traceLog("app startup task started")
                    appDelegate.vpnManager = appState.vpnManager
                    appDelegate.appState = appState
                    // Wire window delegate now that the SwiftUI window definitely exists.
                    if let window = NSApp.windows.first {
                        window.delegate = appDelegate
                    }
                    await appState.vpnManager.load()
                    appState.syncDestinationRoutingFileWithPreferences()
                    menuBarController.configure(
                        onConnectProfile: { profileID in
                            Task { await connect(profileID: profileID) }
                        },
                        onDisconnect: { appState.vpnManager.disconnect() },
                        onOpen: {
                            NSApp.setActivationPolicy(.regular)
                            NSApp.applicationIconImage = makeDockIcon()
                            NSApp.windows.first?.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        },
                        onSelectRoutingMode: { mode in
                            if mode == .appTunnel {
                                let routed = appState.appRuleStore.rules.filter { $0.action == .routeVPN }.count
                                guard AppConstants.isPerAppSplitTunnelEnabled, routed > 0 else { return }
                            }
                            appState.settings.routingMode = mode
                        }
                    )
                    menuBarController.bindAppState(appState, refreshMenuBar: refreshMenuBar)
                    refreshMenuBar()
                    traceLog("menu configured with state=\(appState.vpnManager.stats.state.rawValue)")
                }
        }
        .defaultSize(width: 980, height: 680)
        // Scene-level observers keep firing even when the window is closed.
        .onChange(of: appState.vpnManager.stats.state) { _, newValue in
            traceLog("vpn state changed -> \(newValue.rawValue)")
            if newValue != .disconnected {
                autoReconnectTask?.cancel()
                autoReconnectTask = nil
            }
            if newValue == .disconnected,
               appState.settings.autoReconnect,
               appState.vpnManager.shouldAutoReconnect
            {
                autoReconnectTask?.cancel()
                let task = Task { @MainActor in
                    defer { autoReconnectTask = nil }
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    guard appState.vpnManager.stats.state == .disconnected,
                          appState.settings.autoReconnect,
                          appState.vpnManager.shouldAutoReconnect
                    else {
                        traceLog("auto reconnect skipped (state or settings changed)")
                        return
                    }
                    guard !appState.vpnManager.isBusy else {
                        traceLog("auto reconnect skipped (manager busy)")
                        return
                    }
                    traceLog("auto reconnect attempt starting")
                    Task { await quickConnect() }
                }
                autoReconnectTask = task
                traceLog("auto reconnect scheduled in 2 seconds (single-flight)")
            }
        }
        .commands {
            CommandMenu("VPN") {
                Button("Connect") { Task { await quickConnect() } }
                    .disabled(appState.vpnManager.stats.state == .connected || appState.vpnManager.stats.state == .connecting)
                Button("Disconnect") { appState.vpnManager.disconnect() }
                    .disabled(appState.vpnManager.stats.state == .disconnected || appState.vpnManager.stats.state == .error)
            }
        }
    }

    private func quickConnect() async {
        guard let profile = appState.profileStore.selectedProfile else {
            traceLog("quickConnect aborted: no selected profile")
            return
        }
        await connect(profile: profile)
    }

    private func connect(profileID: UUID) async {
        guard let profile = appState.profileStore.profiles.first(where: { $0.id == profileID }) else {
            traceLog("connect aborted: missing profile id=\(profileID.uuidString)")
            return
        }
        await connect(profile: profile)
    }

    private func connect(profile: WireGuardProfile) async {
        traceLog("connect using profile=\(profile.name)")
        await appState.connectProfile(profile)
    }

    private func refreshMenuBar() {
        let selectedRoutedApps = appState.appRuleStore.rules.filter { $0.action == .routeVPN }.count
        let plannedModeLabel: String = {
            switch appState.settings.routingMode {
            case .fullTunnel:
                return "Full Tunnel"
            case .appTunnel:
                return selectedRoutedApps > 0 ? "App-Tunnel" : "Full Tunnel"
            }
        }()
        let activeModeLabel = appState.vpnManager.stats.perAppSplitTunnelActive ? "App-Tunnel" : "Full Tunnel"
        let modeLabel: String = {
            switch appState.vpnManager.stats.state {
            case .connected, .connecting, .reconnecting, .disconnecting:
                return activeModeLabel
            case .disconnected, .error:
                return plannedModeLabel
            }
        }()
        let canEnableAppTunnelRouting = AppConstants.isPerAppSplitTunnelEnabled && selectedRoutedApps > 0
        let menuInputs = MenuBarRefreshInputs(appState: appState)
        menuBarController.update(
            connectionState: appState.vpnManager.stats.state,
            endpoint: appState.vpnManager.stats.endpoint,
            publicIP: appState.vpnManager.stats.publicIP,
            publicIPLocation: appState.vpnManager.stats.publicIPLocation,
            rxBytesPerSecond: appState.vpnManager.stats.rxBytesPerSecond,
            txBytesPerSecond: appState.vpnManager.stats.txBytesPerSecond,
            tunnelModeLabel: modeLabel,
            routingMode: appState.settings.routingMode,
            canEnableAppTunnelRouting: canEnableAppTunnelRouting,
            destinationFilterSummary: menuInputs.destinationFilterMenuSummary,
            showTrafficRates: appState.settings.showTrafficRates
        )
        menuBarController.updateProfiles(
            appState.profileStore.profiles,
            selectedProfileID: appState.profileStore.selectedProfileID,
            activeProfileID: activeProfileID(),
            isBusy: appState.vpnManager.isBusy
        )
    }

    private func activeProfileID() -> UUID? {
        switch appState.vpnManager.stats.state {
        case .connecting, .reconnecting, .disconnecting, .connected:
            return appState.vpnManager.stats.connectedProfileID ?? appState.profileStore.selectedProfileID
        case .disconnected, .error:
            return nil
        }
    }

    private func traceLog(_ message: String) {
        Self.osLog.debug("\(message, privacy: .public)")
    }
}

private func makeDockIcon() -> NSImage? {
    guard let source = NSImage(named: "MenuBarTunnel") else { return nil }
    let canvasSize: CGFloat = 512
    let iconFraction: CGFloat = 0.85
    let sourceSize = source.size
    guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
    let scale = min(canvasSize * iconFraction / sourceSize.width,
                    canvasSize * iconFraction / sourceSize.height)
    let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let canvas = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
    canvas.lockFocus()
    let origin = NSPoint(x: (canvasSize - drawSize.width) / 2,
                         y: (canvasSize - drawSize.height) / 2)
    source.draw(in: NSRect(origin: origin, size: drawSize))
    canvas.unlockFocus()
    return canvas
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let lifecycleLog = Logger(subsystem: "com.tunnelbahn.mac", category: "AppLifecycle")

    weak var vpnManager: VPNManager?
    weak var appState: AppState?
    private var terminateReplySent = false
    private var isHandlingTermination = false

    func applicationDidFinishLaunching(_: Notification) {
        // Start as a regular app (Dock visible) since the window opens on launch.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = makeDockIcon()
        if let window = NSApp.windows.first {
            window.delegate = self
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return false
    }

    // When the window is re-opened (e.g. clicking the tray "Open" item), restore the Dock icon.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = makeDockIcon()
        return true
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide instead of closing so the window doesn't end up minimized in the Dock.
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = nil
        return false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Flush any in-flight debounced edits to the routing snapshot synchronously,
        // before the run loop spins down. `applicationWillTerminate` is too late —
        // it fires close to process exit and main-queue async hops can be skipped.
        // Safe to call on the cancel path too: persisting current state is idempotent
        // with what the 500 ms debounce would have written anyway.
        if !isHandlingTermination {
            appState?.saveCurrentSnapshot()
        }

        guard let vpnManager else {
            Self.lifecycleLog.debug("no VPN manager; terminating immediately")
            return .terminateNow
        }
        if !vpnManager.shouldDeferTerminationForVPN() {
            Self.lifecycleLog.debug("Network Extension inactive (tunnel stopped); terminating immediately")
            return .terminateNow
        }
        if isHandlingTermination {
            Self.lifecycleLog.debug("termination already in progress; waiting")
            return .terminateLater
        }

        NSApp.activate(ignoringOtherApps: true)
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)
            ?? ProcessInfo.processInfo.processName
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You are about to exit \(appName). Disconnect the VPN?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertSecondButtonReturn {
            Self.lifecycleLog.debug("user cancelled quit while VPN active")
            return .terminateCancel
        }

        Self.lifecycleLog.debug("VPN active (state=\(vpnManager.stats.state.rawValue)); initiating disconnect before termination")
        isHandlingTermination = true
        Task { @MainActor in
            await vpnManager.disconnectForTermination()
            Self.lifecycleLog.debug("VPN disconnect completed; allowing app to terminate")
            if !terminateReplySent {
                terminateReplySent = true
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        // Cleanup belongs in `applicationShouldTerminate`; async work started here often won't finish before exit.
        if let vpnManager {
            Self.lifecycleLog.debug(
                "applicationWillTerminate stats=\(vpnManager.stats.state.rawValue) deferVPNQuit=\(vpnManager.shouldDeferTerminationForVPN())"
            )
        } else {
            Self.lifecycleLog.debug("applicationWillTerminate (no vpnManager)")
        }
    }
}

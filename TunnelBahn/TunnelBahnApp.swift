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
                    await appState.vpnManager.load()
                    menuBarController.configure(
                        onConnectProfile: { profileID in
                            Task { await connect(profileID: profileID) }
                        },
                        onDisconnect: { appState.vpnManager.disconnect() },
                        onOpen: { NSApp.activate(ignoringOtherApps: true) },
                        onSelectRoutingMode: { mode in
                            if mode == .appTunnel {
                                let routed = appState.appRuleStore.rules.filter { $0.action == .routeVPN }.count
                                guard AppConstants.isPerAppSplitTunnelEnabled, routed > 0 else { return }
                            }
                            appState.settings.routingMode = mode
                        }
                    )
                    refreshMenuBar()
                    traceLog("menu configured with state=\(appState.vpnManager.stats.state.rawValue)")
                }
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
                .onChange(of: MenuBarRefreshInputs(appState: appState)) { _, _ in
                    refreshMenuBar()
                }
        }
        .defaultSize(width: 980, height: 680)
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
        guard let selectedProfileID = appState.profileStore.selectedProfileID else {
            traceLog("quickConnect aborted: no selected profile")
            return
        }
        await connect(profileID: selectedProfileID)
    }

    private func connect(profileID: UUID) async {
        guard let profile = appState.profileStore.profiles.first(where: { $0.id == profileID }) else {
            traceLog("connect aborted: missing profile id=\(profileID.uuidString)")
            return
        }
        appState.profileStore.select(id: profileID)
        traceLog("connect using profile=\(profile.name)")
        await appState.vpnManager.connect(
            profile: profile,
            rules: appState.appRuleStore.rules
        )
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
        menuBarController.update(
            connectionState: appState.vpnManager.stats.state,
            endpoint: appState.vpnManager.stats.endpoint,
            publicIP: appState.vpnManager.stats.publicIP,
            publicIPLocation: appState.vpnManager.stats.publicIPLocation,
            rxBytesPerSecond: appState.vpnManager.stats.rxBytesPerSecond,
            txBytesPerSecond: appState.vpnManager.stats.txBytesPerSecond,
            tunnelModeLabel: modeLabel,
            routingMode: appState.settings.routingMode,
            canEnableAppTunnelRouting: canEnableAppTunnelRouting
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
        #if DEBUG
        print("[DEBUG][App] \(message)")
        #endif
        Self.osLog.debug("\(message, privacy: .public)")
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var vpnManager: VPNManager?
    private var terminateReplySent = false
    private var isHandlingTermination = false

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let vpnManager else {
            print("[DEBUG][AppLifecycle] no VPN manager; terminating immediately")
            return .terminateNow
        }
        if !vpnManager.shouldDeferTerminationForVPN() {
            print("[DEBUG][AppLifecycle] Network Extension inactive (tunnel stopped); terminating immediately")
            return .terminateNow
        }
        if isHandlingTermination {
            print("[DEBUG][AppLifecycle] termination already in progress; waiting")
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
            print("[DEBUG][AppLifecycle] user cancelled quit while VPN active")
            return .terminateCancel
        }

        print("[DEBUG][AppLifecycle] VPN active (state=\(vpnManager.stats.state.rawValue)); initiating disconnect before termination")
        isHandlingTermination = true
        Task { @MainActor in
            await vpnManager.disconnectForTermination()
            print("[DEBUG][AppLifecycle] VPN disconnect completed; allowing app to terminate")
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
            print(
                "[DEBUG][AppLifecycle] applicationWillTerminate stats=\(vpnManager.stats.state.rawValue) " +
                "deferVPNQuit=\(vpnManager.shouldDeferTerminationForVPN())"
            )
        } else {
            print("[DEBUG][AppLifecycle] applicationWillTerminate (no vpnManager)")
        }
    }
}

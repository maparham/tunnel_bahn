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
    let routingMode: RoutingMode
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
    private static let osLog = AppLog(subsystem: "com.tunnelbahn.mac", category: "App")

    @StateObject private var appState = AppState()
    @StateObject private var menuBarController = MenuBarController()
    @StateObject private var sysExtManager = SystemExtensionManager()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var autoReconnectTask: Task<Void, Never>?
    @State private var missingKeyProfileNames: [String] = []
    /// Last profile the tunnel was actually connected with. `stats.connectedProfileID` is already
    /// cleared by the time the `.disconnected` state change is observed, so auto-reconnect must
    /// capture it here while it's still set — otherwise a Wi-Fi blip reconnects whatever profile
    /// happens to be *selected* (possibly never connected) with its routing rules.
    @State private var lastConnectedProfileID: UUID?

    var body: some Scene {
        WindowGroup("TunnelBahn") {
            ContentView()
                .environmentObject(appState)
                .alert(
                    "Network Extensions Need Approval",
                    isPresented: $sysExtManager.needsUserApproval
                ) {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    Button("Later") {}
                } message: {
                    Text("TunnelBahn's network extensions need your approval before the VPN can connect.\n\nOpen System Settings → General → Login Items & Extensions → Network Extensions and enable both TunnelBahn extensions.")
                }
                .alert(
                    "Profiles Need Re-import",
                    isPresented: Binding(
                        get: { !missingKeyProfileNames.isEmpty },
                        set: { if !$0 { missingKeyProfileNames = [] } }
                    )
                ) {
                    Button("OK") { missingKeyProfileNames = [] }
                } message: {
                    // swiftlint:disable:next line_length
                    let names = missingKeyProfileNames.joined(separator: ", ")
                    let plural = missingKeyProfileNames.count == 1 ? "profile is" : "profiles are"
                    Text(
                        "The private key for \(missingKeyProfileNames.count) \(plural) missing from the keychain: \(names).\n\n" +
                        "This usually happens after a build change that created a new app-group container. " +
                        "Delete these profiles and re-import them from their original .conf files."
                    )
                }
                .onChange(of: appState.profileStore.profilesWithMissingKeys) { _, stillMissing in
                    let stillMissingNames = Set(stillMissing.map(\.name))
                    // Remove profiles whose keys have been fixed (re-import cleared them).
                    missingKeyProfileNames = missingKeyProfileNames.filter { stillMissingNames.contains($0) }
                    // Surface profiles whose keys went missing after startup (e.g., bad import).
                    for name in stillMissingNames where !missingKeyProfileNames.contains(name) {
                        missingKeyProfileNames.append(name)
                    }
                }
                .task {
                    traceLog("app startup task started")
                    sysExtManager.installExtensions()
                    appDelegate.vpnManager = appState.vpnManager
                    // Wire window delegate now that the SwiftUI window definitely exists.
                    if let window = NSApp.windows.first {
                        window.delegate = appDelegate
                    }
                    await appState.vpnManager.load()
                    appDelegate.appState = appState
                    // Drain any tunnelbahn:// URL that arrived during cold launch before
                    // vpnManager.load() completed.
                    if let pendingURL = AppLifecycleDelegate.pendingTestURL {
                        AppLifecycleDelegate.pendingTestURL = nil
                        appDelegate.handleTestURL(pendingURL)
                    }
                    appState.profileStore.runKeychainIntegrityCheck()
                    missingKeyProfileNames = appState.profileStore.profilesWithMissingKeys.map(\.name)
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
            if let connectedID = appState.vpnManager.stats.connectedProfileID {
                lastConnectedProfileID = connectedID
            }
            if newValue != .disconnected {
                autoReconnectTask?.cancel()
                autoReconnectTask = nil
            }
            if newValue == .disconnected,
               appState.settings.autoReconnect,
               appState.vpnManager.shouldAutoReconnect
            {
                autoReconnectTask?.cancel()
                // Reconnect the profile that was connected when the tunnel dropped, not
                // whatever is currently selected in the UI. Captured at drop-detection time
                // so a mid-wait selection change cannot redirect the reconnect either.
                let targetProfileID = lastConnectedProfileID
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
                    if let targetProfileID,
                       appState.profileStore.profiles.contains(where: { $0.id == targetProfileID }) {
                        Task { await connect(profileID: targetProfileID) }
                    } else {
                        // Previous profile unknown or deleted — fall back to the selected profile.
                        Task { await quickConnect() }
                    }
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
            enforceDestinationFiltering: appState.settings.enforceDestinationFiltering,
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
        Self.osLog.debug("\(message)")
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
    private static let lifecycleLog = AppLog(subsystem: "com.tunnelbahn.mac", category: "AppLifecycle")
    private static let testURLLog = AppLog(subsystem: "com.tunnelbahn.mac", category: "TestURL")

    weak var vpnManager: VPNManager?
    weak var appState: AppState?
    static var pendingTestURL: URL?
    private var terminateReplySent = false
    private var isHandlingTermination = false

    func applicationDidFinishLaunching(_: Notification) {
        // Start as a regular app (Dock visible) since the window opens on launch.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = makeDockIcon()
        if let window = NSApp.windows.first {
            window.delegate = self
        }
        // Register for tunnelbahn:// URL opens. NSAppleEventManager fires regardless of
        // window visibility — required for menu-bar-only mode where .onOpenURL won't fire.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLAppleEvent(_:withReplyEvent:)),
            forEventClass: 0x4755524C, // 'GURL' kInternetEventClass
            andEventID: 0x4755524C    // 'GURL' kAEGetURL
        )
    }

    // MARK: - tunnelbahn:// URL scheme
    // Format: tunnelbahn://test?routingMode=app_tunnel&enforceDestinationFiltering=true&connect=Proton

    @objc private func handleURLAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: 0x2D2D2D2D)?.stringValue, // keyDirectObject '----'
              let url = URL(string: urlString) else { return }
        handleTestURL(url)
    }

    func handleTestURL(_ url: URL) {
        guard url.scheme == "tunnelbahn", url.host == "test" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return }

        func param(_ name: String) -> String? { queryItems.first(where: { $0.name == name })?.value }
        func flag(_ name: String) -> Bool { param(name).map { $0 == "true" || $0 == "1" } ?? false }

        let routingMode: RoutingMode? = param("routingMode").flatMap { RoutingMode(rawValue: $0) }
        let enforceFilter: Bool? = param("enforceDestinationFiltering").map { $0 == "true" || $0 == "1" }
        let profileName: String? = param("connect")
        let shouldDisconnect = param("disconnect") != nil

        Self.testURLLog.notice(
            "[APPSPLIT_TEST_URL] routingMode=\(routingMode?.rawValue ?? "nil") enforceFilter=\(enforceFilter.map(String.init) ?? "nil") connect=\(profileName ?? "nil") disconnect=\(shouldDisconnect)"
        )

        guard let appState else {
            Self.testURLLog.notice("[APPSPLIT_TEST_URL] appState not ready — queuing URL until load completes")
            AppLifecycleDelegate.pendingTestURL = url
            return
        }

        // ── setDestinationCIDRs=1.1.1.1/32,... ────────────────────────────────
        if let rawCidrs = param("setDestinationCIDRs") {
            let cidrs = rawCidrs.split(separator: ",").map(String.init)
            let rules = cidrs.map { DestinationCidrRule(cidr: $0.trimmingCharacters(in: .whitespaces), isEnabled: true) }
            appState.destinationRuleStore.replaceAll(
                customRules: rules,
                bulkGroups: appState.destinationRuleStore.bulkGroups,
                domainRules: appState.destinationRuleStore.domainRules
            )
            Self.testURLLog.notice("[APPSPLIT_TEST_URL] set \(rules.count) destination CIDRs")
        }

        // ── clearDestinationCIDRs=1 ────────────────────────────────────────────
        if flag("clearDestinationCIDRs") {
            appState.destinationRuleStore.replaceAll(
                customRules: [],
                bulkGroups: appState.destinationRuleStore.bulkGroups,
                domainRules: appState.destinationRuleStore.domainRules
            )
            Self.testURLLog.notice("[APPSPLIT_TEST_URL] cleared destination CIDRs")
        }

        // ── setAppRules=com.apple.Terminal,... ────────────────────────────────
        if let rawBundleIDs = param("setAppRules") {
            let bundleIDs = rawBundleIDs.split(separator: ",").map(String.init)
            let rules = bundleIDs.map { bundleID -> AppRule in
                let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
                return AppRule(
                    displayName: trimmed,
                    bundleIdentifier: trimmed,
                    appPath: "",
                    action: .routeVPN
                )
            }
            appState.appRuleStore.replaceAll(rules)
            Self.testURLLog.notice("[APPSPLIT_TEST_URL] set \(rules.count) app rules")
        }

        // ── clearAppRules=1 ───────────────────────────────────────────────────
        if flag("clearAppRules") {
            appState.appRuleStore.replaceAll([])
            Self.testURLLog.notice("[APPSPLIT_TEST_URL] cleared app rules")
        }

        // ── saveSnapshot=<name> ───────────────────────────────────────────────
        if let snapName = param("saveSnapshot") {
            let snapshot: [String: Any] = [
                "routingMode": appState.settings.routingMode.rawValue,
                "enforceDestinationFiltering": appState.settings.enforceDestinationFiltering
            ]
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
                let path = "/tmp/tunnelbahn-snapshot-\(snapName).json"
                try? data.write(to: URL(fileURLWithPath: path))
                Self.testURLLog.notice("[APPSPLIT_TEST_URL] saved snapshot '\(snapName)' to \(path)")
            }
        }

        // ── restoreSnapshot=<name> ────────────────────────────────────────────
        if let snapName = param("restoreSnapshot") {
            let path = "/tmp/tunnelbahn-snapshot-\(snapName).json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let rawMode = obj["routingMode"] as? String,
                   let mode = RoutingMode(rawValue: rawMode) {
                    appState.settings.routingMode = mode
                }
                if let enforce = obj["enforceDestinationFiltering"] as? Bool {
                    appState.settings.enforceDestinationFiltering = enforce
                }
                Self.testURLLog.notice("[APPSPLIT_TEST_URL] restored snapshot '\(snapName)'")
            } else {
                Self.testURLLog.error("[APPSPLIT_TEST_URL] snapshot '\(snapName)' not found at \(path)")
            }
        }

        // ── dump=stats ────────────────────────────────────────────────────────
        if param("dump") == "stats" {
            let state = appState.vpnManager.stats
            let obj: [String: Any] = [
                "vpnState": state.state.rawValue,
                "routingMode": appState.settings.routingMode.rawValue,
                "enforceDestinationFiltering": appState.settings.enforceDestinationFiltering,
                "perAppSplitTunnelActive": state.perAppSplitTunnelActive,
                "connectedProfileID": state.connectedProfileID?.uuidString ?? "",
                "publicIP": state.publicIP ?? "",
                "appRuleCount": appState.appRuleStore.rules.count,
                "destinationCidrCount": appState.destinationRuleStore.customRules.count,
                "destinationBulkListsEnabled": appState.settings.destinationBulkListsEnabled,
                "destinationCustomRangesEnabled": appState.settings.destinationCustomRangesEnabled
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
                let path = "/tmp/tunnelbahn-state.json"
                try? data.write(to: URL(fileURLWithPath: path))
                Self.testURLLog.notice("[APPSPLIT_TEST_URL] wrote stats to \(path)")
            }
        }

        // ── probe=<url> ───────────────────────────────────────────────────────
        if let probeURLString = param("probe"),
           let probeURL = URL(string: probeURLString) {
            let outputPath = param("probeOutput") ?? "/tmp/tunnelbahn-probe.json"
            Task {
                let start = Date()
                var result: [String: Any] = ["url": probeURLString, "ts": ISO8601DateFormatter().string(from: start)]
                Self.testURLLog.notice("[APPSPLIT_PROBE] probing \(probeURLString)")
                do {
                    let (data, response) = try await URLSession.shared.data(from: probeURL)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    result["exitIP"] = body
                    result["statusCode"] = status
                    result["durationMs"] = ms
                    Self.testURLLog.notice("[APPSPLIT_PROBE] result exitIP=\(body) status=\(status) ms=\(ms)")
                } catch {
                    result["error"] = error.localizedDescription
                    Self.testURLLog.error("[APPSPLIT_PROBE] error: \(error.localizedDescription)")
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
                    try? data.write(to: URL(fileURLWithPath: outputPath))
                }
            }
        }

        // ── quit=1 ────────────────────────────────────────────────────────────
        if flag("quit") {
            Self.testURLLog.notice("[APPSPLIT_TEST_URL] quit requested")
            NSApp.terminate(nil)
            return
        }

        // ── disconnect ────────────────────────────────────────────────────────
        if shouldDisconnect && profileName == nil {
            appState.vpnManager.disconnect()
            return
        }

        // ── connect (with optional routingMode / enforceDestinationFiltering) ─
        guard let profileName else { return }

        guard let profile = appState.profileStore.profiles.first(where: {
            $0.name.caseInsensitiveCompare(profileName) == .orderedSame
        }) else {
            Self.testURLLog.error("[APPSPLIT_TEST_URL] profile '\(profileName)' not found")
            return
        }

        let mode = routingMode ?? appState.settings.routingMode
        let enforce = enforceFilter ?? appState.settings.enforceDestinationFiltering

        Task {
            await appState.connectProfileForTest(profile, routingMode: mode, enforceDestinationFiltering: enforce)
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

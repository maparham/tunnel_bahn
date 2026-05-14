import Foundation
import Combine
import Darwin
import NetworkExtension
import OSLog

@MainActor
final class VPNManager: ObservableObject {
    private static let osLog = Logger(subsystem: "com.tunnelbahn.mac", category: "VPN")

    @Published private(set) var stats: ConnectionStats = .empty
    @Published private(set) var isBusy = false
    @Published private(set) var shouldAutoReconnect = false

    private var manager = NETunnelProviderManager()
    private let settings: AppSettings
    private weak var resourceMonitor: ResourceMonitor?
    private var resourceMonitorCancellables = Set<AnyCancellable>()
    private let publicIPSession = URLSession(configuration: .ephemeral)
    private var statsRefreshTask: Task<Void, Never>?
    private var lastTransferSnapshot: TransferSnapshot?
    private var lastPerAppAggregateSnapshot: TransferSnapshot?
    private let perAppStatsProxy = PerAppStatsProxyManager()
    private let scopedBookmarks = ScopedBookmarkStore()
    private static let perAppRoutedSigningIDsDefaultsKey = "perAppRoutedSigningIdentifiers"
    private static let perAppRouteAllFlowsDefaultsKey = "perAppRouteAllIdentifiedFlows"

    /// Set by `disconnect()` to make in-flight `connect` exit waits and tear down.
    private var connectCancelled = false
    /// Finishes proxy/probe/stats when the tunnel connects after the initial NEVPN wait window.
    private var pendingConnectCompletionTask: Task<Void, Never>?
    /// True while `connect` is in-flight (used so termination does not race connect/teardown).
    private var connectRunning = false
    /// Single shared disconnect work item so manual disconnect and termination cannot run `performDisconnect` concurrently.
    private var disconnectCoordinatorTask: Task<Void, Never>?

    init(settings: AppSettings, resourceMonitor: ResourceMonitor?) {
        self.settings = settings
        self.resourceMonitor = resourceMonitor
        traceLog("init")
        if let resourceMonitor {
            resourceMonitor.$cpuUsage
                .combineLatest(resourceMonitor.$memoryUsage)
                .sink { [weak self] _, _ in
                    self?.syncResourceStatsFromMonitor()
                    self?.syncExtensionResourceStats()
                }
                .store(in: &resourceMonitorCancellables)
        }
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.traceLog("received NEVPNStatusDidChange")
                self?.syncStatus()
            }
        }
    }

    func load() async {
        traceLog("load started")
        do {
            try await loadOrCreateTunnelManagerOnAppLaunch()
            syncStatus()
            if stats.state == .connected {
                await refreshPublicIPAndLocation()
                startStatsRefreshIfNeeded()
            }
            traceLog("load preferences finished")
        } catch {
            stats.state = .error
            stats.lastError = error.localizedDescription
            traceLog("load preferences failed: \(error.localizedDescription)")
        }
    }

    func connect(profile: WireGuardProfile, rules: [AppRule], destinationCidrStrings: [String]) async {
        if isBusy {
            emitConnectSummaryLine(
                outcome: "ignored",
                profileName: profile.name,
                reason: "busy",
                wantedAppTunnel: nil,
                neAppRuleCount: nil,
                routingMethod: nil,
                onDemand: nil,
                managerAppRuleCount: nil
            )
            traceLog("connect ignored because manager is busy")
            return
        }
        traceLog("connect requested profile=\(profile.name) rules=\(rules.count)")
        connectCancelled = false
        pendingConnectCompletionTask?.cancel()
        pendingConnectCompletionTask = nil
        isBusy = true
        defer { isBusy = false }
        connectRunning = true
        defer { connectRunning = false }
        stats.state = .connecting
        stats.lastError = nil
        // Snapshot who was connected (or last runtime on disk) *before* we assign the new
        // profile ID — otherwise switch detection always sees `profile.id` and skips the stop.
        let priorConnectedProfileID = stats.connectedProfileID ?? loadPersistedRuntimeProfile()?.id
        stats.connectedProfileID = profile.id

        do {
            try AppGroupStore.ensureSharedDirectories()
            traceLog("shared directories ensured")

            // If a tunnel is already active, and the user is activating a *different* profile,
            // we must stop the current tunnel first. Otherwise the running extension can keep
            // using the old in-memory session/config, and traffic continues via the previous
            // profile even though the UI "activated" the new one.
            let isSwitchingProfiles = (priorConnectedProfileID != nil && priorConnectedProfileID != profile.id)
            if isSwitchingProfiles {
                let status = manager.connection.status
                if status != .disconnected && status != .invalid {
                    // Prevent macOS from auto-restarting the *old* tunnel config via On-Demand
                    // while we are in the middle of a profile switch.
                    if manager.isOnDemandEnabled || manager.isEnabled {
                        manager.isOnDemandEnabled = false
                        manager.isEnabled = false
                        do {
                            try await manager.saveToPreferences()
                            try await manager.loadFromPreferences()
                            traceLog("profile switch: temporarily disabled on-demand and manager before stop")
                        } catch {
                            traceLog("profile switch: failed to disable on-demand before stop: \(error.localizedDescription)")
                        }
                    }

                    traceLog(
                        "profile switch: stopping existing tunnel status=\(connectionStatusString(status)) " +
                        "from=\(priorConnectedProfileID?.uuidString ?? "unknown") to=\(profile.id.uuidString)"
                    )
                    manager.connection.stopVPNTunnel()

                    // Wait for a clean disconnect so the next start picks up the new runtime state.
                    let deadline = Date().addingTimeInterval(10)
                    while Date() < deadline {
                        if connectCancelled {
                            break
                        }
                        let s = manager.connection.status
                        if s == .disconnected || s == .invalid {
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(200))
                    }

                    if connectCancelled {
                        traceLog("connect aborted during profile switch disconnect wait")
                        await coordinatedDisconnect(waitForTunnelStop: false)
                        return
                    }

                    let finalStatus = manager.connection.status
                    traceLog("profile switch: after stop status=\(connectionStatusString(finalStatus))")
                }
            }

            let extensionProfile = try resolvePeerEndpointsForExtension(profile)

            guard extensionProfile.peers.count == 1 else {
                stats.state = .error
                stats.lastError =
                    "Only one WireGuard peer is supported. Remove extra peers or use separate profiles."
                stats.connectedProfileID = nil
                stats.endpoint = nil
                emitConnectSummaryLine(
                    outcome: "aborted",
                    profileName: profile.name,
                    reason: "multi_peer_not_supported",
                    wantedAppTunnel: nil,
                    neAppRuleCount: nil,
                    routingMethod: nil,
                    onDemand: nil,
                    managerAppRuleCount: nil
                )
                return
            }

            let appTunnelModeSelected = (settings.routingMode == .appTunnel)
            if appTunnelModeSelected {
                for rule in rules where rule.action == .routeVPN {
                    let resolved = scopedBookmarks.startAccess(
                        for: rule,
                        onStaleBookmark: { [weak self] message in self?.traceLog("WARNING: \(message)") }
                    )
                    if resolved == nil, rule.bookmarkData != nil {
                        traceLog(
                            "WARNING: could not resolve security-scoped bookmark for \(rule.displayName); SecStaticCode may use fallback requirement"
                        )
                    }
                }
            }
            var requestedAppRules = appTunnelModeSelected ? NEAppRuleBuilder.build(from: rules, log: traceLog) : []
            if !appTunnelModeSelected, !rules.isEmpty {
                traceLog("routing mode is full-tunnel; ignoring \(rules.count) app rules")
            }

            if AppConstants.isPerAppSplitTunnelEnabled, appTunnelModeSelected {
                let fromHardcodedPaths = NEAppRuleBuilder.buildFromAlwaysIncludedPaths(
                    AppConstants.perAppAlwaysIncludeAppPaths,
                    log: traceLog
                )
                if !fromHardcodedPaths.isEmpty {
                    traceLog("perAppAlwaysIncludeAppPaths: added \(fromHardcodedPaths.count) NEAppRule(s) before merge")
                }
                requestedAppRules = NEAppRuleBuilder.dedupe(requestedAppRules + fromHardcodedPaths, log: traceLog)
            } else if !requestedAppRules.isEmpty {
                traceLog("App-tunnel split is disabled; ignoring \(requestedAppRules.count) built NEAppRule(s), using full tunnel")
                requestedAppRules = []
            }
            scopedBookmarks.stopAllAccess()

            let hasAppTunnelSelection =
                AppConstants.isPerAppSplitTunnelEnabled && appTunnelModeSelected && !requestedAppRules.isEmpty
            let isFullTrafficAccountingShape =
                AppConstants.isPerAppSplitTunnelEnabled
                && (settings.routingMode == .fullTunnel || (appTunnelModeSelected && requestedAppRules.isEmpty))

            let profileOkForAccounting = profileHasDefaultRoute(profile: extensionProfile)

            /// When true: `forPerAppVPN` + transparent proxy + tunnel rules that only include the proxy
            /// (and optional host probe). Used for app-tunnel split **or** full-tunnel app-tunnel byte accounting.
            let useAppTunnelNEStack = hasAppTunnelSelection || (profileOkForAccounting && isFullTrafficAccountingShape)

            Self.osLog.notice("[connect] routingMode=\(self.settings.routingMode.rawValue, privacy: .public) hasAppTunnelSelection=\(hasAppTunnelSelection, privacy: .public) profileOkForAccounting=\(profileOkForAccounting, privacy: .public) useAppTunnelNEStack=\(useAppTunnelNEStack, privacy: .public) requestedAppRules=\(requestedAppRules.count, privacy: .public)")

            #if DEBUG
            logConnectModeDecision(
                originalProfile: profile,
                extensionProfile: extensionProfile,
                selectedRules: rules,
                requestedAppRules: requestedAppRules,
                useAppTunnelNEStack: useAppTunnelNEStack,
                hasAppTunnelSelection: hasAppTunnelSelection,
                routeAllFlowsForStats: useAppTunnelNEStack && !hasAppTunnelSelection
            )
            #endif


            if useAppTunnelNEStack {
                // Always stop the proxy before writing the destination routing file so that
                // startProxy() always reads the current config. Without this, a same-profile
                // reconnect leaves the proxy running with stale in-memory state (enforceFiltering
                // may be false until the next flush tick fires, causing minutes of broken bypass).
                await perAppStatsProxy.disable()
                traceLog("connect: transparent proxy stopped before config write")

                if hasAppTunnelSelection {
                    persistPerAppStatsRoutingConfig(appRules: requestedAppRules, routeAllIdentifiedFlows: false)
                    traceLog("app-tunnel split: persisted \(requestedAppRules.count) NEAppRule signing identifier(s) for transparent proxy filter")
                } else {
                    persistPerAppStatsRoutingConfig(appRules: [], routeAllIdentifiedFlows: true)
                    traceLog("full-traffic accounting: persisted routeAllIdentifiedFlows for transparent proxy")
                }
                // For split-tunnel profiles, force destination filtering to AllowedIPs so the
                // proxy only relays flows whose destination is inside the tunnel. Flows to
                // internet destinations are returned false → OS handles them natively via en0.
                if !profileOkForAccounting {
                    let allowedIPs = extensionProfile.peers.flatMap { $0.allowedIPs }
                    persistDestinationRoutingFromHost(enforceFiltering: true, ranges: allowedIPs)
                    traceLog("split-tunnel: proxy destination filter set to AllowedIPs (\(allowedIPs.count) CIDRs)")
                } else {
                    persistDestinationRoutingFromHost(
                        enforceFiltering: settings.enforceDestinationFiltering,
                        ranges: destinationCidrStrings
                    )
                }
                traceLog(
                    "VPN accounting stack: tunnel DNS servers=[\(extensionProfile.interface.dnsServers.joined(separator: ", "))]"
                )
            } else {
                clearPersistedPerAppRoutedSigningIdentifiers()
                traceLog("full-tunnel mode: destination-IP routing only (no app-tunnel accounting stack; missing default-route peer or split disabled)")
            }

            var rulesForVPNManager = requestedAppRules
            if useAppTunnelNEStack, settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                rulesForVPNManager = NEAppRuleBuilder.dedupe(rulesForVPNManager + [hostRule], log: traceLog)
                traceLog(
                    "tunnel probe: merged host app NEAppRule signingID=\(hostRule.matchSigningIdentifier) totalRules=\(rulesForVPNManager.count)"
                )
            }
            
            // Proxy signing ID is always in appRules when the NE stack is active. The proxy
            // intercepts flows and decides per-flow whether to relay (in-AllowedIPs) or pass
            // through (out-of-AllowedIPs). Apps not in tunnel appRules bypass the tunnel entirely.
            var finalAppRules: [NEAppRule] = []
            if useAppTunnelNEStack {
                let proxyRule = PerAppStatsProxyManager.extensionAppRule()
                finalAppRules = [proxyRule]
                if settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                    finalAppRules = NEAppRuleBuilder.dedupe(finalAppRules + [hostRule], log: traceLog)
                }
                traceLog("app-tunnel: tunnel NEAppRules count=\(finalAppRules.count)")
            }

            let runtimeStateData = try makeRuntimeStateData(profile: extensionProfile)
            try persistRuntimeState(data: runtimeStateData)
            traceLog("runtime state persisted for profile=\(profile.name)")
            let appRules = useAppTunnelNEStack ? finalAppRules : []
            try await configureManager(
                appRules: appRules,
                runtimeStateData: runtimeStateData,
                useAppTunnelNEStack: useAppTunnelNEStack
            )

            if connectCancelled {
                await coordinatedDisconnect(waitForTunnelStop: false)
                return
            }
            
            #if DEBUG
            logManagerConfiguration()
            logEffectiveExtensionProfile(extensionProfile)
            #endif

            if connectCancelled {
                await coordinatedDisconnect(waitForTunnelStop: false)
                return
            }

            try manager.connection.startVPNTunnel()

            let waitOutcome = await waitForTunnelConnectOutcome(timeoutSeconds: 20)
            switch waitOutcome {
            case .cancelled:
                traceLog("connect cancelled during NEVPN wait")
                await coordinatedDisconnect(waitForTunnelStop: false)
                return
            case .failed:
                stats.state = .error
                stats.lastError =
                    "Tunnel did not connect (status: \(connectionStatusString(manager.connection.status))). If you were switching profiles, try again."
                stats.connectedProfileID = nil
                stats.endpoint = nil
                traceLog(
                    "connect failed: NEVPNStatus not connecting (\(connectionStatusString(manager.connection.status)))"
                )
                emitConnectSummaryLine(
                    outcome: "error",
                    profileName: profile.name,
                    reason: "nevpn_not_connected",
                    wantedAppTunnel: hasAppTunnelSelection,
                    neAppRuleCount: rulesForVPNManager.count,
                    routingMethod: manager.routingMethod.rawValue,
                    onDemand: manager.isOnDemandEnabled,
                    managerAppRuleCount: manager.appRules.count
                )
                return
            case .stillStarting:
                Self.osLog.notice("[connect] NEVPN stillStarting — deferring proxy/stats start")
                traceLog("connect: NEVPN still starting after initial wait; deferring completion")
                stats.state = .connecting
                stats.connectedProfileID = profile.id
                stats.lastError = nil
                scheduleDeferredConnectCompletion(
                    profile: profile,
                    extensionProfile: extensionProfile,
                    hasAppTunnelSelection: hasAppTunnelSelection,
                    useAppTunnelNEStack: useAppTunnelNEStack,
                    profileOkForAccounting: profileOkForAccounting,
                    rulesForVPNManagerCount: rulesForVPNManager.count
                )
                return
            case .connected:
                await applySuccessfulConnectPostTunnel(
                    profile: profile,
                    extensionProfile: extensionProfile,
                    hasAppTunnelSelection: hasAppTunnelSelection,
                    useAppTunnelNEStack: useAppTunnelNEStack,
                    profileOkForAccounting: profileOkForAccounting,
                    rulesForVPNManagerCount: rulesForVPNManager.count
                )
            }
        } catch {
            if connectCancelled {
                await coordinatedDisconnect(waitForTunnelStop: false)
                return
            }
            stats.state = .error
            let message = userFacingConnectErrorMessage(error)
            stats.lastError = message
            stats.connectedProfileID = nil
            stats.endpoint = nil
            traceLog("connect failed: \(message)")
            emitConnectSummaryLine(
                outcome: "error",
                profileName: profile.name,
                reason: "connect_exception",
                wantedAppTunnel: nil,
                neAppRuleCount: nil,
                routingMethod: nil,
                onDemand: nil,
                managerAppRuleCount: nil,
                detail: message
            )
        }
    }

    /// Re-writes the shared destination-routing snapshot from host preferences (`TransparentProxyProvider`
    /// reads it when running; keeping it aligned while disconnected avoids stale `enforce` if the tunnel
    /// stops outside TunnelBahn and is started again).
    @MainActor
    func syncDestinationRoutingFromHostActivity(enforceFiltering: Bool, flattenedRangeStrings: [String]) {
        persistDestinationRoutingFromHost(enforceFiltering: enforceFiltering, ranges: flattenedRangeStrings)
    }

    private func profileHasDefaultRoute(profile: WireGuardProfile) -> Bool {
        // Treat as default-route if any peer includes 0.0.0.0/0 or ::/0.
        for peer in profile.peers {
            if peer.allowedIPs.contains("0.0.0.0/0") || peer.allowedIPs.contains("::/0") {
                return true
            }
        }
        return false
    }

    private enum TunnelConnectWaitOutcome {
        case connected
        case cancelled
        case stillStarting
        case failed
    }

    private func waitForTunnelConnectOutcome(timeoutSeconds: TimeInterval) async -> TunnelConnectWaitOutcome {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if connectCancelled {
                return .cancelled
            }
            let status = manager.connection.status
            if status == .connected {
                return .connected
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if connectCancelled {
            return .cancelled
        }
        let status = manager.connection.status
        if status == .connected {
            return .connected
        }
        switch status {
        case .connecting, .reasserting:
            return .stillStarting
        default:
            return .failed
        }
    }

    private func scheduleDeferredConnectCompletion(
        profile: WireGuardProfile,
        extensionProfile: WireGuardProfile,
        hasAppTunnelSelection: Bool,
        useAppTunnelNEStack: Bool,
        profileOkForAccounting: Bool,
        rulesForVPNManagerCount: Int
    ) {
        let expectedID = profile.id
        pendingConnectCompletionTask?.cancel()
        pendingConnectCompletionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishConnectAfterDeferredTunnelWait(
                expectedProfileID: expectedID,
                profile: profile,
                extensionProfile: extensionProfile,
                hasAppTunnelSelection: hasAppTunnelSelection,
                useAppTunnelNEStack: useAppTunnelNEStack,
                profileOkForAccounting: profileOkForAccounting,
                rulesForVPNManagerCount: rulesForVPNManagerCount
            )
        }
    }

    private func finishConnectAfterDeferredTunnelWait(
        expectedProfileID: UUID,
        profile: WireGuardProfile,
        extensionProfile: WireGuardProfile,
        hasAppTunnelSelection: Bool,
        useAppTunnelNEStack: Bool,
        profileOkForAccounting: Bool,
        rulesForVPNManagerCount: Int
    ) async {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if Task.isCancelled || connectCancelled {
                return
            }
            if stats.connectedProfileID != expectedProfileID {
                return
            }
            let status = manager.connection.status
            if status == .connected {
                await applySuccessfulConnectPostTunnel(
                    profile: profile,
                    extensionProfile: extensionProfile,
                    hasAppTunnelSelection: hasAppTunnelSelection,
                    useAppTunnelNEStack: useAppTunnelNEStack,
                    profileOkForAccounting: profileOkForAccounting,
                    rulesForVPNManagerCount: rulesForVPNManagerCount
                )
                return
            }
            if status == .disconnected || status == .invalid {
                stats.state = .error
                stats.lastError = "Tunnel failed before connecting."
                stats.connectedProfileID = nil
                stats.endpoint = nil
                emitConnectSummaryLine(
                    outcome: "error",
                    profileName: profile.name,
                    reason: "nevpn_failed_while_waiting",
                    wantedAppTunnel: hasAppTunnelSelection,
                    neAppRuleCount: rulesForVPNManagerCount,
                    routingMethod: manager.routingMethod.rawValue,
                    onDemand: manager.isOnDemandEnabled,
                    managerAppRuleCount: manager.appRules.count
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        if Task.isCancelled || connectCancelled {
            return
        }
        if manager.connection.status == .connected {
            await applySuccessfulConnectPostTunnel(
                profile: profile,
                extensionProfile: extensionProfile,
                hasAppTunnelSelection: hasAppTunnelSelection,
                useAppTunnelNEStack: useAppTunnelNEStack,
                profileOkForAccounting: profileOkForAccounting,
                rulesForVPNManagerCount: rulesForVPNManagerCount
            )
            return
        }

        stats.state = .error
        stats.lastError = "Tunnel did not become ready in time."
        stats.connectedProfileID = nil
        stats.endpoint = nil
        emitConnectSummaryLine(
            outcome: "error",
            profileName: profile.name,
            reason: "nevpn_deferred_timeout",
            wantedAppTunnel: hasAppTunnelSelection,
            neAppRuleCount: rulesForVPNManagerCount,
            routingMethod: manager.routingMethod.rawValue,
            onDemand: manager.isOnDemandEnabled,
            managerAppRuleCount: manager.appRules.count
        )
    }

    private func applySuccessfulConnectPostTunnel(
        profile: WireGuardProfile,
        extensionProfile: WireGuardProfile,
        hasAppTunnelSelection: Bool,
        useAppTunnelNEStack: Bool,
        profileOkForAccounting: Bool,
        rulesForVPNManagerCount: Int
    ) async {
        Self.osLog.notice("[connect] applySuccessfulConnectPostTunnel hasAppTunnelSelection=\(hasAppTunnelSelection, privacy: .public) useAppTunnelNEStack=\(useAppTunnelNEStack, privacy: .public) profileOkForAccounting=\(profileOkForAccounting, privacy: .public)")
        stats.state = .connected
        stats.connectedAt = .now
        stats.connectedProfileID = profile.id
        stats.endpoint = extensionProfile.peers.first?.endpoint
        stats.perAppSplitTunnelActive = hasAppTunnelSelection && useAppTunnelNEStack
        stats.perAppStatsCollectionActive = useAppTunnelNEStack

        if useAppTunnelNEStack {
            PerAppTransferStore.reset()
            Self.osLog.notice("[connect] calling perAppStatsProxy.enable()")
            do {
                try await perAppStatsProxy.enable()
                Self.osLog.notice("[connect] perAppStatsProxy.enable() succeeded")
            } catch {
                Self.osLog.notice("[connect] perAppStatsProxy.enable() failed: \(error.localizedDescription, privacy: .public)")
                traceLog("app-tunnel stats proxy enable failed: \(error.localizedDescription)")
                stats.lastError = "App-tunnel accounting could not start: \(error.localizedDescription)"
                await coordinatedDisconnect(waitForTunnelStop: false)
                emitConnectSummaryLine(
                    outcome: "error",
                    profileName: profile.name,
                    reason: "app_tunnel_proxy_failed",
                    wantedAppTunnel: hasAppTunnelSelection,
                    neAppRuleCount: rulesForVPNManagerCount,
                    routingMethod: manager.routingMethod.rawValue,
                    onDemand: manager.isOnDemandEnabled,
                    managerAppRuleCount: manager.appRules.count,
                    detail: error.localizedDescription
                )
                return
            }
            if connectCancelled {
                traceLog("connect post-tunnel: user disconnected during proxy enable")
                await coordinatedDisconnect(waitForTunnelStop: false)
                return
            }
            guard stats.state == .connected, stats.connectedProfileID == profile.id else {
                traceLog(
                    "connect post-tunnel: superseded during proxy enable (state=\(stats.state.rawValue)); skipping finish"
                )
                return
            }
        }

        // Defer ipify / probes so bring-up is not blocked (~10–45s) while the tunnel is already usable.
        let probePhase: TunnelProbePhase = {
            guard useAppTunnelNEStack else { return .fullTunnel }
            guard hasAppTunnelSelection else { return .fullTunnel }
            if settings.includeHostAppInPerAppRulesForProbe { return .appTunnelHostIncluded }
            return .appTunnelHostExcluded
        }()
        let profileID = profile.id
        let runProbe = settings.runTunnelConnectivityProbe

        startStatsRefreshIfNeeded()
        shouldAutoReconnect = true
        traceLog("connect succeeded endpoint=\(stats.endpoint ?? "unknown")")
        emitConnectSummaryLine(
            outcome: "ok",
            profileName: profile.name,
            reason: nil,
            wantedAppTunnel: hasAppTunnelSelection,
            neAppRuleCount: rulesForVPNManagerCount,
            routingMethod: manager.routingMethod.rawValue,
            onDemand: manager.isOnDemandEnabled,
            managerAppRuleCount: manager.appRules.count
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.stats.connectedProfileID == profileID, self.stats.state == .connected else { return }
            if runProbe {
                self.traceLog(
                    "[APPSPLIT_PROBE] nevpn_wait outcome=connected status=\(self.manager.connection.status.rawValue)"
                )
            }
            await self.refreshPublicIPAndLocation()
            guard self.stats.connectedProfileID == profileID, self.stats.state == .connected else { return }
            if runProbe {
                await TunnelConnectivityProbe.run(phase: probePhase, comparePublicIP: self.stats.publicIP)
            }
        }
    }

    /// Used when `includeHostAppInPerAppRulesForProbe` is on so TunnelBahn-initiated probes match app-tunnel VPN routing.
    private func makeHostAppNEAppRule() -> NEAppRule? {
        guard let bid = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bid.isEmpty
        else {
            traceLog("tunnel probe: host app bundle identifier unavailable")
            return nil
        }
        let path = Bundle.main.bundleURL.path
        let requirement: String
        if let designated = NEAppRuleBuilder.designatedRequirementString(forAppAtPath: path, log: traceLog) {
            requirement = designated
        } else {
            requirement = #"anchor apple generic and identifier "\#(bid)""#
            traceLog("tunnel probe: designated requirement unavailable for host app; using fallback")
        }
        return NEAppRule(signingIdentifier: bid, designatedRequirement: requirement)
    }

    func disconnect() {
        connectCancelled = true
        pendingConnectCompletionTask?.cancel()
        pendingConnectCompletionTask = nil
        shouldAutoReconnect = false
        manager.connection.stopVPNTunnel()

        if connectRunning {
            // Connect can still be inside `applySuccessfulConnectPostTunnel` (e.g. awaiting proxy enable)
            // while `stats.state` is already `.connected`. A bare return would skip `coordinatedDisconnect`,
            // so tray Disconnect appears to do nothing until connect finishes.
            traceLog("disconnect: in-flight connect; scheduling coordinated teardown")
        }
        if stats.state == .disconnected, isTunnelFullyStopped() {
            traceLog("disconnect ignored because already disconnected")
            connectCancelled = false
            return
        }
        traceLog("disconnect requested")
        isBusy = true
        stats.state = .disconnecting
        Task {
            await coordinatedDisconnect(waitForTunnelStop: false)
        }
    }

    /// Prefer Network Extension status over UI mirror when deciding whether shutdown is needed before quit.
    func shouldDeferTerminationForVPN() -> Bool {
        !isTunnelFullyStopped()
    }

    func disconnectForTermination() async {
        shouldAutoReconnect = false
        connectCancelled = true
        pendingConnectCompletionTask?.cancel()
        pendingConnectCompletionTask = nil
        manager.connection.stopVPNTunnel()
        await waitForConnectToFinishIfNeeded(timeoutSeconds: 45)

        if stats.state == .disconnected, isTunnelFullyStopped() {
            traceLog("termination cleanup skipped: already fully stopped")
            isBusy = false
            return
        }

        traceLog("termination cleanup requested")
        isBusy = true
        stats.state = .disconnecting
        await coordinatedDisconnect(waitForTunnelStop: true)
        isBusy = false
    }

    private func connectionStatusString(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func logManagerConfiguration() {
        traceLog("=== MANAGER CONFIGURATION DUMP ===")
        traceLog("routingMethod: \(manager.routingMethod.rawValue) (1=destinationIP, 2=sourceApplication)")
        traceLog("isEnabled: \(manager.isEnabled)")
        traceLog("isOnDemandEnabled: \(manager.isOnDemandEnabled)")
        traceLog("localizedDescription: \(manager.localizedDescription ?? "nil")")
        
        let appRules = manager.appRules
        traceLog("appRules count: \(appRules.count)")
        for (index, rule) in appRules.enumerated() {
            traceLog("  appRule[\(index)]: signingID=\(rule.matchSigningIdentifier) domainCount=\(rule.matchDomains?.count ?? 0)")
        }
        
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            traceLog("protocol serverAddress: \(proto.serverAddress ?? "nil")")
            traceLog("protocol bundleID: \(proto.providerBundleIdentifier ?? "nil")")
        }
        
        traceLog("connection status: \(manager.connection.status.rawValue)")
        traceLog("=== END CONFIGURATION DUMP ===")
    }
    
    private func configureManager(appRules: [NEAppRule], runtimeStateData: Data, useAppTunnelNEStack: Bool) async throws {
        traceLog("configureManager started useAppTunnelNEStack=\(useAppTunnelNEStack) appRules=\(appRules.count)")
        try await loadOrCreateTunnelManager(useAppTunnelNEStack: useAppTunnelNEStack)

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.packetTunnelProviderBundleIdentifier
        proto.serverAddress = "TunnelBahn"
        let runtimeStateB64 = runtimeStateData.base64EncodedString()
        proto.providerConfiguration = [
            "profile": "active",
            "runtimeStateB64": runtimeStateB64,
        ]
        manager.localizedDescription = AppConstants.vpnManagerDescription
        manager.protocolConfiguration = proto

        manager.appRules = appRules

        // App-tunnel VPN: On-Demand must include at least one connect rule so matched apps trigger the tunnel.
        // Without onDemandRules, macOS may not route app traffic through the packet tunnel even when connected.
        if useAppTunnelNEStack {
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .any
            manager.onDemandRules = [connectRule]
            manager.isOnDemandEnabled = true
        } else {
            manager.onDemandRules = nil
            manager.isOnDemandEnabled = false
        }
        manager.isEnabled = true

        traceLog(
            "about to save: routingMethod=\(manager.routingMethod.rawValue) isOnDemandEnabled=\(manager.isOnDemandEnabled) " +
            "onDemandRules=\(manager.onDemandRules?.count ?? 0) appRules=\(manager.appRules.count)"
        )

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        traceLog(
            "after reload: routingMethod=\(manager.routingMethod.rawValue) isOnDemandEnabled=\(manager.isOnDemandEnabled) " +
            "onDemandRules=\(manager.onDemandRules?.count ?? 0) appRules=\(manager.appRules.count)"
        )
        traceLog("configureManager finished")
    }

    /// First launch / Settings load: attach to saved manager or create **standard** full-tunnel manager (not app-tunnel NE stack).
    private func loadOrCreateTunnelManagerOnAppLaunch() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        traceLog("loadOrCreateTunnelManagerOnAppLaunch: found \(managers.count) managers")

        for (index, mgr) in managers.enumerated() {
            traceLog("  manager[\(index)]: desc=\(mgr.localizedDescription ?? "nil") routing=\(mgr.routingMethod.rawValue) enabled=\(mgr.isEnabled)")
        }

        let matching = managers.filter { $0.localizedDescription == AppConstants.vpnManagerDescription }
        if let existing = matching.first {
            manager = existing
            if matching.count > 1 {
                for dup in matching.dropFirst() {
                    do { try await dup.removeFromPreferences() } catch {
                        traceLog("failed removing duplicate tunnel config: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Safety: Do NOT adopt unrelated VPN configs. Previous fallback could attach to
        // other WireGuard apps' configs or test managers, causing config corruption.
        // Instead, always create a fresh manager when ours isn't found.
        traceLog("no matching TunnelBahn manager found; creating new standard NETunnelProviderManager")
        manager = NETunnelProviderManager()
    }

    /// Ensures the stored manager type matches the next connection: **standard** for full tunnel, **forPerAppVPN** for split.
    private func loadOrCreateTunnelManager(useAppTunnelNEStack: Bool) async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let matching = managers.filter { $0.localizedDescription == AppConstants.vpnManagerDescription }

        let wantsAppTunnelNEStack = useAppTunnelNEStack

        if let existing = matching.first {
            let hasPerAppRouting = existing.routingMethod == .sourceApplication
            if wantsAppTunnelNEStack != hasPerAppRouting {
                traceLog("replacing tunnel manager: wantAppTunnelNEStack=\(wantsAppTunnelNEStack) current routingMethod=\(existing.routingMethod.rawValue)")
                existing.connection.stopVPNTunnel()
                try? await Task.sleep(for: .seconds(1))
                try await existing.removeFromPreferences()
                for dup in matching.dropFirst() {
                    try? await dup.removeFromPreferences()
                }
                manager = wantsAppTunnelNEStack ? NETunnelProviderManager.forPerAppVPN() : NETunnelProviderManager()
                traceLog("new manager routingMethod=\(manager.routingMethod.rawValue)")
                return
            }

            manager = existing
            if matching.count > 1 {
                for dup in matching.dropFirst() {
                    do { try await dup.removeFromPreferences() } catch {
                        traceLog("failed removing duplicate: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        manager = wantsAppTunnelNEStack ? NETunnelProviderManager.forPerAppVPN() : NETunnelProviderManager()
        traceLog("no saved TunnelBahn manager; created routingMethod=\(manager.routingMethod.rawValue)")
    }

    private func isTunnelFullyStopped() -> Bool {
        let status = manager.connection.status
        return status == .disconnected || status == .invalid
    }

    private func waitForTunnelDisconnected(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isTunnelFullyStopped() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return isTunnelFullyStopped()
    }

    private func waitForConnectToFinishIfNeeded(timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while connectRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if connectRunning {
            traceLog("termination: timed out waiting for in-flight connect (\(timeoutSeconds)s); proceeding with teardown")
        }
    }

    private func coordinatedDisconnect(waitForTunnelStop: Bool) async {
        let task: Task<Void, Never>
        if let existing = disconnectCoordinatorTask {
            task = existing
        } else {
            let newTask = Task { @MainActor in
                await self.performDisconnect(waitForTunnelStop: waitForTunnelStop)
                self.disconnectCoordinatorTask = nil
            }
            disconnectCoordinatorTask = newTask
            task = newTask
        }

        await task.value

        if waitForTunnelStop && !isTunnelFullyStopped() {
            traceLog("coordinatedDisconnect: tunnel still active after coordinator task; extending wait")
            _ = await waitForTunnelDisconnected(timeoutSeconds: 5)
            syncStatus()
        }
    }

    private func performDisconnect(waitForTunnelStop: Bool = false) async {
        // If an app-tunnel VPN configuration remains enabled with appRules installed,
        // macOS may enforce "VPN required" for matched apps even while disconnected
        // (which looks like the app's traffic is blocked).
        // So on manual disconnect, disable the configuration (and on-demand) in preferences.
        if manager.isEnabled || manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            manager.isEnabled = false
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                traceLog("config disabled on disconnect (isEnabled=false, isOnDemandEnabled=false)")
            } catch {
                traceLog("failed disabling config on disconnect: \(error.localizedDescription)")
            }
        }

        await perAppStatsProxy.disable()
        PerAppTransferStore.reset()
        ExtensionResourceStore.reset()
        clearPersistedPerAppRoutedSigningIdentifiers()

        manager.connection.stopVPNTunnel()

        if waitForTunnelStop {
            let stopped = await waitForTunnelDisconnected(timeoutSeconds: 5)
            let finalStatus = manager.connection.status
            if stopped {
                traceLog("tunnel stop confirmed status=\(connectionStatusString(finalStatus))")
            } else {
                traceLog("tunnel stop timeout status=\(connectionStatusString(finalStatus))")
                stats.lastError = stats.lastError ?? "Tunnel may still be stopping."
            }
            syncStatus()
        } else {
            stats.state = .disconnected
        }
        stats.connectedAt = nil
        stats.lastInboundAt = nil
        stats.connectedProfileID = nil
        stats.endpoint = nil
        stats.publicIP = nil
        stats.publicIPLocation = nil
        stats.perAppSplitTunnelActive = false
        stats.perAppStatsCollectionActive = false
        stats.bytesIn = 0
        stats.bytesOut = 0
        stats.rxBytesPerSecond = 0
        stats.txBytesPerSecond = 0
        stats.perAppAggregateRxBytesPerSecond = 0
        stats.perAppAggregateTxBytesPerSecond = 0
        stats.perAppStats = [:]
        stats.perDestinationStats = []
        stats.perAppStatsUpdatedAt = nil
        stopStatsRefresh()
        syncExtensionResourceStats()
        shouldAutoReconnect = false
        isBusy = false
        connectCancelled = false
        traceLog("disconnect completed")
    }

    private func makeRuntimeStateData(profile: WireGuardProfile) throws -> Data {
        let payload = RuntimeState(profile: profile)
        return try JSONEncoder().encode(payload)
    }

    private func persistPerAppStatsRoutingConfig(appRules: [NEAppRule], routeAllIdentifiedFlows: Bool) {
        // Always write the bool so a prior full-traffic session cannot leave `true` stuck when switching to split.
        AppGroupStore.defaults.set(routeAllIdentifiedFlows, forKey: Self.perAppRouteAllFlowsDefaultsKey)

        var ids = Set<String>()
        if !routeAllIdentifiedFlows {
            for rule in appRules {
                let trimmed = rule.matchSigningIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    ids.insert(trimmed)
                }
            }
        }
        let sorted = Array(ids).sorted()
        traceLog(
            "will persist app-tunnel stats routing: routeAll=\(routeAllIdentifiedFlows) signingIDs.count=\(sorted.count)"
        )

        AppGroupStore.defaults.set(sorted, forKey: Self.perAppRoutedSigningIDsDefaultsKey)
        AppGroupStore.defaults.synchronize()

        if let readBack = AppGroupStore.defaults.stringArray(forKey: Self.perAppRoutedSigningIDsDefaultsKey) {
            traceLog(
                "persisted signing identifiers count=\(sorted.count), verified readback count=\(readBack.count) routeAll=\(routeAllIdentifiedFlows)"
            )
        } else {
            traceLog("WARNING: persisted app-tunnel routed signing identifiers but readback returned nil!")
        }

        do {
            guard let fileURL = SharedPaths.perAppRoutedSigningIdentifiersFileURL() else {
                throw NSError(
                    domain: "TunnelBahn.VPN",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to access shared app-tunnel signing IDs file."]
                )
            }
            var payload: [String: Any] = ["signingIdentifiers": sorted]
            if routeAllIdentifiedFlows {
                payload["routeAllIdentifiedFlows"] = true
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            traceLog("persisted app-tunnel stats routing file bytes=\(data.count)")
        } catch {
            traceLog("WARNING: failed to persist app-tunnel stats routing file: \(error.localizedDescription)")
        }
    }

    private func clearPersistedPerAppRoutedSigningIdentifiers() {
        AppGroupStore.defaults.removeObject(forKey: Self.perAppRoutedSigningIDsDefaultsKey)
        AppGroupStore.defaults.removeObject(forKey: Self.perAppRouteAllFlowsDefaultsKey)
        if let fileURL = SharedPaths.perAppRoutedSigningIdentifiersFileURL() {
            try? FileManager.default.removeItem(at: fileURL)
        }
        removeDestinationRoutingFile()
    }

    private func persistDestinationRoutingFromHost(enforceFiltering: Bool, ranges: [String]) {
        guard let fileURL = SharedPaths.destinationRangesFileURL() else {
            traceLog("WARNING: unable to locate destination routing App Group URL")
            return
        }
        let payload = DestinationRoutingFilePayload(enforceDestinationFiltering: enforceFiltering, ranges: ranges)
        do {
            try DestinationRoutingFileStore.write(payload, to: fileURL)
            traceLog("destination routing file written enforce=\(enforceFiltering) rawRangeCount=\(ranges.count)")
        } catch {
            traceLog("WARNING: destination routing write failed: \(error.localizedDescription)")
        }
    }

    private func removeDestinationRoutingFile() {
        guard let fileURL = SharedPaths.destinationRangesFileURL() else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persistRuntimeState(data: Data) throws {
        guard let fileURL = SharedPaths.stateFileURL() else {
            throw NSError(
                domain: "TunnelBahn.VPN",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Unable to access shared state file."]
            )
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func resolvePeerEndpointsForExtension(_ profile: WireGuardProfile) throws -> WireGuardProfile {
        var resolvedProfile = profile
        resolvedProfile.peers = try profile.peers.map { peer in
            guard let endpoint = ParsedEndpoint(peer.endpoint), !endpoint.hostIsIPAddress else {
                return peer
            }

            var resolvedPeer = peer
            let resolvedHost = try resolveEndpointHost(endpoint.host, port: endpoint.port)
            resolvedPeer.endpoint = endpoint.replacingHost(with: resolvedHost)
            traceLog("resolved peer endpoint \(endpoint.host):\(endpoint.port) -> \(resolvedPeer.endpoint)")
            return resolvedPeer
        }
        return resolvedProfile
    }

    private func resolveEndpointHost(_ host: String, port: String) throws -> String {
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, port, &hints, &result)
        guard status == 0, let result else {
            throw NSError(
                domain: "TunnelBahn.VPN",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve WireGuard endpoint \(host): \(String(cString: gai_strerror(status)))."]
            )
        }
        defer { freeaddrinfo(result) }

        var firstIPv6: String?
        var pointer: UnsafeMutablePointer<addrinfo>? = result
        while let current = pointer {
            let info = current.pointee
            if info.ai_family == AF_INET,
               let ipv4 = stringIPv4Address(from: info.ai_addr)
            {
                return ipv4
            }
            if info.ai_family == AF_INET6,
               firstIPv6 == nil,
               let ipv6 = stringIPv6Address(from: info.ai_addr)
            {
                firstIPv6 = ipv6
            }
            pointer = info.ai_next
        }

        if let firstIPv6 { return firstIPv6 }
        throw NSError(
            domain: "TunnelBahn.VPN",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Unable to resolve WireGuard endpoint \(host) to an IPv4 or IPv6 address."]
        )
    }

    private func stringIPv4Address(from sockaddr: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let sockaddr else { return nil }
        let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            pointer.pointee.sin_addr
        }
        var mutableAddress = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &mutableAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    private func stringIPv6Address(from sockaddr: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let sockaddr else { return nil }
        let address = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            pointer.pointee.sin6_addr
        }
        var mutableAddress = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &mutableAddress, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    private func syncStatus() {
        let status = manager.connection.status
        switch manager.connection.status {
        case .connected: stats.state = .connected
        case .connecting: stats.state = .connecting
        case .disconnecting: stats.state = .disconnecting
        case .reasserting: stats.state = .reconnecting
        case .invalid, .disconnected:
            // NE can briefly report disconnected/invalid during connect/switch/teardown.
            // Keep `connectedProfileID` aligned with intentional tunnel work until teardown finishes.
            let preserveProfileIdentity =
                connectRunning
                || stats.state == .connecting
                || stats.state == .disconnecting
                || stats.state == .reconnecting
            stats.state = .disconnected
            stats.publicIP = nil
            stats.publicIPLocation = nil
            if !preserveProfileIdentity {
                stats.connectedProfileID = nil
            }
        @unknown default: stats.state = .error
        }
        if stats.state == .connected, stats.connectedProfileID == nil {
            if let runtimeProfile = loadPersistedRuntimeProfile() {
                stats.connectedProfileID = runtimeProfile.id
                stats.endpoint = runtimeProfile.peers.first?.endpoint
            }
        }
        if stats.state == .connected, stats.publicIP == nil {
            Task { @MainActor in
                await refreshPublicIPAndLocation()
            }
        }
        if stats.state == .connected || stats.state == .reconnecting {
            startStatsRefreshIfNeeded()
        } else {
            stopStatsRefresh()
        }
        if stats.state != .connected, stats.state != .reconnecting {
            stats.bytesIn = 0
            stats.bytesOut = 0
            stats.rxBytesPerSecond = 0
            stats.txBytesPerSecond = 0
            stats.perAppAggregateRxBytesPerSecond = 0
            stats.perAppAggregateTxBytesPerSecond = 0
            stats.perAppStatsCollectionActive = false
        }
        syncResourceStatsFromMonitor()
        syncExtensionResourceStats()
        traceLog("syncStatus manager=\(status.rawValue) appState=\(stats.state.rawValue)")
    }

    private func syncExtensionResourceStats() {
        guard stats.state == .connected || stats.state == .reconnecting else {
            stats.packetTunnelCPUUsage = 0
            stats.packetTunnelMemoryUsage = 0
            stats.transparentProxyCPUUsage = 0
            stats.transparentProxyMemoryUsage = 0
            stats.extensionStatsUpdatedAt = nil
            return
        }
        let snapshot = ExtensionResourceStore.read()
        stats.packetTunnelCPUUsage = snapshot.packetTunnelCPU
        stats.packetTunnelMemoryUsage = snapshot.packetTunnelMemory
        stats.transparentProxyCPUUsage = snapshot.transparentProxyCPU
        stats.transparentProxyMemoryUsage = snapshot.transparentProxyMemory
        stats.extensionStatsUpdatedAt = snapshot.lastUpdate == .distantPast ? nil : snapshot.lastUpdate
    }

    private func syncResourceStatsFromMonitor() {
        guard let resourceMonitor else {
            stats.appCPUUsage = 0
            stats.appMemoryUsage = 0
            return
        }
        stats.appCPUUsage = resourceMonitor.cpuUsage
        stats.appMemoryUsage = resourceMonitor.memoryUsage
    }

    private func loadPersistedRuntimeProfile() -> WireGuardProfile? {
        guard let url = SharedPaths.stateFileURL(),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(RuntimeState.self, from: data)
        else {
            return nil
        }
        return state.profile
    }

    private func startStatsRefreshIfNeeded() {
        guard statsRefreshTask == nil else { return }
        statsRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await self?.refreshWireGuardStats()
            }
        }
    }

    private func stopStatsRefresh() {
        statsRefreshTask?.cancel()
        statsRefreshTask = nil
        lastTransferSnapshot = nil
        lastPerAppAggregateSnapshot = nil
    }

    private func refreshWireGuardStats() async {
        guard stats.state == .connected || stats.state == .reconnecting else { return }
        guard let runtimeConfiguration = await loadRuntimeConfiguration() else { return }
        let totals = Self.parseTransferTotals(from: runtimeConfiguration)
        let now = Date()

        if let lastTransferSnapshot {
            let elapsed = max(now.timeIntervalSince(lastTransferSnapshot.date), 0.001)
            stats.rxBytesPerSecond = Double(totals.rxBytes.saturatingSubtract(lastTransferSnapshot.rxBytes)) / elapsed
            stats.txBytesPerSecond = Double(totals.txBytes.saturatingSubtract(lastTransferSnapshot.txBytes)) / elapsed
        }

        stats.bytesIn = totals.rxBytes
        stats.bytesOut = totals.txBytes
        stats.lastInboundAt = totals.lastInboundAt
        lastTransferSnapshot = TransferSnapshot(date: now, rxBytes: totals.rxBytes, txBytes: totals.txBytes)

        // App-tunnel counters (transparent proxy accounting). Reading is non-blocking and
        // tolerates a missing/corrupt file by returning `.empty`.
        if stats.perAppStatsCollectionActive {
            let snapshot = PerAppTransferStore.read()
            stats.perAppStats = snapshot.apps
            stats.perDestinationStats = snapshot.perDestination
            stats.perAppStatsUpdatedAt = snapshot.lastUpdate

            let aggregateRx = snapshot.apps.values.reduce(UInt64(0)) { partial, entry in partial &+ entry.rxBytes }
            let aggregateTx = snapshot.apps.values.reduce(UInt64(0)) { partial, entry in partial &+ entry.txBytes }

            if let lastPerAppAggregateSnapshot {
                let elapsed = max(now.timeIntervalSince(lastPerAppAggregateSnapshot.date), 0.001)
                stats.perAppAggregateRxBytesPerSecond =
                    Double(aggregateRx.saturatingSubtract(lastPerAppAggregateSnapshot.rxBytes)) / elapsed
                stats.perAppAggregateTxBytesPerSecond =
                    Double(aggregateTx.saturatingSubtract(lastPerAppAggregateSnapshot.txBytes)) / elapsed
            }
            lastPerAppAggregateSnapshot = TransferSnapshot(date: now, rxBytes: aggregateRx, txBytes: aggregateTx)
        } else {
            stats.perAppAggregateRxBytesPerSecond = 0
            stats.perAppAggregateTxBytesPerSecond = 0
            lastPerAppAggregateSnapshot = nil
            if !stats.perAppStats.isEmpty {
                stats.perAppStats = [:]
            }
            if !stats.perDestinationStats.isEmpty {
                stats.perDestinationStats = []
            }
        }
        syncResourceStatsFromMonitor()
        syncExtensionResourceStats()
    }

    private func loadRuntimeConfiguration() async -> String? {
        guard let session = manager.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            let race = ProviderMessageContinuationRace<String?>()
            Task {
                try? await Task.sleep(for: .seconds(8))
                race.resume(continuation, returning: nil)
            }
            do {
                try session.sendProviderMessage(Data("runtimeConfiguration".utf8)) { data in
                    race.resume(continuation, returning: data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                race.resume(continuation, returning: nil)
            }
        }
    }

    private static func parseTransferTotals(from runtimeConfiguration: String) -> (rxBytes: UInt64, txBytes: UInt64, lastInboundAt: Date?) {
        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0
        var lastHandshakeUnix: UInt64 = 0
        for line in runtimeConfiguration.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "rx_bytes":
                rxBytes += UInt64(parts[1]) ?? 0
            case "tx_bytes":
                txBytes += UInt64(parts[1]) ?? 0
            case "last_inbound_unix":
                lastHandshakeUnix = UInt64(parts[1]) ?? 0
            default:
                continue
            }
        }
        let lastInboundAt: Date? = lastHandshakeUnix > 0 ? Date(timeIntervalSince1970: Double(lastHandshakeUnix) / 1000) : nil
        return (rxBytes, txBytes, lastInboundAt)
    }

    private func refreshPublicIPAndLocation() async {
        guard stats.state == .connected else { return }
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, _) = try await publicIPSession.data(for: request)
            let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty else { return }
            stats.publicIP = ip
            stats.publicIPLocation = await fetchLocation(for: ip)
            traceLog("public IP refreshed \(ip)")
        } catch {
            traceLog("public IP refresh failed: \(error.localizedDescription)")
        }
    }

    private func fetchLocation(for ip: String) async -> String? {
        guard let url = URL(string: "https://ipwho.is/\(ip)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, _) = try await publicIPSession.data(for: request)
            let payload = try JSONDecoder().decode(IPWhoIsResponse.self, from: data)
            guard payload.success else { return nil }
            let parts: [String] = [payload.city, payload.region, payload.country]
                .compactMap { value in
                    guard let value else { return nil }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: ", ")
        } catch {
            traceLog("public IP location lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func traceLog(_ message: String) {
        #if DEBUG
        print("[DEBUG][VPN] \(message)")
        #endif
        Self.osLog.debug("\(message, privacy: .public)")
    }

    private func connectSummaryLog(_ message: String) {
        #if DEBUG
        print("[DEBUG][VPN] \(message)")
        #endif
        Self.osLog.info("\(message, privacy: .public)")
    }

    private func logConnectModeDecision(
        originalProfile: WireGuardProfile,
        extensionProfile: WireGuardProfile,
        selectedRules: [AppRule],
        requestedAppRules: [NEAppRule],
        useAppTunnelNEStack: Bool,
        hasAppTunnelSelection: Bool,
        routeAllFlowsForStats: Bool
    ) {
        traceLog("=== CONNECT MODE DECISION ===")
        traceLog(
            "selectedRules=\(selectedRules.count) requestedAppRules=\(requestedAppRules.count) " +
            "hasAppTunnelSelection=\(hasAppTunnelSelection) routeAllFlowsForStats=\(routeAllFlowsForStats)"
        )
        let label: String
        if !useAppTunnelNEStack {
            label = "full-tunnel-destination-ip (no accounting stack)"
        } else if hasAppTunnelSelection {
            label = "app-tunnel-split-with-accounting"
        } else {
            label = "full-traffic-with-accounting"
        }
        traceLog("mode=\(label)")
        if selectedRules.isEmpty {
            traceLog("selectedRules detail: none")
        } else {
            for rule in selectedRules {
                traceLog("selectedRule displayName=\(rule.displayName) action=\(rule.action.rawValue) appPath=\(rule.appPath)")
            }
        }
        if requestedAppRules.isEmpty {
            traceLog("effective NEAppRule signing identifiers: none")
        } else {
            for appRule in requestedAppRules {
                traceLog("effective NEAppRule signingIdentifier=\(appRule.matchSigningIdentifier)")
            }
        }
        traceLog("original profile summary: \(profileSummary(originalProfile))")
        traceLog("extension profile summary: \(profileSummary(extensionProfile))")
        traceLog("=== END CONNECT MODE DECISION ===")
    }

    private func logEffectiveExtensionProfile(_ profile: WireGuardProfile) {
        traceLog("=== EFFECTIVE PROFILE FOR EXTENSION ===")
        traceLog(profileSummary(profile))
        for (index, peer) in profile.peers.enumerated() {
            traceLog(
                "peer[\(index)] endpoint=\(peer.endpoint) allowedIPs=\(peer.allowedIPs.joined(separator: ", ")) " +
                "keepalive=\(peer.persistentKeepalive.map(String.init) ?? "nil")"
            )
        }
        traceLog("=== END EFFECTIVE PROFILE FOR EXTENSION ===")
    }

    /// Single-line summary for log triage. Run: `/usr/bin/log stream ... | grep APPSPLIT_CONNECT_SUMMARY`
    private func emitConnectSummaryLine(
        outcome: String,
        profileName: String,
        reason: String?,
        wantedAppTunnel: Bool?,
        neAppRuleCount: Int?,
        routingMethod: Int?,
        onDemand: Bool?,
        managerAppRuleCount: Int?,
        detail: String? = nil
    ) {
        let safeProfile = profileName
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        var parts: [String] = [
            "[APPSPLIT_CONNECT_SUMMARY]",
            "outcome=\(outcome)",
            "profile=\(safeProfile)",
        ]
        if let reason {
            parts.append("reason=\(reason)")
        }
        if let wantedAppTunnel {
            parts.append("wantedAppTunnel=\(wantedAppTunnel)")
        }
        if let neAppRuleCount {
            parts.append("builtNEAppRules=\(neAppRuleCount)")
        }
        if let routingMethod {
            parts.append("routingMethod=\(routingMethod)")
        }
        if let onDemand {
            parts.append("onDemand=\(onDemand)")
        }
        if let managerAppRuleCount {
            parts.append("managerAppRules=\(managerAppRuleCount)")
        }
        if let detail {
            let flattened = detail
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(240)
            parts.append("detail=\(flattened)")
        }
        connectSummaryLog(parts.joined(separator: " "))
    }

    private func profileSummary(_ profile: WireGuardProfile) -> String {
        let addresses = profile.interface.addresses.joined(separator: ", ")
        let dnsServers = profile.interface.dnsServers.joined(separator: ", ")
        let mtu = profile.interface.mtu.map(String.init) ?? "nil"
        return "profile=\(profile.name) addresses=[\(addresses)] dns=[\(dnsServers)] mtu=\(mtu) peers=\(profile.peers.count)"
    }

    private func userFacingConnectErrorMessage(_ error: Error) -> String {
        let description = error.localizedDescription
        let lowered = description.lowercased()
        if lowered.contains("permission denied") {
            return "VPN start failed: permission denied. Build and run a signed app/extension from Xcode with Network Extension capability enabled."
        }
        if lowered.contains("app rule") {
            return "App-tunnel policy could not be configured. Verify app bundle identifiers and Network Extension entitlements, then retry Connect."
        }
        return description
    }
}

/// Ensures only one completion fires when racing `sendProviderMessage` against a timeout `Task`.
private final class ProviderMessageContinuationRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func resume(_ continuation: CheckedContinuation<T, Never>, returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: value)
    }
}

private struct RuntimeState: Codable {
    let profile: WireGuardProfile
}

private struct ParsedEndpoint {
    let host: String
    let port: String
    let isBracketedIPv6: Bool

    init?(_ raw: String) {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0 == "#" })
            .first
            .map(String.init) ?? raw

        if token.hasPrefix("["),
           let closeBracket = token.firstIndex(of: "]")
        {
            let afterBracket = token[token.index(after: closeBracket)...]
            guard afterBracket.hasPrefix(":") else { return nil }
            host = String(token[token.index(after: token.startIndex)..<closeBracket])
            port = String(afterBracket.dropFirst())
            isBracketedIPv6 = true
            guard !host.isEmpty, !port.isEmpty else { return nil }
            return
        }

        guard let separator = token.lastIndex(of: ":") else { return nil }
        host = String(token[..<separator])
        port = String(token[token.index(after: separator)...])
        isBracketedIPv6 = false
        guard !host.isEmpty, !port.isEmpty else { return nil }
    }

    var hostIsIPAddress: Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1
    }

    func replacingHost(with resolvedHost: String) -> String {
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, resolvedHost, &ipv6) == 1 {
            return "[\(resolvedHost)]:\(port)"
        }
        return "\(resolvedHost):\(port)"
    }
}

private struct TransferSnapshot {
    let date: Date
    let rxBytes: UInt64
    let txBytes: UInt64
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

private struct IPWhoIsResponse: Codable {
    let success: Bool
    let city: String?
    let region: String?
    let country: String?
}

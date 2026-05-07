import Foundation
import Darwin
import NetworkExtension
import OSLog

@MainActor
final class VPNManager: ObservableObject {
    private static let osLog = Logger(subsystem: "com.appsplit.wg", category: "VPN")

    @Published private(set) var stats: ConnectionStats = .empty
    @Published private(set) var isBusy = false
    @Published private(set) var shouldAutoReconnect = false

    private var manager = NETunnelProviderManager()
    private let settings: AppSettings
    private let publicIPSession = URLSession(configuration: .ephemeral)
    private var statsRefreshTask: Task<Void, Never>?
    private var lastTransferSnapshot: TransferSnapshot?
    private var lastPerAppAggregateSnapshot: TransferSnapshot?
    private let perAppStatsProxy = PerAppStatsProxyManager()
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

    init(settings: AppSettings) {
        self.settings = settings
        traceLog("init")
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

    func connect(profile: WireGuardProfile, rules: [AppRule]) async {
        if isBusy {
            emitConnectSummaryLine(
                outcome: "ignored",
                profileName: profile.name,
                reason: "busy",
                wantedPerApp: nil,
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
                    
                    // Stop the transparent proxy so it doesn't keep stale state/connections from old profile.
                    // When we reconnect, it will be restarted fresh.
                    await perAppStatsProxy.disable()
                    traceLog("profile switch: transparent proxy disabled")
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
                    wantedPerApp: nil,
                    neAppRuleCount: nil,
                    routingMethod: nil,
                    onDemand: nil,
                    managerAppRuleCount: nil
                )
                return
            }

            let perAppModeSelected = (settings.routingMode == .perApp)
            var requestedAppRules = perAppModeSelected ? NEAppRuleBuilder.build(from: rules, log: traceLog) : []
            if !perAppModeSelected, !rules.isEmpty {
                traceLog("routing mode is full-tunnel; ignoring \(rules.count) app rules")
            }

            if AppConstants.isPerAppSplitTunnelEnabled, perAppModeSelected {
                let fromHardcodedPaths = NEAppRuleBuilder.buildFromAlwaysIncludedPaths(
                    AppConstants.perAppAlwaysIncludeAppPaths,
                    log: traceLog
                )
                if !fromHardcodedPaths.isEmpty {
                    traceLog("perAppAlwaysIncludeAppPaths: added \(fromHardcodedPaths.count) NEAppRule(s) before merge")
                }
                requestedAppRules = NEAppRuleBuilder.dedupe(requestedAppRules + fromHardcodedPaths, log: traceLog)
            } else if !requestedAppRules.isEmpty {
                traceLog("Per-app split is disabled; ignoring \(requestedAppRules.count) built NEAppRule(s), using full tunnel")
                requestedAppRules = []
            }

            let hasPerAppSelection =
                AppConstants.isPerAppSplitTunnelEnabled && perAppModeSelected && !requestedAppRules.isEmpty
            let isFullTrafficAccountingShape =
                AppConstants.isPerAppSplitTunnelEnabled
                && (settings.routingMode == .fullTunnel || (perAppModeSelected && requestedAppRules.isEmpty))

            let profileOkForAccounting = profileHasDefaultRoute(profile: extensionProfile)

            /// When true: `forPerAppVPN` + transparent proxy + tunnel rules that only include the proxy
            /// (and optional host probe). Used for per-app split **or** full-tunnel per-app byte accounting.
            let usePerAppVPN = profileOkForAccounting && (hasPerAppSelection || isFullTrafficAccountingShape)

            #if DEBUG
            logConnectModeDecision(
                originalProfile: profile,
                extensionProfile: extensionProfile,
                selectedRules: rules,
                requestedAppRules: requestedAppRules,
                usePerAppVPN: usePerAppVPN,
                hasPerAppSelection: hasPerAppSelection,
                routeAllFlowsForStats: usePerAppVPN && !hasPerAppSelection
            )
            #endif

            // Per-app allow-list: selected apps are forced into the tunnel; peers need default-route AllowedIPs.
            if hasPerAppSelection, !profileOkForAccounting {
                stats.state = .error
                stats.lastError = "A routed app needs default-route AllowedIPs on the peer (e.g. 0.0.0.0/0 and ::/0). Update the profile and reconnect."
                stats.connectedProfileID = nil
                stats.endpoint = nil
                traceLog("connect aborted: per-app routed app but profile AllowedIPs is not default-route")
                emitConnectSummaryLine(
                    outcome: "aborted",
                    profileName: profile.name,
                    reason: "per_app_needs_default_route_allowedips",
                    wantedPerApp: true,
                    neAppRuleCount: requestedAppRules.count,
                    routingMethod: nil,
                    onDemand: nil,
                    managerAppRuleCount: nil
                )
                return
            }

            if usePerAppVPN {
                if hasPerAppSelection {
                    persistPerAppStatsRoutingConfig(appRules: requestedAppRules, routeAllIdentifiedFlows: false)
                    traceLog("per-app split: persisted \(requestedAppRules.count) NEAppRule signing identifier(s) for transparent proxy filter")
                } else {
                    persistPerAppStatsRoutingConfig(appRules: [], routeAllIdentifiedFlows: true)
                    traceLog("full-traffic accounting: persisted routeAllIdentifiedFlows for transparent proxy")
                }
                traceLog(
                    "VPN accounting stack: tunnel DNS servers=[\(extensionProfile.interface.dnsServers.joined(separator: ", "))]"
                )
            } else {
                clearPersistedPerAppRoutedSigningIdentifiers()
                traceLog("full-tunnel mode: destination-IP routing only (no per-app accounting stack; missing default-route peer or split disabled)")
            }

            var rulesForVPNManager = requestedAppRules
            if usePerAppVPN, settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                rulesForVPNManager = NEAppRuleBuilder.dedupe(rulesForVPNManager + [hostRule], log: traceLog)
                traceLog(
                    "tunnel probe: merged host app NEAppRule signingID=\(hostRule.matchSigningIdentifier) totalRules=\(rulesForVPNManager.count)"
                )
            }
            
            // For per-app traffic counting via transparent proxy: only include the transparent proxy's
            // own signing ID in the tunnel's NEAppRules. The transparent proxy will intercept ALL flows
            // and decide which to relay (and count). If we put the user's app signing IDs in the tunnel's
            // NEAppRules, macOS routes those flows directly through the tunnel without presenting them
            // to the transparent proxy, making per-app counting impossible.
            var finalAppRules: [NEAppRule] = []
            if usePerAppVPN {
                let proxyRule = PerAppStatsProxyManager.extensionAppRule()
                finalAppRules = [proxyRule]
                if settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                    finalAppRules.append(hostRule)
                }
                traceLog(
                    "per-app stats: tunnel NEAppRules only include proxy+host (count=\(finalAppRules.count)), transparent proxy will handle user app routing"
                )
            }

            let runtimeStateData = try makeRuntimeStateData(profile: extensionProfile)
            try persistRuntimeState(data: runtimeStateData)
            traceLog("runtime state persisted for profile=\(profile.name)")
            let appRules = usePerAppVPN ? finalAppRules : []
            try await configureManager(
                appRules: appRules,
                runtimeStateData: runtimeStateData,
                usePerAppVPN: usePerAppVPN
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
                    wantedPerApp: hasPerAppSelection,
                    neAppRuleCount: rulesForVPNManager.count,
                    routingMethod: manager.routingMethod.rawValue,
                    onDemand: manager.isOnDemandEnabled,
                    managerAppRuleCount: manager.appRules.count
                )
                return
            case .stillStarting:
                traceLog("connect: NEVPN still starting after initial wait; deferring completion")
                stats.state = .connecting
                stats.connectedProfileID = profile.id
                stats.lastError = nil
                scheduleDeferredConnectCompletion(
                    profile: profile,
                    extensionProfile: extensionProfile,
                    hasPerAppSelection: hasPerAppSelection,
                    usePerAppVPN: usePerAppVPN,
                    rulesForVPNManagerCount: rulesForVPNManager.count
                )
                return
            case .connected:
                await applySuccessfulConnectPostTunnel(
                    profile: profile,
                    extensionProfile: extensionProfile,
                    hasPerAppSelection: hasPerAppSelection,
                    usePerAppVPN: usePerAppVPN,
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
                wantedPerApp: nil,
                neAppRuleCount: nil,
                routingMethod: nil,
                onDemand: nil,
                managerAppRuleCount: nil,
                detail: message
            )
        }
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
        hasPerAppSelection: Bool,
        usePerAppVPN: Bool,
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
                hasPerAppSelection: hasPerAppSelection,
                usePerAppVPN: usePerAppVPN,
                rulesForVPNManagerCount: rulesForVPNManagerCount
            )
        }
    }

    private func finishConnectAfterDeferredTunnelWait(
        expectedProfileID: UUID,
        profile: WireGuardProfile,
        extensionProfile: WireGuardProfile,
        hasPerAppSelection: Bool,
        usePerAppVPN: Bool,
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
                    hasPerAppSelection: hasPerAppSelection,
                    usePerAppVPN: usePerAppVPN,
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
                    wantedPerApp: hasPerAppSelection,
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
                hasPerAppSelection: hasPerAppSelection,
                usePerAppVPN: usePerAppVPN,
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
            wantedPerApp: hasPerAppSelection,
            neAppRuleCount: rulesForVPNManagerCount,
            routingMethod: manager.routingMethod.rawValue,
            onDemand: manager.isOnDemandEnabled,
            managerAppRuleCount: manager.appRules.count
        )
    }

    private func applySuccessfulConnectPostTunnel(
        profile: WireGuardProfile,
        extensionProfile: WireGuardProfile,
        hasPerAppSelection: Bool,
        usePerAppVPN: Bool,
        rulesForVPNManagerCount: Int
    ) async {
        stats.state = .connected
        stats.connectedAt = .now
        stats.connectedProfileID = profile.id
        stats.endpoint = extensionProfile.peers.first?.endpoint
        stats.perAppSplitTunnelActive = hasPerAppSelection && usePerAppVPN
        stats.perAppStatsCollectionActive = usePerAppVPN

        if usePerAppVPN {
            PerAppTransferStore.reset()
            do {
                try await perAppStatsProxy.enable()
            } catch {
                traceLog("per-app stats proxy enable failed: \(error.localizedDescription)")
                stats.lastError = "Per-app accounting could not start: \(error.localizedDescription)"
                await coordinatedDisconnect(waitForTunnelStop: false)
                emitConnectSummaryLine(
                    outcome: "error",
                    profileName: profile.name,
                    reason: "per_app_proxy_failed",
                    wantedPerApp: hasPerAppSelection,
                    neAppRuleCount: rulesForVPNManagerCount,
                    routingMethod: manager.routingMethod.rawValue,
                    onDemand: manager.isOnDemandEnabled,
                    managerAppRuleCount: manager.appRules.count,
                    detail: error.localizedDescription
                )
                return
            }
        }

        if settings.runTunnelConnectivityProbe {
            traceLog("[APPSPLIT_PROBE] nevpn_wait outcome=connected status=\(manager.connection.status.rawValue)")
            await refreshPublicIPAndLocation()
            let probePhase: TunnelProbePhase = {
                guard usePerAppVPN else { return .fullTunnel }
                guard hasPerAppSelection else { return .fullTunnel }
                if settings.includeHostAppInPerAppRulesForProbe { return .perAppHostIncluded }
                return .perAppHostExcluded
            }()
            await TunnelConnectivityProbe.run(phase: probePhase, comparePublicIP: stats.publicIP)
        } else {
            await refreshPublicIPAndLocation()
        }

        startStatsRefreshIfNeeded()
        shouldAutoReconnect = true
        traceLog("connect succeeded endpoint=\(stats.endpoint ?? "unknown")")
        emitConnectSummaryLine(
            outcome: "ok",
            profileName: profile.name,
            reason: nil,
            wantedPerApp: hasPerAppSelection,
            neAppRuleCount: rulesForVPNManagerCount,
            routingMethod: manager.routingMethod.rawValue,
            onDemand: manager.isOnDemandEnabled,
            managerAppRuleCount: manager.appRules.count
        )
    }

    /// Used when `includeHostAppInPerAppRulesForProbe` is on so AppSplitWG-initiated probes match per-app VPN routing.
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
            traceLog("disconnect: in-flight connect will observe cancellation and tear down")
            return
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

    func loadDiagnostics() async -> String {
        guard let session = manager.connection as? NETunnelProviderSession else {
            return "Network Extension diagnostics unavailable: tunnel session not ready."
        }
        return await withCheckedContinuation { continuation in
            let race = ProviderMessageContinuationRace<String>()
            Task {
                try? await Task.sleep(for: .seconds(12))
                race.resume(
                    continuation,
                    returning: "Network Extension diagnostics timed out (extension did not respond)."
                )
            }
            do {
                try session.sendProviderMessage(Data("diagnostics".utf8)) { data in
                    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No diagnostics payload."
                    race.resume(continuation, returning: text)
                }
            } catch {
                race.resume(
                    continuation,
                    returning: "Network Extension diagnostics failed: \(error.localizedDescription)"
                )
            }
        }
    }
    
    func getManagerDiagnostics() -> String {
        var output = "=== VPN MANAGER DIAGNOSTICS ===\n\n"

        output += "Routing Configuration:\n"
        let routingLabel = Self.routingMethodLabel(manager.routingMethod)
        output += "  Routing Method: \(routingLabel)\n"
        output += "  Is Enabled: \(manager.isEnabled)\n"
        output += "  On-Demand Enabled: \(manager.isOnDemandEnabled)\n"
        output += "  Connection Status: \(connectionStatusString(manager.connection.status))\n\n"
        
        output += "App Rules Configuration:\n"
        let appRules = manager.appRules
        if !appRules.isEmpty {
            output += "  Total Rules: \(appRules.count)\n"
            for (index, rule) in appRules.enumerated() {
                output += "  [\(index)] \(rule.matchSigningIdentifier)\n"
            }
        } else {
            switch manager.routingMethod {
            case .destinationIP:
                output += "  No app rules configured (full tunnel will route ALL traffic)\n"
            case .sourceApplication:
                output += "  No app rules configured (per-app VPN will route NO apps)\n"
            @unknown default:
                output += "  No app rules configured (routing method unknown)\n"
            }
        }
        output += "\n"
        
        output += "Manager Details:\n"
        output += "  Description: \(manager.localizedDescription ?? "nil")\n"
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            output += "  Server Address: \(proto.serverAddress ?? "nil")\n"
            output += "  Provider Bundle ID: \(proto.providerBundleIdentifier ?? "nil")\n"
        }
        
        output += "\n=== EXPECTED CONFIGURATION ===\n"
        output += "Full tunnel (like official WireGuard): destinationIP, no app rules, profile unchanged.\n"
        output += "Per-app split: sourceApplication, On-Demand on, at least one app rule.\n"
        output += "\nNote: This app disables the VPN configuration on Disconnect so per-app \"VPN required\" does not block apps.\n"
        
        return output
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

    private static func routingMethodLabel(_ method: NETunnelProviderRoutingMethod) -> String {
        switch method {
        case .destinationIP:
            return "destinationIP (full tunnel)"
        case .sourceApplication:
            return "sourceApplication (per-app VPN)"
        @unknown default:
            return "unknown (rawValue \(method.rawValue))"
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
    
    private func configureManager(appRules: [NEAppRule], runtimeStateData: Data, usePerAppVPN: Bool) async throws {
        traceLog("configureManager started usePerAppVPN=\(usePerAppVPN) appRules=\(appRules.count)")
        try await loadOrCreateTunnelManager(usePerAppVPN: usePerAppVPN)

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.packetTunnelProviderBundleIdentifier
        proto.serverAddress = "AppSplit WG"
        let runtimeStateB64 = runtimeStateData.base64EncodedString()
        proto.providerConfiguration = [
            "profile": "active",
            "runtimeStateB64": runtimeStateB64,
        ]
        manager.localizedDescription = AppConstants.vpnManagerDescription
        manager.protocolConfiguration = proto

        manager.appRules = appRules

        // Per-app VPN: On-Demand must include at least one connect rule so matched apps trigger the tunnel.
        // Without onDemandRules, macOS may not route app traffic through the packet tunnel even when connected.
        if usePerAppVPN {
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

    /// First launch / Settings load: attach to saved manager or create **standard** full-tunnel manager (not per-app).
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
        traceLog("no matching AppSplit manager found; creating new standard NETunnelProviderManager")
        manager = NETunnelProviderManager()
    }

    /// Ensures the stored manager type matches the next connection: **standard** for full tunnel, **forPerAppVPN** for split.
    private func loadOrCreateTunnelManager(usePerAppVPN: Bool) async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let matching = managers.filter { $0.localizedDescription == AppConstants.vpnManagerDescription }

        let wantsPerApp = usePerAppVPN

        if let existing = matching.first {
            let hasPerAppRouting = existing.routingMethod == .sourceApplication
            if wantsPerApp != hasPerAppRouting {
                traceLog("replacing tunnel manager: want perApp=\(wantsPerApp) current routingMethod=\(existing.routingMethod.rawValue)")
                existing.connection.stopVPNTunnel()
                try? await Task.sleep(for: .seconds(1))
                try await existing.removeFromPreferences()
                for dup in matching.dropFirst() {
                    try? await dup.removeFromPreferences()
                }
                manager = wantsPerApp ? NETunnelProviderManager.forPerAppVPN() : NETunnelProviderManager()
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

        manager = wantsPerApp ? NETunnelProviderManager.forPerAppVPN() : NETunnelProviderManager()
        traceLog("no saved AppSplit manager; created routingMethod=\(manager.routingMethod.rawValue)")
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
        // If a per-app VPN configuration remains enabled with appRules installed,
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
        stats.perAppStatsUpdatedAt = nil
        stopStatsRefresh()
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
            "will persist per-app stats routing: routeAll=\(routeAllIdentifiedFlows) signingIDs.count=\(sorted.count)"
        )

        AppGroupStore.defaults.set(sorted, forKey: Self.perAppRoutedSigningIDsDefaultsKey)
        AppGroupStore.defaults.synchronize()

        if let readBack = AppGroupStore.defaults.stringArray(forKey: Self.perAppRoutedSigningIDsDefaultsKey) {
            traceLog(
                "persisted signing identifiers count=\(sorted.count), verified readback count=\(readBack.count) routeAll=\(routeAllIdentifiedFlows)"
            )
        } else {
            traceLog("WARNING: persisted per-app routed signing identifiers but readback returned nil!")
        }

        do {
            guard let fileURL = SharedPaths.perAppRoutedSigningIdentifiersFileURL() else {
                throw NSError(
                    domain: "AppSplitWG.VPN",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to access shared per-app signing IDs file."]
                )
            }
            var payload: [String: Any] = ["signingIdentifiers": sorted]
            if routeAllIdentifiedFlows {
                payload["routeAllIdentifiedFlows"] = true
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            traceLog("persisted per-app stats routing file bytes=\(data.count)")
        } catch {
            traceLog("WARNING: failed to persist per-app stats routing file: \(error.localizedDescription)")
        }
    }

    private func clearPersistedPerAppRoutedSigningIdentifiers() {
        AppGroupStore.defaults.removeObject(forKey: Self.perAppRoutedSigningIDsDefaultsKey)
        AppGroupStore.defaults.removeObject(forKey: Self.perAppRouteAllFlowsDefaultsKey)
        if let fileURL = SharedPaths.perAppRoutedSigningIdentifiersFileURL() {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func persistRuntimeState(data: Data) throws {
        guard let fileURL = SharedPaths.stateFileURL() else {
            throw NSError(
                domain: "AppSplitWG.VPN",
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
                domain: "AppSplitWG.VPN",
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
            domain: "AppSplitWG.VPN",
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
        traceLog("syncStatus manager=\(status.rawValue) appState=\(stats.state.rawValue)")
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
        lastTransferSnapshot = TransferSnapshot(date: now, rxBytes: totals.rxBytes, txBytes: totals.txBytes)

        // Per-app counters (transparent proxy accounting). Reading is non-blocking and
        // tolerates a missing/corrupt file by returning `.empty`.
        if stats.perAppStatsCollectionActive {
            let snapshot = PerAppTransferStore.read()
            stats.perAppStats = snapshot.apps
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
        }
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

    private static func parseTransferTotals(from runtimeConfiguration: String) -> (rxBytes: UInt64, txBytes: UInt64) {
        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0
        for line in runtimeConfiguration.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "rx_bytes":
                rxBytes += UInt64(parts[1]) ?? 0
            case "tx_bytes":
                txBytes += UInt64(parts[1]) ?? 0
            default:
                continue
            }
        }
        return (rxBytes, txBytes)
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
        usePerAppVPN: Bool,
        hasPerAppSelection: Bool,
        routeAllFlowsForStats: Bool
    ) {
        traceLog("=== CONNECT MODE DECISION ===")
        traceLog(
            "selectedRules=\(selectedRules.count) requestedAppRules=\(requestedAppRules.count) " +
            "hasPerAppSelection=\(hasPerAppSelection) routeAllFlowsForStats=\(routeAllFlowsForStats)"
        )
        let label: String
        if !usePerAppVPN {
            label = "full-tunnel-destination-ip (no accounting stack)"
        } else if hasPerAppSelection {
            label = "per-app-split-with-accounting"
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
        wantedPerApp: Bool?,
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
        if let wantedPerApp {
            parts.append("wantedPerApp=\(wantedPerApp)")
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
            return "Per-app policy could not be configured. Verify app bundle identifiers and Network Extension entitlements, then retry Connect."
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

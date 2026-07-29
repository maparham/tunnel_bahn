import Foundation
import Combine
import Darwin
import NetworkExtension
import OSLog

@MainActor
final class VPNManager: ObservableObject {
    private static let osLog = AppLog(subsystem: "com.tunnelbahn.mac", category: "VPN")

    /// Per-process env: `TUNNELBAHN_VPN_TRACE_VERBOSE=1` enables per-rule NEAppRule dumps and full manager config logging.
    #if DEBUG
    private static var vpnTraceVerbose: Bool {
        ProcessInfo.processInfo.environment["TUNNELBAHN_VPN_TRACE_VERBOSE"] == "1"
    }
    #else
    private static var vpnTraceVerbose: Bool { false }
    #endif

    @Published private(set) var stats: ConnectionStats = .empty
    @Published private(set) var isBusy = false
    @Published private(set) var shouldAutoReconnect = false

    /// Ref-count so nested teardown inside a user connect sequence does not clear UI busy early.
    private var operationBusyDepth = 0

    private var manager = NETunnelProviderManager()
    private let settings: AppSettings
    private let profileStore: ProfileStore
    private weak var resourceMonitor: ResourceMonitor?
    private var resourceMonitorCancellables = Set<AnyCancellable>()
    private let publicIPSession = URLSession(configuration: .ephemeral)
    private var statsRefreshTask: Task<Void, Never>?
    private var periodicProbeTask: Task<Void, Never>?
    private var publicIPRefreshTask: Task<Void, Never>?
    private var lastTransferSnapshot: TransferSnapshot?
    private var lastPerAppAggregateSnapshot: TransferSnapshot?
    private let perAppStatsProxy = PerAppStatsProxyManager()
    /// Built during connect and consumed when enabling the transparent proxy after the tunnel is up.
    private var pendingTransparentProxyConfig: TransparentProxyRuntimeConfig?
    private let scopedBookmarks = ScopedBookmarkStore()
    private static let perAppRoutedSigningIDsDefaultsKey = "perAppRoutedSigningIdentifiers"
    private static let perAppRouteAllFlowsDefaultsKey = "perAppRouteAllIdentifiedFlows"

    /// Set by `disconnect()` to make in-flight `connect` exit waits and tear down.
    private var connectCancelled = false
    /// True while `connect` is in-flight (used so termination does not race connect/teardown).
    private var connectRunning = false
    /// True while `performDisconnect` is in-flight. Prevents transient NE states (.connected,
    /// .disconnecting) from regressing stats.state back toward connected while teardown runs.
    private var disconnectRunning = false
    /// Single shared disconnect work item so manual disconnect and termination cannot run `performDisconnect` concurrently.
    private var disconnectCoordinatorTask: Task<Void, Never>?
    private var lastNEStatusNotificationRaw: Int?
    private var lastLoggedSyncStatusKey: String?
    private var lastLoggedDisconnectSuppressRaw: Int?

    init(settings: AppSettings, resourceMonitor: ResourceMonitor?, profileStore: ProfileStore) {
        self.settings = settings
        self.profileStore = profileStore
        self.resourceMonitor = resourceMonitor
        traceLog("init")
        if !AppGroupStore.isAvailable {
            traceLog(
                "WARNING: App Group container unavailable for \(AppConstants.appGroupID) — " +
                "shared state will not sync with extensions; check signing and app-group entitlements"
            )
        }
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
                guard let self else { return }
                let raw = self.manager.connection.status.rawValue
                if self.lastNEStatusNotificationRaw != raw {
                    self.lastNEStatusNotificationRaw = raw
                    self.traceLog("NEVPNStatusDidChange manager=\(raw)")
                }
                self.syncStatus()
            }
        }
    }

    private func enterOperationBusy() {
        operationBusyDepth += 1
        if operationBusyDepth == 1 {
            isBusy = true
        }
    }

    private func leaveOperationBusy() {
        operationBusyDepth = max(0, operationBusyDepth - 1)
        isBusy = operationBusyDepth > 0
    }

    /// Keeps `isBusy` true for the full disconnect → resolve → connect pipeline (linear UI: idle → busy → connected).
    func runUserConnectSequence(_ work: () async -> Void) async {
        enterOperationBusy()
        defer { leaveOperationBusy() }
        await work()
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

    func connect(profile: WireGuardProfile, rules: [AppRule], destinationCidrStrings: [String], destinationDomainNames: [String] = []) async {
        if connectRunning || disconnectRunning {
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
            traceLog("connect ignored because connect or disconnect is in flight")
            return
        }
        guard profileStore.hasValidPrivateKey(for: profile) else {
            stats.state = .error
            stats.lastError = "The private key for \"\(profile.name)\" is missing from the keychain. Delete the profile and re-import it from its original .conf file."
            return
        }
        traceLog("connect requested profile=\(profile.name) rules=\(rules.count)")
        emitScenarioSummary(profile: profile, rules: rules, destinationCidrStrings: destinationCidrStrings)
        connectCancelled = false
        connectRunning = true
        defer { connectRunning = false }
        stats.state = .connecting
        stats.lastError = nil
        stats.connectivityProbeResult = .unknown
        stopPeriodicProbe()
        // Snapshot who was connected (or last runtime on disk) *before* we assign the new
        // profile ID — otherwise switch detection always sees `profile.id` and skips the stop.
        let priorConnectedProfileID = stats.connectedProfileID ?? loadPersistedRuntimeProfile()?.id
        stats.connectedProfileID = profile.id
        /// True once `configureManager` has saved preferences with `isEnabled`/`isOnDemandEnabled`
        /// for THIS attempt. Gates the catch-path cleanup so a failure before configuration
        /// (e.g. endpoint resolution) cannot disable a manager belonging to a healthy session.
        var managerSavedEnabledThisAttempt = false

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

            // The single-peer requirement is WireGuard-specific. SSH profiles carry no WG
            // peers (the SSH connection params travel via profile.ssh → TunnelSSHParams), so
            // this guard only applies when the transport is WireGuard.
            if profile.transport == .wireguard {
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
            var requestedAppRules = appTunnelModeSelected
                ? NEAppRuleBuilder.build(from: rules, log: traceLog, verbose: Self.vpnTraceVerbose)
                : []
            if !appTunnelModeSelected, !rules.isEmpty {
                traceLog("routing mode is full-tunnel; ignoring \(rules.count) app rules")
            }

            if AppConstants.isPerAppSplitTunnelEnabled, appTunnelModeSelected {
                let fromHardcodedPaths = NEAppRuleBuilder.buildFromAlwaysIncludedPaths(
                    AppConstants.perAppAlwaysIncludeAppPaths,
                    log: traceLog,
                    verbose: Self.vpnTraceVerbose
                )
                if !fromHardcodedPaths.isEmpty {
                    traceLog("perAppAlwaysIncludeAppPaths: added \(fromHardcodedPaths.count) NEAppRule(s) before merge")
                }
                requestedAppRules = NEAppRuleBuilder.dedupe(
                    requestedAppRules + fromHardcodedPaths,
                    log: traceLog,
                    verbose: Self.vpnTraceVerbose
                )
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

            /// Full-tunnel mode with destination-CIDR filtering: activate the transparent proxy
            /// to filter all apps' flows by destination CIDR, but keep the standard (non-per-app)
            /// VPN manager so 0.0.0.0/0 → utun routes everything (including the proxy's own
            /// relay connections) through the tunnel without needing per-app attribution.
            let isFullTunnelDestFilterShape = AppConstants.isPerAppSplitTunnelEnabled
                && !appTunnelModeSelected
                && settings.enforceDestinationFiltering
                && !destinationCidrStrings.isEmpty
                && profileOkForAccounting

            Self.osLog.notice("[connect] routingMode=\(self.settings.routingMode.rawValue) hasAppTunnelSelection=\(hasAppTunnelSelection) profileOkForAccounting=\(profileOkForAccounting) useAppTunnelNEStack=\(useAppTunnelNEStack) isFullTunnelDestFilterShape=\(isFullTunnelDestFilterShape) requestedAppRules=\(requestedAppRules.count)")

            // SSH egress tunnels only the flows the transparent proxy captures. If neither the
            // app-tunnel proxy stack nor the full-tunnel dest-filter proxy stack activates (e.g.
            // full-tunnel mode with no app selection — SSH has no WireGuard default-route peer to
            // satisfy `profileOkForAccounting`), there is nothing to feed the UDS→SSH relay and
            // traffic would silently exit direct while the tunnel reports "connected". Fail loudly
            // instead. v1: SSH requires App-Tunnel mode with at least one selected app.
            if profile.transport == .ssh && !useAppTunnelNEStack && !isFullTunnelDestFilterShape {
                stats.state = .error
                stats.lastError =
                    "SSH profiles require App-Tunnel mode. Switch this profile to App-Tunnel routing and select the apps to route through SSH."
                stats.connectedProfileID = nil
                stats.endpoint = nil
                emitConnectSummaryLine(
                    outcome: "aborted",
                    profileName: profile.name,
                    reason: "ssh_requires_app_tunnel",
                    wantedAppTunnel: hasAppTunnelSelection,
                    neAppRuleCount: requestedAppRules.count,
                    routingMethod: nil,
                    onDemand: nil,
                    managerAppRuleCount: nil
                )
                return
            }

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


            var destinationEnforce = false
            var destinationRanges: [String] = []

            if useAppTunnelNEStack || isFullTunnelDestFilterShape {
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
                if !profileOkForAccounting && profile.transport == .wireguard {
                    destinationRanges = extensionProfile.peers.flatMap { $0.allowedIPs }
                    destinationEnforce = true
                    persistDestinationRoutingFromHost(enforceFiltering: true, ranges: destinationRanges)
                    traceLog("split-tunnel: proxy destination filter set to AllowedIPs (\(destinationRanges.count) CIDRs)")
                } else {
                    destinationEnforce = settings.enforceDestinationFiltering
                    destinationRanges = destinationCidrStrings
                    persistDestinationRoutingFromHost(
                        enforceFiltering: destinationEnforce,
                        ranges: destinationRanges,
                        domainNames: destinationDomainNames
                    )
                }
                pendingTransparentProxyConfig = makeTransparentProxyRuntimeConfig(
                    appRules: requestedAppRules,
                    routeAllIdentifiedFlows: !hasAppTunnelSelection,
                    enforceDestinationFiltering: destinationEnforce,
                    destinationRanges: destinationRanges,
                    destinationDomainNames: destinationDomainNames,
                    dropTunneledUDP: profile.transport == .ssh,
                    // Server-side DNS: only SSH mode can resolve names on the far end (via direct-tcpip).
                    // WireGuard mode must keep local resolution + numeric-IP relay, so gate strictly on transport.
                    remoteDNSResolution: profile.transport == .ssh
                )
                traceLog(
                    "transparent proxy runtime config: signingIDs=\(pendingTransparentProxyConfig?.signingIdentifiers.count ?? 0) routeAll=\(!hasAppTunnelSelection) destRanges=\(destinationRanges.count) destDomains=\(destinationDomainNames.count) names=[\(destinationDomainNames.prefix(12).joined(separator: ","))]"
                )
                traceLog(
                    "VPN accounting stack: tunnel DNS servers=[\(extensionProfile.interface.dnsServers.joined(separator: ", "))]"
                )
            } else {
                pendingTransparentProxyConfig = nil
                clearPersistedPerAppRoutedSigningIdentifiers()
                traceLog("full-tunnel mode: destination-IP routing only (no app-tunnel accounting stack; missing default-route peer or split disabled)")
            }

            var rulesForVPNManager = requestedAppRules
            if useAppTunnelNEStack, settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                rulesForVPNManager = NEAppRuleBuilder.dedupe(
                    rulesForVPNManager + [hostRule],
                    log: traceLog,
                    verbose: Self.vpnTraceVerbose
                )
                traceLog(
                    "tunnel probe: merged host app NEAppRule signingID=\(hostRule.matchSigningIdentifier) totalRules=\(rulesForVPNManager.count)"
                )
            }
            
            // Destination split: selected apps stay OUT of NEAppRules so the transparent proxy
            // intercepts their flows first; in-CIDR relay traffic reaches the VPN via the XPC
            // bridge into the packet-tunnel extension (smoltcp → BoringTun), not NWConnection.
            let destinationSplitActive = useAppTunnelNEStack && destinationEnforce && !destinationRanges.isEmpty
            let putSelectedAppsOnTunnel = hasAppTunnelSelection && !destinationSplitActive
            var finalAppRules: [NEAppRule] = []
            if useAppTunnelNEStack {
                let proxyRule = PerAppStatsProxyManager.extensionAppRule()
                if destinationSplitActive {
                    var tunnelRules: [NEAppRule] = [proxyRule]
                    if settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                        tunnelRules.append(hostRule)
                    }
                    finalAppRules = NEAppRuleBuilder.dedupe(
                        tunnelRules,
                        log: traceLog,
                        verbose: Self.vpnTraceVerbose
                    )
                    traceLog(
                        "app-tunnel: destination-filtered XPC relay destCIDRs=\(destinationRanges.count) tunnelRules=\(finalAppRules.count) (proxy-only NEAppRules)"
                    )
                } else if putSelectedAppsOnTunnel {
                    // app-tunnel with NO destination filter: route the selected apps THROUGH the
                    // transparent proxy rather than the kernel per-app VPN, so their flows are
                    // intercepted, relayed via the tunnel, AND counted for per-app stats. Keeping
                    // them OUT of NEAppRules is what lets the proxy see them — the proxy's
                    // includedNetworkRules are catch-all when filtering is off, so it intercepts
                    // every flow and relays the routed (selected) apps while releasing the rest.
                    // This mirrors the destination-split path; the only difference is catch-all vs
                    // narrowed interception. Trade-off (chosen deliberately): the selected apps take
                    // the userspace relay hop instead of the more efficient kernel NEAppRule, which
                    // is the price of per-app byte attribution in this mode.
                    var tunnelRules: [NEAppRule] = [proxyRule]
                    if settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                        tunnelRules.append(hostRule)
                    }
                    finalAppRules = NEAppRuleBuilder.dedupe(
                        tunnelRules,
                        log: traceLog,
                        verbose: Self.vpnTraceVerbose
                    )
                    traceLog("app-tunnel: selected apps via transparent proxy for stats (no destination filter)")
                } else if hasAppTunnelSelection {
                    var tunnelRules: [NEAppRule] = [proxyRule]
                    if settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                        tunnelRules.append(hostRule)
                    }
                    finalAppRules = NEAppRuleBuilder.dedupe(
                        tunnelRules,
                        log: traceLog,
                        verbose: Self.vpnTraceVerbose
                    )
                    traceLog("app-tunnel: proxy-only tunnel NEAppRules (no selected apps)")
                } else {
                    finalAppRules = [proxyRule]
                    if settings.includeHostAppInPerAppRulesForProbe, let hostRule = makeHostAppNEAppRule() {
                        finalAppRules = NEAppRuleBuilder.dedupe(
                            finalAppRules + [hostRule],
                            log: traceLog,
                            verbose: Self.vpnTraceVerbose
                        )
                    }
                }
                traceLog("app-tunnel: tunnel NEAppRules count=\(finalAppRules.count)")
            }

            // In full_tunnel+filter shape, narrow the packet tunnel's includedRoutes to only
            // the filter CIDRs so the kernel routes only those IPs through utun. Out-of-filter
            // traffic falls back to en0 without needing any cleanup on disconnect or crash —
            // the next connect rewrites the file with whatever shape is active then.
            // DNS server IPs must also be included; they live inside the WireGuard virtual
            // network (e.g. 10.2.0.1) and are unreachable if not routed through utun.
            let tunnelIncludedRoutes: [String]? = isFullTunnelDestFilterShape
                ? destinationCidrStrings + extensionProfile.interface.dnsServers.map { $0.contains(":") ? "\($0)/128" : "\($0)/32" }
                : nil
            let fileRuntimeData = try makeRuntimeStateData(
                profile: extensionProfile,
                includeSecrets: false,
                appTunnelIncludedRoutes: tunnelIncludedRoutes
            )
            try persistRuntimeState(data: fileRuntimeData)
            let tunnelRuntimeData = try makeRuntimeStateData(
                profile: extensionProfile,
                includeSecrets: true,
                appTunnelIncludedRoutes: tunnelIncludedRoutes
            )
            traceLog("runtime state persisted for profile=\(profile.name)")
            let appRules = useAppTunnelNEStack ? finalAppRules : []
            try await configureManager(
                appRules: appRules,
                runtimeStateData: tunnelRuntimeData,
                useAppTunnelNEStack: useAppTunnelNEStack,
                hasDefaultRoute: profileHasDefaultRoute(profile: extensionProfile),
                destinationSplitActive: destinationSplitActive,
                narrowedRoutes: isFullTunnelDestFilterShape
            )
            managerSavedEnabledThisAttempt = true

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
                stats.lastError = tunnelConnectFailureMessage(neStatus: manager.connection.status)
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
                await coordinatedDisconnect(waitForTunnelStop: false)
                stats.state = .error
                return
            case .stillStarting:
                Self.osLog.notice("[connect] NEVPN stillStarting — awaiting deferred completion inline")
                traceLog("connect: NEVPN still starting after initial wait; awaiting completion")
                stats.state = .connecting
                stats.connectedProfileID = profile.id
                stats.lastError = nil
                await finishConnectAfterDeferredTunnelWait(
                    expectedProfileID: profile.id,
                    profile: profile,
                    extensionProfile: extensionProfile,
                    hasAppTunnelSelection: hasAppTunnelSelection,
                    useAppTunnelNEStack: useAppTunnelNEStack,
                    profileOkForAccounting: profileOkForAccounting,
                    rulesForVPNManagerCount: rulesForVPNManager.count,
                    destinationSplitActive: destinationSplitActive,
                    isFullTunnelDestFilterShape: isFullTunnelDestFilterShape
                )
            case .connected:
                await applySuccessfulConnectPostTunnel(
                    profile: profile,
                    extensionProfile: extensionProfile,
                    hasAppTunnelSelection: hasAppTunnelSelection,
                    useAppTunnelNEStack: useAppTunnelNEStack,
                    profileOkForAccounting: profileOkForAccounting,
                    rulesForVPNManagerCount: rulesForVPNManager.count,
                    destinationSplitActive: destinationSplitActive,
                    isFullTunnelDestFilterShape: isFullTunnelDestFilterShape
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
            // If configureManager already saved preferences with isEnabled/isOnDemandEnabled for
            // this attempt (e.g. startVPNTunnel threw afterwards), the NEOnDemandRuleConnect rule
            // stays on disk and macOS relaunches the broken tunnel on any network activity —
            // the phantom connect/disconnect-every-19s bug. Best-effort disable, mirroring
            // performDisconnect; only touches the manager this attempt configured, and (like the
            // startup cleanup) only while the system tunnel is fully stopped so a still-live
            // tunnel is never orphaned with disabled preferences.
            if managerSavedEnabledThisAttempt, isTunnelFullyStopped(),
               manager.isEnabled || manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                manager.isEnabled = false
                do {
                    try await manager.saveToPreferences()
                    try await manager.loadFromPreferences()
                    traceLog("connect failure cleanup: disabled saved config (isEnabled=false, isOnDemandEnabled=false)")
                } catch {
                    traceLog("connect failure cleanup: WARNING — failed to disable saved config: \(error.localizedDescription)")
                }
            }
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

    /// Live-push the connected per-app-split profile's merged destination CIDRs to the running
    /// proxy so a domain that resolved to a new IP mid-session (e.g. a CDN's second A record)
    /// starts tunneling immediately, without a reconnect. The shared `destination-routing.json`
    /// can't carry this (host and proxy are different uids → different App Group containers), so
    /// this rides the provider-message channel instead. Reconnect correctness is already covered
    /// by the rule store accumulating resolved IPs; this only closes the mid-session gap.
    @MainActor
    @discardableResult
    func pushDestinationRangesToRunningProxy(enforce: Bool, ranges: [String]) async -> Bool {
        await perAppStatsProxy.pushDestinationRanges(enforce: enforce, ranges: ranges)
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
        // After startVPNTunnel(), the NE manager briefly stays at .disconnected while
        // the daemon processes the request (especially with forPerAppVPN + On-Demand).
        // Fast-failing on that initial disconnected state causes a false error before the
        // tunnel reaches .connecting. 3 s gives slower Macs (and heavier on-demand configs)
        // enough runway to transition to .connecting without a false teardown.
        let graceDeadline = Date().addingTimeInterval(3.0)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if connectCancelled {
                return .cancelled
            }
            let status = manager.connection.status
            if status == .connected {
                return .connected
            }
            if (status == .disconnected || status == .invalid), Date() > graceDeadline {
                return .failed
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

    private func finishConnectAfterDeferredTunnelWait(
        expectedProfileID: UUID,
        profile: WireGuardProfile,
        extensionProfile: WireGuardProfile,
        hasAppTunnelSelection: Bool,
        useAppTunnelNEStack: Bool,
        profileOkForAccounting: Bool,
        rulesForVPNManagerCount: Int,
        destinationSplitActive: Bool,
        isFullTunnelDestFilterShape: Bool = false
    ) async {
        // Mirror the grace from waitForTunnelConnectOutcome: NE can flicker to .disconnected
        // during forPerAppVPN manager reconfiguration transitions before settling into .connecting.
        let graceDeadline = Date().addingTimeInterval(3.0)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if connectCancelled {
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
                    rulesForVPNManagerCount: rulesForVPNManagerCount,
                    destinationSplitActive: destinationSplitActive,
                    isFullTunnelDestFilterShape: isFullTunnelDestFilterShape
                )
                return
            }
            if (status == .disconnected || status == .invalid), Date() > graceDeadline {
                stats.state = .error
                stats.lastError = tunnelConnectFailureMessage(neStatus: status)
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
                await coordinatedDisconnect(waitForTunnelStop: false)
                stats.state = .error
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        if connectCancelled {
            return
        }
        if manager.connection.status == .connected {
            await applySuccessfulConnectPostTunnel(
                profile: profile,
                extensionProfile: extensionProfile,
                hasAppTunnelSelection: hasAppTunnelSelection,
                useAppTunnelNEStack: useAppTunnelNEStack,
                profileOkForAccounting: profileOkForAccounting,
                rulesForVPNManagerCount: rulesForVPNManagerCount,
                destinationSplitActive: destinationSplitActive,
                isFullTunnelDestFilterShape: isFullTunnelDestFilterShape
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
        await coordinatedDisconnect(waitForTunnelStop: false)
        stats.state = .error
    }

    private func applySuccessfulConnectPostTunnel(
        profile: WireGuardProfile,
        extensionProfile: WireGuardProfile,
        hasAppTunnelSelection: Bool,
        useAppTunnelNEStack: Bool,
        profileOkForAccounting: Bool,
        rulesForVPNManagerCount: Int,
        destinationSplitActive: Bool,
        isFullTunnelDestFilterShape: Bool = false
    ) async {
        Self.osLog.notice(
            "[connect] applySuccessfulConnectPostTunnel hasAppTunnelSelection=\(hasAppTunnelSelection) useAppTunnelNEStack=\(useAppTunnelNEStack) profileOkForAccounting=\(profileOkForAccounting) destinationSplitActive=\(destinationSplitActive) isFullTunnelDestFilterShape=\(isFullTunnelDestFilterShape)"
        )
        let useTransparentProxy = useAppTunnelNEStack || isFullTunnelDestFilterShape
        stats.state = .connected
        stats.connectedAt = .now
        stats.connectedProfileID = profile.id
        stats.endpoint = profile.transport == .ssh
            ? profile.ssh.map { "\($0.host):\($0.port)" }
            : extensionProfile.peers.first?.endpoint
        stats.perAppSplitTunnelActive = hasAppTunnelSelection && useAppTunnelNEStack
        stats.perAppStatsCollectionActive = useTransparentProxy
        stats.tunnelHasDefaultRoute = profileOkForAccounting && !destinationSplitActive

        if useTransparentProxy {
            PerAppTransferStore.reset()
            Self.osLog.notice("[connect] calling perAppStatsProxy.enable() destinationSplit=\(destinationSplitActive)")
            do {
                guard var proxyConfig = pendingTransparentProxyConfig else {
                    throw NSError(
                        domain: "TunnelBahn.VPN",
                        code: 10,
                        userInfo: [NSLocalizedDescriptionKey: "Missing transparent proxy runtime configuration."]
                    )
                }
                // Relay outbound connections must be bound to the utun interface because
                // NE extension process NWConnections bypass per-app VPN routing — `setMetadata`
                // propagates the source-app identity but does NOT redirect the socket onto utun.
                // Needed both for destination-split (S4) and app-tunnel-without-filter (S3) shapes.
                if let session = manager.connection as? NETunnelProviderSession {
                    if let ifName = await sendProviderMessage(session, command: "tunnelInterfaceName") {
                        proxyConfig.packetTunnelInterfaceName = ifName
                        Self.osLog.notice("[connect] resolved tunnelInterfaceName=\(ifName)")
                    } else {
                        Self.osLog.notice("[connect] tunnelInterfaceName IPC returned nil — relay will use default route")
                    }
                    pendingTransparentProxyConfig = proxyConfig
                }
                try await perAppStatsProxy.enable(config: proxyConfig)
                pendingTransparentProxyConfig = nil
                Self.osLog.notice("[connect] perAppStatsProxy.enable() succeeded")
            } catch {
                Self.osLog.notice("[connect] perAppStatsProxy.enable() failed: \(error.localizedDescription)")
                traceLog("app-tunnel stats proxy enable failed: \(error.localizedDescription)")
                stats.state = .error
                stats.lastError = "App-tunnel accounting could not start: \(error.localizedDescription)"
                await coordinatedDisconnect(waitForTunnelStop: false)
                stats.state = .error
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
        // Skip the probe entirely for profiles without a default route (LAN-only / split-destination):
        // all probe URLs are internet addresses not in AllowedIPs, so they'd be silently dropped by WireGuard.
        let probePhase: TunnelProbePhase = {
            guard useAppTunnelNEStack else { return .fullTunnel }
            guard hasAppTunnelSelection else { return .fullTunnel }
            if settings.includeHostAppInPerAppRulesForProbe { return .appTunnelHostIncluded }
            return .appTunnelHostExcluded
        }()
        let profileID = profile.id
        let runProbe = settings.runTunnelConnectivityProbe && profileOkForAccounting && !destinationSplitActive

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
                Task { [weak self] in await self?.refreshPublicIPAndLocation() }
                let result = await TunnelConnectivityProbe.warmup(phase: probePhase, comparePublicIP: nil)
                guard self.stats.connectedProfileID == profileID, self.stats.state == .connected else { return }
                self.stats.connectivityProbeResult = result
                self.startPeriodicProbeIfNeeded(phase: probePhase, profileID: profileID)
            } else {
                await self.refreshPublicIPAndLocation()
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
        enterOperationBusy()
        stats.state = .disconnecting
        Task {
            defer { leaveOperationBusy() }
            await coordinatedDisconnect(waitForTunnelStop: false)
        }
    }

    /// Prefer Network Extension status over UI mirror when deciding whether shutdown is needed before quit.
    func shouldDeferTerminationForVPN() -> Bool {
        !isTunnelFullyStopped()
    }

    func disconnectAndWait() async {
        guard stats.state != .disconnected || !isTunnelFullyStopped() else { return }
        shouldAutoReconnect = false
        connectCancelled = true
        manager.connection.stopVPNTunnel()
        await waitForConnectToFinishIfNeeded(timeoutSeconds: 15)
        stats.state = .disconnecting
        await coordinatedDisconnect(waitForTunnelStop: true)
    }

    func disconnectForTermination() async {
        shouldAutoReconnect = false
        connectCancelled = true
        manager.connection.stopVPNTunnel()
        await waitForConnectToFinishIfNeeded(timeoutSeconds: 45)

        if stats.state == .disconnected, isTunnelFullyStopped() {
            traceLog("termination cleanup skipped: already fully stopped")
            return
        }

        traceLog("termination cleanup requested")
        enterOperationBusy()
        defer { leaveOperationBusy() }
        stats.state = .disconnecting
        await coordinatedDisconnect(waitForTunnelStop: true)
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
        let appRules = manager.appRules
        if Self.vpnTraceVerbose {
            traceLog("=== MANAGER CONFIGURATION DUMP ===")
            traceLog("routingMethod: \(manager.routingMethod.rawValue) (1=destinationIP, 2=sourceApplication)")
            traceLog("isEnabled: \(manager.isEnabled)")
            traceLog("isOnDemandEnabled: \(manager.isOnDemandEnabled)")
            traceLog("localizedDescription: \(manager.localizedDescription ?? "nil")")
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
        } else {
            traceLog(
                "manager config: routing=\(manager.routingMethod.rawValue) enabled=\(manager.isEnabled) " +
                "onDemand=\(manager.isOnDemandEnabled) appRules=\(appRules.count) conn=\(manager.connection.status.rawValue)"
            )
        }
    }
    
    private func configureManager(
        appRules: [NEAppRule],
        runtimeStateData: Data,
        useAppTunnelNEStack: Bool,
        hasDefaultRoute: Bool = false,
        destinationSplitActive: Bool = false,
        narrowedRoutes: Bool = false
    ) async throws {
        traceLog(
            "configureManager started useAppTunnelNEStack=\(useAppTunnelNEStack) appRules=\(appRules.count) " +
            "hasDefaultRoute=\(hasDefaultRoute) destinationSplitActive=\(destinationSplitActive)"
        )
        try await loadOrCreateTunnelManager(useAppTunnelNEStack: useAppTunnelNEStack)

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.packetTunnelProviderBundleIdentifier
        proto.serverAddress = "TunnelBahn"
        let runtimeStateB64 = runtimeStateData.base64EncodedString()
        proto.providerConfiguration = [
            "profile": "active",
            "runtimeStateB64": runtimeStateB64,
        ]
        // Per-app NEAppRules still need includeAllNetworks on default-route profiles so matched
        // apps bind to the tunnel stack; destination split relies on utun includedRoutes (not this flag).
        if useAppTunnelNEStack {
            proto.excludeLocalNetworks = true
            if hasDefaultRoute {
                proto.includeAllNetworks = true
                proto.enforceRoutes = false
            } else {
                proto.includeAllNetworks = false
                proto.enforceRoutes = true
            }
        } else if hasDefaultRoute && !narrowedRoutes {
            // narrowedRoutes=true means includedRoutes is already restricted to filter CIDRs;
            // includeAllNetworks would override that and force everything through utun, defeating
            // the split. Leave it false so the kernel respects the narrowed includedRoutes.
            proto.includeAllNetworks = true
            proto.excludeLocalNetworks = true
        } else {
            proto.enforceRoutes = true
        }
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

        let tunnelProto = manager.protocolConfiguration as? NETunnelProviderProtocol
        traceLog(
            "about to save: routingMethod=\(manager.routingMethod.rawValue) isOnDemandEnabled=\(manager.isOnDemandEnabled) " +
            "onDemandRules=\(manager.onDemandRules?.count ?? 0) appRules=\(manager.appRules.count) " +
            "includeAllNetworks=\(tunnelProto?.includeAllNetworks ?? false) enforceRoutes=\(tunnelProto?.enforceRoutes ?? false)"
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

        if Self.vpnTraceVerbose {
            for (index, mgr) in managers.enumerated() {
                traceLog(
                    "  manager[\(index)]: desc=\(mgr.localizedDescription ?? "nil") routing=\(mgr.routingMethod.rawValue) enabled=\(mgr.isEnabled)"
                )
            }
        }

        let matching = managers.filter { $0.localizedDescription == AppConstants.vpnManagerDescription }
        if let existing = matching.first {
            manager = existing
            // If the previous session ended without clean teardown (force-quit, crash while
            // connected), the manager may still have isOnDemandEnabled=true on disk. macOS sees
            // the On-Demand rule and repeatedly tries to start the packet tunnel on network
            // activity, producing phantom connect→disconnect cycles every ~19 seconds.
            // Only clear stale on-demand prefs when the system tunnel is fully stopped; if the
            // tunnel is still live (force-quit while connected), leave prefs intact so the running
            // tunnel is not orphaned with disabled manager preferences.
            let liveStatus = existing.connection.status
            let tunnelIsStopped = liveStatus == .disconnected || liveStatus == .invalid
            if tunnelIsStopped, existing.isOnDemandEnabled || existing.isEnabled {
                existing.isOnDemandEnabled = false
                existing.isEnabled = false
                do {
                    try await existing.saveToPreferences()
                    try await existing.loadFromPreferences()
                    traceLog("startup: cleared stale on-demand/enabled from previous session")
                } catch {
                    traceLog("startup: WARNING — failed to clear stale on-demand: \(error.localizedDescription)")
                }
            }
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
        disconnectRunning = true
        defer {
            disconnectRunning = false
            lastLoggedDisconnectSuppressRaw = nil
        }
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

        publicIPRefreshTask?.cancel()
        publicIPRefreshTask = nil
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
        stats.tunnelHasDefaultRoute = false
        stats.bytesIn = 0
        stats.bytesOut = 0
        stats.rxBytesPerSecond = 0
        stats.txBytesPerSecond = 0
        stats.perAppAggregateRxBytesPerSecond = 0
        stats.perAppAggregateTxBytesPerSecond = 0
        stats.perAppStats = [:]
        stats.perDestinationStats = []
        stats.perAppStatsUpdatedAt = nil
        stats.connectivityProbeResult = .unknown
        stats.competingProxySigningIDs = []
        stopStatsRefresh()
        stopPeriodicProbe()
        syncExtensionResourceStats()
        shouldAutoReconnect = false
        connectCancelled = false
        traceLog("disconnect completed")
    }

    private func makeRuntimeStateData(
        profile: WireGuardProfile,
        includeSecrets: Bool,
        appTunnelIncludedRoutes: [String]? = nil
    ) throws -> Data {
        // WireGuard secrets (interface private key + preshared keys) only exist for WG profiles.
        // SSH profiles carry no WG interface key; their credential travels via `ssh.privateKeyRef`
        // (read by the extension), so resolving WG secrets here would fail with errSecItemNotFound.
        let secrets = (includeSecrets && profile.transport == .wireguard)
            ? try TunnelRuntimeState.resolveSecrets(for: profile) : nil
        // Resolve the SSH private key app-side (uid 501 can read the Keychain) and embed the PEM in
        // the runtime state — the root extension cannot read the user-context Keychain item across
        // the uid boundary. Only include the secret material in the secrets-bearing payload.
        let ssh: TunnelSSHParams?
        if profile.transport == .ssh, let sshProfile = profile.ssh {
            let pem = includeSecrets ? try KeychainService.shared.read(account: sshProfile.privateKeyRef) : nil
            ssh = TunnelSSHParams(
                host: sshProfile.host,
                port: sshProfile.port,
                username: sshProfile.username,
                privateKeyRef: sshProfile.privateKeyRef,
                privateKeyPEM: pem,
                hostKeyFingerprint: sshProfile.hostKeyFingerprint
            )
        } else {
            ssh = nil
        }
        let payload = TunnelRuntimeState(
            profile: profile,
            secrets: secrets,
            appTunnelIncludedRoutes: appTunnelIncludedRoutes,
            ssh: ssh
        )
        return try JSONEncoder().encode(payload)
    }

    private func makeTransparentProxyRuntimeConfig(
        appRules: [NEAppRule],
        routeAllIdentifiedFlows: Bool,
        enforceDestinationFiltering: Bool,
        destinationRanges: [String],
        destinationDomainNames: [String],
        dropTunneledUDP: Bool,
        remoteDNSResolution: Bool
    ) -> TransparentProxyRuntimeConfig {
        TransparentProxyRuntimeConfig(
            signingIdentifiers: routeAllIdentifiedFlows ? [] : signingIdentifiers(from: appRules),
            routeAllIdentifiedFlows: routeAllIdentifiedFlows,
            destinationRouting: DestinationRoutingFilePayload(
                enforceDestinationFiltering: enforceDestinationFiltering,
                ranges: destinationRanges,
                domainNames: destinationDomainNames
            ),
            dropTunneledUDP: dropTunneledUDP,
            remoteDNSResolution: remoteDNSResolution
        )
    }

    private func signingIdentifiers(from appRules: [NEAppRule]) -> [String] {
        var ids = Set<String>()
        for rule in appRules {
            let trimmed = rule.matchSigningIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                ids.insert(trimmed)
            }
        }
        return Array(ids).sorted()
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

    private func persistDestinationRoutingFromHost(enforceFiltering: Bool, ranges: [String], domainNames: [String] = []) {
        guard let fileURL = SharedPaths.destinationRangesFileURL() else {
            traceLog("WARNING: unable to locate destination routing App Group URL")
            return
        }
        let payload = DestinationRoutingFilePayload(enforceDestinationFiltering: enforceFiltering, ranges: ranges, domainNames: domainNames)
        do {
            try DestinationRoutingFileStore.write(payload, to: fileURL)
            traceLog("destination routing file written enforce=\(enforceFiltering) rawRangeCount=\(ranges.count) domainNames=\(domainNames.count)")
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
        // While performDisconnect owns the lifecycle, ignore any transient NE state that would
        // regress the UI back toward connected. Only .disconnecting and .disconnected are allowed
        // through; everything else is noise from the NE manager reconfiguration during teardown.
        if disconnectRunning, status != .disconnecting, status != .disconnected, status != .invalid {
            let r = status.rawValue
            if lastLoggedDisconnectSuppressRaw != r {
                lastLoggedDisconnectSuppressRaw = r
                traceLog("syncStatus suppressed during disconnect: manager=\(r)")
            }
            return
        }
        switch manager.connection.status {
        case .connected: stats.state = .connected
        case .connecting: stats.state = .connecting
        case .disconnecting: stats.state = .disconnecting
        case .reasserting: stats.state = .reconnecting
        case .invalid, .disconnected:
            // NE reports disconnected/invalid while preferences are rewritten and again before
            // `startVPNTunnel` promotes status — during that gap the tunnel is fully stopped but
            // `connect()` still owns the lifecycle. Only mirror NE→disconnected when not connecting.
            if !connectRunning {
                stats.state = .disconnected
                stats.connectedProfileID = nil
                stats.publicIP = nil
                stats.publicIPLocation = nil
                stats.tunnelHasDefaultRoute = false
                stats.connectivityProbeResult = .unknown
            }
        @unknown default: stats.state = .error
        }
        if stats.state == .connected, stats.connectedProfileID == nil {
            if let runtimeProfile = loadPersistedRuntimeProfile() {
                stats.connectedProfileID = runtimeProfile.id
                stats.endpoint = runtimeProfile.transport == .ssh
                    ? runtimeProfile.ssh.map { "\($0.host):\($0.port)" }
                    : runtimeProfile.peers.first?.endpoint
            }
        }
        if stats.state == .connected, stats.tunnelHasDefaultRoute, stats.publicIP == nil,
           publicIPRefreshTask == nil {
            publicIPRefreshTask = Task { @MainActor [weak self] in
                await self?.refreshPublicIPAndLocation()
                self?.publicIPRefreshTask = nil
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
        let syncKey = "\(status.rawValue)|\(stats.state.rawValue)"
        if lastLoggedSyncStatusKey != syncKey {
            lastLoggedSyncStatusKey = syncKey
            traceLog("syncStatus manager=\(status.rawValue) appState=\(stats.state.rawValue)")
        }
    }

    /// Zeroes extension CPU/memory on disconnect. The live values can't come from
    /// `ExtensionResourceStore` (the root extensions write it into a container this user host
    /// can't read), so they're pulled over IPC by `refreshExtensionResourceStatsViaIPC()`; while
    /// connected this leaves the last-fetched values in place so they don't flicker to zero.
    private func syncExtensionResourceStats() {
        guard stats.state == .connected || stats.state == .reconnecting else {
            stats.packetTunnelCPUUsage = 0
            stats.packetTunnelMemoryUsage = 0
            stats.transparentProxyCPUUsage = 0
            stats.transparentProxyMemoryUsage = 0
            stats.extensionStatsUpdatedAt = nil
            return
        }
    }

    /// Pulls each extension's own CPU/memory over `sendProviderMessage` (packet tunnel via its
    /// session, proxy via `PerAppStatsProxyManager`) and merges them. A nil reply from either
    /// leaves that extension's previous values untouched.
    private func refreshExtensionResourceStatsViaIPC() async {
        guard stats.state == .connected || stats.state == .reconnecting else { return }
        if let session = manager.connection as? NETunnelProviderSession,
           let json = await sendProviderMessage(session, command: "resourceStats"),
           let usage = Self.parseResourceUsage(json) {
            stats.packetTunnelCPUUsage = usage.cpu
            stats.packetTunnelMemoryUsage = usage.memory
        }
        if let usage = await perAppStatsProxy.fetchResourceUsage() {
            stats.transparentProxyCPUUsage = usage.cpu
            stats.transparentProxyMemoryUsage = usage.memory
        }
        stats.extensionStatsUpdatedAt = .now
    }

    private static func parseResourceUsage(_ json: String) -> (cpu: Double, memory: UInt64)? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cpu = (obj["cpu"] as? NSNumber)?.doubleValue,
              let memory = (obj["memory"] as? NSNumber)?.uint64Value
        else { return nil }
        return (cpu, memory)
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
              let state = try? JSONDecoder().decode(TunnelRuntimeState.self, from: data)
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

    private func startPeriodicProbeIfNeeded(phase: TunnelProbePhase, profileID: UUID) {
        guard periodicProbeTask == nil else { return }
        periodicProbeTask = Task { @MainActor [weak self] in
            // If the loop exits on its own (e.g. a transient non-connected state), clear the
            // handle so the next `startPeriodicProbeIfNeeded` can restart the probe. A cancelled
            // task must NOT clear it: `stopPeriodicProbe` already did, and a new task may own it.
            defer {
                if !Task.isCancelled {
                    self?.periodicProbeTask = nil
                }
            }
            while !Task.isCancelled {
                // Recheck quickly while no internet detected, slowly once confirmed ok.
                let interval: Duration = self?.stats.connectivityProbeResult == .ok ? .seconds(60) : .seconds(5)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                guard let self,
                      self.stats.connectedProfileID == profileID,
                      self.stats.state == .connected else { break }
                let result = await TunnelConnectivityProbe.recheck(phase: phase)
                guard !Task.isCancelled,
                      self.stats.connectedProfileID == profileID,
                      self.stats.state == .connected else { break }
                self.stats.connectivityProbeResult = result
            }
        }
    }

    private func stopPeriodicProbe() {
        periodicProbeTask?.cancel()
        periodicProbeTask = nil
    }

    private func refreshWireGuardStats() async {
        guard stats.state == .connected || stats.state == .reconnecting else { return }
        // Read the competing-proxy file unconditionally — it lives in the App Group filesystem and
        // is independent of the WireGuard IPC channel below. An IPC timeout must not leave the
        // warning stale.
        refreshCompetingProxyWarningFromExtensionFile()
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

        // App-tunnel counters (transparent proxy accounting). Pulled over `sendProviderMessage`
        // because the proxy extension (root) and this host (user) resolve the App Group container
        // to different directories and the sandbox blocks the root extension from writing into the
        // user's container — so a shared file can't carry stats across the boundary. A nil reply
        // (timeout / proxy not up) is tolerated by falling back to `.empty`.
        if stats.perAppStatsCollectionActive {
            let snapshot = await perAppStatsProxy.fetchStats() ?? .empty
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
        await refreshExtensionResourceStatsViaIPC()
    }

    /// Reads the proxy extension's observed-foreign-proxy file and updates
    /// `stats.competingProxySigningIDs`. The extension writes on change when `handleNewFlow` sees
    /// a proxy-like signing ID on a flow it declines (`!routed`).
    ///
    /// In route-all-identified-flows mode every identifiable flow is routed, so that path stays
    /// cold and the file stays empty. Competing-proxy hints are only aimed at explicit per-app
    /// routing, where another extension shadowing breaks user expectations.
    private func refreshCompetingProxyWarningFromExtensionFile() {
        guard let url = SharedPaths.observedForeignProxySigningIDsFileURL() else {
            if !stats.competingProxySigningIDs.isEmpty { stats.competingProxySigningIDs = [] }
            return
        }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = obj["signingIdentifiers"] as? [String]
        else {
            if !stats.competingProxySigningIDs.isEmpty { stats.competingProxySigningIDs = [] }
            return
        }
        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        if cleaned != stats.competingProxySigningIDs {
            stats.competingProxySigningIDs = cleaned
        }
    }

    private func loadRuntimeConfiguration() async -> String? {
        guard let session = manager.connection as? NETunnelProviderSession else { return nil }
        return await sendProviderMessage(session, command: "runtimeConfiguration", timeoutSeconds: 8)
    }

    private func sendProviderMessage(
        _ session: NETunnelProviderSession,
        command: String,
        timeoutSeconds: Double = 3
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let race = ProviderMessageContinuationRace<String?>()
            // Cancel the timeout once the real reply wins, otherwise every call leaves a task
            // sleeping for the full timeout (they accumulate at the 2s stats cadence).
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                race.resume(continuation, returning: nil)
            }
            do {
                try session.sendProviderMessage(Data(command.utf8)) { data in
                    // Resume first, then cancel: cancelling wakes the sleeping timeout task, and
                    // doing so before firing would let it win the race with a spurious nil.
                    race.resume(continuation, returning: data.flatMap { String(data: $0, encoding: .utf8) })
                    timeoutTask.cancel()
                }
            } catch {
                timeoutTask.cancel()
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
        guard stats.tunnelHasDefaultRoute else { return }
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
        Self.osLog.debug("\(message)")
    }

    private func connectSummaryLog(_ message: String) {
        Self.osLog.info("\(message)")
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
        } else if Self.vpnTraceVerbose {
            for rule in selectedRules {
                traceLog("selectedRule displayName=\(rule.displayName) action=\(rule.action.rawValue) appPath=\(rule.appPath)")
            }
        } else {
            traceLog("selectedRules: \(selectedRules.count) (set TUNNELBAHN_VPN_TRACE_VERBOSE=1 for per-rule detail)")
        }
        if requestedAppRules.isEmpty {
            traceLog("effective NEAppRule signing identifiers: none")
        } else if Self.vpnTraceVerbose {
            for appRule in requestedAppRules {
                traceLog("effective NEAppRule signingIdentifier=\(appRule.matchSigningIdentifier)")
            }
        } else {
            traceLog("effective NEAppRules: \(requestedAppRules.count) (verbose env for signing IDs)")
        }
        traceLog("original profile summary: \(profileSummary(originalProfile))")
        traceLog("extension profile summary: \(profileSummary(extensionProfile))")
        traceLog("=== END CONNECT MODE DECISION ===")
    }

    private func logEffectiveExtensionProfile(_ profile: WireGuardProfile) {
        if Self.vpnTraceVerbose {
            traceLog("=== EFFECTIVE PROFILE FOR EXTENSION ===")
            traceLog(profileSummary(profile))
            for (index, peer) in profile.peers.enumerated() {
                traceLog(
                    "peer[\(index)] endpoint=\(peer.endpoint) allowedIPs=\(peer.allowedIPs.joined(separator: ", ")) " +
                    "keepalive=\(peer.persistentKeepalive.map(String.init) ?? "nil")"
                )
            }
            traceLog("=== END EFFECTIVE PROFILE FOR EXTENSION ===")
        } else {
            traceLog("effective extension profile: \(profileSummary(profile))")
        }
    }

    /// Single-line, grep-friendly snapshot of the user's *intent* at connect time.
    /// Print this BEFORE the connect dance so the log clearly shows what mode the user
    /// asked for, regardless of how the manager interprets it later. Run:
    ///   `log show --predicate 'subsystem == "com.tunnelbahn.mac"' --last 5m | grep APPSPLIT_SCENARIO`
    private func emitScenarioSummary(
        profile: WireGuardProfile,
        rules: [AppRule],
        destinationCidrStrings: [String]
    ) {
        let tunnelRules = rules.filter { $0.action == .routeVPN }
        let bypassRules = rules.filter { $0.action == .bypass }
        let safeProfile = profile.name.replacingOccurrences(of: " ", with: "_")
        let cidrPreview = destinationCidrStrings.prefix(8).joined(separator: ",")
        let cidrSuffix = destinationCidrStrings.count > 8 ? "+\(destinationCidrStrings.count - 8)more" : ""
        let parts = [
            "[APPSPLIT_SCENARIO]",
            "profile=\(safeProfile)",
            "routingMode=\(settings.routingMode.rawValue)",
            "enforceDestinationFiltering=\(settings.enforceDestinationFiltering)",
            "destCIDRcount=\(destinationCidrStrings.count)",
            "destCIDRs=[\(cidrPreview)\(cidrSuffix)]",
            "ruleCount=\(rules.count)",
            "tunnelRules=\(tunnelRules.count)",
            "bypassRules=\(bypassRules.count)",
        ]
        connectSummaryLog(parts.joined(separator: " "))
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
        if lowered.contains("internal error") {
            return Self.packetTunnelExtensionLaunchHint()
                ?? "VPN session failed with an internal error."
        }
        return description
    }

    private func tunnelConnectFailureMessage(neStatus: NEVPNStatus) -> String {
        let statusLine = connectionStatusString(neStatus)
        if let hint = Self.packetTunnelExtensionLaunchHint() {
            return "\(hint) (NEVPN \(statusLine))"
        }
        return "Tunnel did not connect (NEVPN \(statusLine)). If you were switching profiles, try again."
    }

    /// Explains the common macOS case where `nesessionmanager` reports Plugin failed / PID 0.
    /// Only available in DEBUG builds — distribution builds always return nil so no
    /// developer-targeted copy reaches end users and no subprocess is spawned on the main actor.
    #if DEBUG
    private static func packetTunnelExtensionLaunchHint() -> String? {
        let sysex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("\(AppConstants.packetTunnelProviderBundleIdentifier).systemextension", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sysex.path) else {
            return "Packet tunnel system extension is missing from this app bundle. Rebuild TunnelBahn from Xcode."
        }
        guard let codesignOutput = runCodesignVerbose(at: sysex.path) else { return nil }
        if codesignOutput.contains("Apple Distribution"), !codesignOutput.contains("Apple Development") {
            return """
            VPN extension is signed with Apple Distribution. macOS will not launch it for local \
            debugging. Use Product → Run in Xcode (Development signing), not a copy in /Applications \
            built for App Store or TestFlight, unless that build uses Development provisioning profiles \
            that include Network Extension entitlements for all targets.
            """
        }
        return nil
    }

    private static func runCodesignVerbose(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
    #else
    private static func packetTunnelExtensionLaunchHint() -> String? { nil }
    #endif
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

import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    var settings: AppSettings
    var profileStore: ProfileStore
    var appDiscovery: AppDiscoveryService
    var appRuleStore: AppRuleStore
    var destinationRuleStore: DestinationRuleStore
    var profileRoutingStore: ProfileRoutingStore
    var resourceMonitor: ResourceMonitor
    var vpnManager: VPNManager
    var domainResolutionCoordinator: DomainResolutionCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var lastKnownProfileID: UUID?
    /// The profile ID whose snapshot is currently installed in the live stores.
    /// Tracked separately from `selectedProfileID` so `saveCurrentSnapshot()` always writes
    /// back to the profile whose data is actually in memory — important during
    /// `connectProfile`, where `prepareLiveRoutingForConnect` swaps the live stores to the
    /// new profile before `profileStore.select(id:)` propagates.
    private var loadedProfileID: UUID?

    @Published var selectedTab: Int = 0

    init() {
        let settings = AppSettings()
        let profileStore = ProfileStore()
        let appDiscovery = AppDiscoveryService()
        let appRuleStore = AppRuleStore()
        let destinationRuleStore = DestinationRuleStore()
        let profileRoutingStore = ProfileRoutingStore()

        self.settings = settings
        self.profileStore = profileStore
        self.appDiscovery = appDiscovery
        self.appRuleStore = appRuleStore
        self.destinationRuleStore = destinationRuleStore
        self.profileRoutingStore = profileRoutingStore
        let resourceMonitor = ResourceMonitor()
        self.resourceMonitor = resourceMonitor
        self.vpnManager = VPNManager(settings: settings, resourceMonitor: resourceMonitor)
        self.domainResolutionCoordinator = DomainResolutionCoordinator(ruleStore: destinationRuleStore)
        bindChildStores()
        domainResolutionCoordinator.start()

        // Load the selected profile's snapshot on first launch.
        lastKnownProfileID = profileStore.selectedProfileID
        loadedProfileID = profileStore.selectedProfileID
        applySnapshot(for: profileStore.selectedProfileID)
    }

    private func bindChildStores() {
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        profileStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        appDiscovery.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        appRuleStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        destinationRuleStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        vpnManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Sync destination routing file on rule/setting changes.
        destinationRuleStore.objectWillChange.merge(with: settings.objectWillChange)
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncDestinationRoutingFileWithPreferences()
            }
            .store(in: &cancellables)

        vpnManager.$stats
            .map(\.state)
            .removeDuplicates()
            .filter { $0 == .disconnected || $0 == .error }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.domainResolutionCoordinator.isConnected = false
                // Re-apply the selected profile's snapshot now that the tunnel is idle so the
                // destination-routing.json sync (skipped while the tunnel was active) runs
                // against the currently-selected profile.
                self?.applySnapshot(for: self?.profileStore.selectedProfileID)
            }
            .store(in: &cancellables)

        vpnManager.$stats
            .map(\.state)
            .removeDuplicates()
            .filter { $0 == .connected }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.domainResolutionCoordinator.isConnected = true
                self?.domainResolutionCoordinator.resolveAll()
            }
            .store(in: &cancellables)

        resourceMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Save current snapshot (debounced) whenever per-profile settings change.
        appRuleStore.objectWillChange
            .merge(with: destinationRuleStore.objectWillChange)
            .merge(with: settings.$routingMode.dropFirst().map { _ in () }.eraseToAnyPublisher())
            .merge(with: settings.$enforceDestinationFiltering.dropFirst().map { _ in () }.eraseToAnyPublisher())
            .merge(with: settings.$destinationBulkListsEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher())
            .merge(with: settings.$destinationCustomRangesEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher())
            .merge(with: settings.$destinationDomainNamesEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.saveCurrentSnapshot()
            }
            .store(in: &cancellables)

        // On profile selection change: flush outgoing snapshot synchronously, then apply new.
        profileStore.$selectedProfileID
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newID in
                guard let self else { return }
                if let outgoingID = lastKnownProfileID, outgoingID == loadedProfileID {
                    saveSnapshot(for: outgoingID)
                }
                lastKnownProfileID = newID
                applySnapshot(for: newID)
            }
            .store(in: &cancellables)

        // Clean up routing snapshot when a profile is deleted.
        profileStore.onProfileDeleted = { [weak self] id in
            guard let self else { return }
            profileRoutingStore.delete(for: id)
            if lastKnownProfileID == id {
                lastKnownProfileID = profileStore.selectedProfileID
            }
            if loadedProfileID == id {
                loadedProfileID = profileStore.selectedProfileID
            }
        }
    }

    /// Applies the stored routing snapshot for `profileID` to the live stores. While a
    /// tunnel is active we still install the snapshot (the UI must show the selected
    /// profile's config), but we skip the direct `destination-routing.json` write that
    /// would otherwise hand a *different* profile's rules to the running proxy. The
    /// disconnect sink re-runs the sync once the tunnel is idle.
    ///
    /// Indirect sync writes (via the debounced publisher in `bindChildStores`) are gated
    /// separately by `syncDestinationRoutingFileWithPreferences`, which blocks writes
    /// when the loaded profile differs from the currently-connected one — preventing the
    /// DNS-resolution-driven mutation here from leaking the new profile's destinations
    /// into the running extension.
    func applySnapshot(for profileID: UUID?) {
        guard let profileID else { return }
        installRoutingSnapshot(
            profileRoutingStore.snapshot(for: profileID),
            for: profileID,
            syncDestinationRouting: !isTunnelActive
        )
    }

    /// Loads the snapshot for the profile about to be connected into the live stores,
    /// even if a tunnel is still active. Skips `destination-routing.json` — `connect()`
    /// writes the authoritative routing payload for the new session.
    func prepareLiveRoutingForConnect(profileID: UUID) {
        installRoutingSnapshot(profileRoutingStore.snapshot(for: profileID), for: profileID, syncDestinationRouting: false)
    }

    private func installRoutingSnapshot(_ snapshot: ProfileRoutingSnapshot, for profileID: UUID, syncDestinationRouting: Bool) {
        loadedProfileID = profileID
        settings.routingMode = snapshot.routingMode
        appRuleStore.replaceAll(snapshot.appRules)
        destinationRuleStore.replaceAll(
            customRules: snapshot.customCidrRules,
            bulkGroups: snapshot.bulkGroups,
            domainRules: snapshot.domainRules
        )
        settings.enforceDestinationFiltering = snapshot.enforceDestinationFiltering
        settings.destinationBulkListsEnabled = snapshot.bulkListsEnabled
        settings.destinationCustomRangesEnabled = snapshot.customRangesEnabled
        settings.destinationDomainNamesEnabled = snapshot.domainNamesEnabled
        domainResolutionCoordinator.resolveAll()
        if syncDestinationRouting {
            syncDestinationRoutingFileWithPreferences()
        }
    }

    /// Persists current live state as the snapshot for the profile currently loaded in the live stores.
    /// Uses `loadedProfileID` rather than `selectedProfileID` because those can diverge briefly
    /// during `connectProfile` (live stores are swapped to the new profile before the selection
    /// publisher fires) — saves must follow the data in memory, not the not-yet-applied selection.
    func saveCurrentSnapshot() {
        guard let profileID = loadedProfileID else { return }
        saveSnapshot(for: profileID)
    }

    private func saveSnapshot(for profileID: UUID) {
        let bulkListsEnabled = settings.destinationBulkListsEnabled
        let customRangesEnabled = settings.destinationCustomRangesEnabled
        let domainNamesEnabled = settings.destinationDomainNamesEnabled
        let hasEffectiveDestinations =
            (customRangesEnabled && destinationRuleStore.customRules.contains(where: \.isEnabled))
            || (bulkListsEnabled && destinationRuleStore.bulkGroups.contains(where: \.isEnabled))
            || (domainNamesEnabled && destinationRuleStore.domainRules.contains(where: \.isEnabled))
        // Never persist enforceDestinationFiltering=true with an empty effective CIDR set —
        // that would silently activate filtering against an empty list on the next connect.
        let enforceFiltering = settings.enforceDestinationFiltering && hasEffectiveDestinations
        let snapshot = ProfileRoutingSnapshot(
            routingMode: settings.routingMode,
            enforceDestinationFiltering: enforceFiltering,
            bulkListsEnabled: bulkListsEnabled,
            customRangesEnabled: customRangesEnabled,
            domainNamesEnabled: domainNamesEnabled,
            appRules: appRuleStore.rules,
            customCidrRules: destinationRuleStore.customRules,
            bulkGroups: destinationRuleStore.bulkGroups,
            domainRules: destinationRuleStore.domainRules
        )
        profileRoutingStore.save(snapshot: snapshot, for: profileID)
    }

    /// Resolves all enabled domain rules before connecting so the routing file is fully
    /// populated when the proxy extension reads it. A second pass fires automatically
    /// after the tunnel comes up (via the connected-state observer in bindChildStores).
    func connectProfile(_ profile: WireGuardProfile) async {
        await vpnManager.runUserConnectSequence {
            // Flush the outgoing profile's in-memory edits BEFORE disconnectAndWait().
            // Two reasons this must happen first:
            //   1. The 500ms-debounced save publisher may not have fired yet for recent edits.
            //   2. `disconnectAndWait()` awaits; during that suspension the $stats.disconnected
            //      sink (which hops through DispatchQueue.main) runs `applySnapshot(for: selectedProfileID)`,
            //      which calls `replaceAll(...)` on the live stores using the on-disk snapshot.
            //      If we flushed *after* disconnectAndWait, the sink would overwrite in-flight
            //      edits with stale disk state and then our save would persist the staleness.
            // Flushing here closes the window because saveSnapshot is synchronous and runs
            // while loadedProfileID still points at the outgoing profile.
            saveCurrentSnapshot()
            await vpnManager.disconnectAndWait()
            profileStore.select(id: profile.id)
            prepareLiveRoutingForConnect(profileID: profile.id)
            domainResolutionCoordinator.cancelInFlight()
            await domainResolutionCoordinator.resolveAllAndWait()
            await vpnManager.connect(
                profile: profile,
                rules: appRuleStore.rules,
                destinationCidrStrings: destinationRuleStore.enabledFlattenedCidrs(
                    customRangesEnabled: settings.destinationCustomRangesEnabled,
                    bulkListsEnabled: settings.destinationBulkListsEnabled,
                    domainNamesEnabled: settings.destinationDomainNamesEnabled
                )
            )
        }
    }

    func connectSelectedProfile() async {
        guard let profile = profileStore.selectedProfile else { return }
        await connectProfile(profile)
    }

    /// Deletes all profiles, app rules, destination rules, routing snapshots, and resets
    /// general settings to their defaults. The VPN must be disconnected before calling.
    func resetAll() {
        let idsToDelete = profileStore.profiles.map(\.id)
        for id in idsToDelete {
            profileStore.delete(id: id)
        }
        appRuleStore.replaceAll([])
        destinationRuleStore.replaceAll(customRules: [], bulkGroups: [], domainRules: [])
        settings.routingMode = .fullTunnel
        settings.enforceDestinationFiltering = false
        settings.destinationBulkListsEnabled = true
        settings.destinationCustomRangesEnabled = true
        settings.destinationDomainNamesEnabled = true
        settings.autoReconnect = true
        settings.launchAtLogin = false
        settings.showTrafficRates = true
        settings.diagnosticsLevel = "info"
        settings.runTunnelConnectivityProbe = true
        settings.includeHostAppInPerAppRulesForProbe = true
        try? LaunchAtLoginService.setEnabled(false)
        syncDestinationRoutingFileWithPreferences()
    }

    /// Writes `destination-routing.json` to match Routing settings + rules (tunnel up or down).
    /// Skipped in three cases:
    ///   1. A connect/disconnect is in progress (`isBusy`) — `connect()` writes the
    ///      authoritative payload at the end of the sequence, and a racing write here would
    ///      either be clobbered or clobber it.
    ///   2. A split-tunnel profile is active — `connect()` already wrote the authoritative
    ///      AllowedIPs-based filter for split-tunnel, and rewriting it with generic
    ///      preference values would break per-app routing.
    ///   3. A tunnel is up for a profile that is **not** the currently-loaded profile in the
    ///      live stores — writing the loaded profile's destinations into the running
    ///      extension would produce a "hybrid policy" (new-profile CIDRs against
    ///      old-profile AllowedIPs / app rules). This blocks the picker-switch-while-
    ///      connected case while still allowing user edits to the currently-connected
    ///      profile to propagate.
    func syncDestinationRoutingFileWithPreferences() {
        guard !vpnManager.isBusy, !vpnManager.stats.perAppSplitTunnelActive else { return }
        if isTunnelActive,
           let connectedID = vpnManager.stats.connectedProfileID,
           let loadedID = loadedProfileID,
           connectedID != loadedID {
            return
        }
        vpnManager.syncDestinationRoutingFromHostActivity(
            enforceFiltering: settings.enforceDestinationFiltering,
            flattenedRangeStrings: destinationRuleStore.enabledFlattenedCidrs(
                customRangesEnabled: settings.destinationCustomRangesEnabled,
                bulkListsEnabled: settings.destinationBulkListsEnabled,
                domainNamesEnabled: settings.destinationDomainNamesEnabled
            )
        )
    }

    /// Whether the VPN is in any active phase (including transitions). Used by routing
    /// gates so they treat connecting/disconnecting transitions the same as connected.
    private var isTunnelActive: Bool {
        switch vpnManager.stats.state {
        case .connected, .connecting, .reconnecting, .disconnecting: return true
        case .disconnected, .error: return false
        }
    }

    /// True when the profile whose snapshot is in the live stores is the one currently
    /// running in the extension. Compares `loadedProfileID` (not `selectedProfileID`)
    /// because the live stores are the source of truth for what the UI shows; the two
    /// can diverge briefly inside `connectProfile()` before the selection publisher fires.
    var isViewingConnectedProfile: Bool {
        guard isTunnelActive,
              let loadedID = loadedProfileID,
              let connectedID = vpnManager.stats.connectedProfileID else {
            return false
        }
        return loadedID == connectedID
    }
}

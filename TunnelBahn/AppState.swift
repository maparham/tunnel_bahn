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
                // Selection may have changed while the tunnel was active; `applySnapshot` was
                // skipped then so live stores still matched the previous profile. Reload the
                // selected profile's snapshot now that the tunnel is idle.
                self?.applySnapshot(for: self?.profileStore.selectedProfileID)
                self?.syncDestinationRoutingFileWithPreferences()
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
                // Save under the outgoing profile ID (captured before the switch).
                if let outgoingID = lastKnownProfileID {
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
        }
    }

    /// Applies the stored routing snapshot for `profileID` to the live stores.
    func applySnapshot(for profileID: UUID?) {
        guard let profileID else { return }

        // Only update live state when the tunnel is not active. While connected the
        // extension owns the routing table; a mid-session replace can produce a hybrid
        // policy (new-profile rules + old-profile enable flags) and corrupt routing.
        let tunnelActive: Bool = {
            switch vpnManager.stats.state {
            case .connected, .connecting, .reconnecting, .disconnecting: return true
            case .disconnected, .error: return false
            }
        }()
        guard !tunnelActive else { return }

        installRoutingSnapshot(profileRoutingStore.snapshot(for: profileID), syncDestinationRouting: true)
    }

    /// Loads the snapshot for the profile about to be connected into the live stores,
    /// even if a tunnel is still active. Skips `destination-routing.json` — `connect()`
    /// writes the authoritative routing payload for the new session.
    func prepareLiveRoutingForConnect(profileID: UUID) {
        installRoutingSnapshot(profileRoutingStore.snapshot(for: profileID), syncDestinationRouting: false)
    }

    private func installRoutingSnapshot(_ snapshot: ProfileRoutingSnapshot, syncDestinationRouting: Bool) {
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

    /// Persists current live state as the snapshot for the selected profile.
    func saveCurrentSnapshot() {
        guard let profileID = profileStore.selectedProfileID else { return }
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
            await vpnManager.disconnectAndWait()
            profileStore.select(id: profile.id)
            prepareLiveRoutingForConnect(profileID: profile.id)
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
    /// Skipped while a connect is in progress or when a split-tunnel profile is active —
    /// `connect()` writes the authoritative AllowedIPs-based filter for split-tunnel profiles,
    /// and a concurrent write here would overwrite it with stale generic preference values.
    func syncDestinationRoutingFileWithPreferences() {
        guard !vpnManager.isBusy, !vpnManager.stats.perAppSplitTunnelActive else { return }
        vpnManager.syncDestinationRoutingFromHostActivity(
            enforceFiltering: settings.enforceDestinationFiltering,
            flattenedRangeStrings: destinationRuleStore.enabledFlattenedCidrs(
                customRangesEnabled: settings.destinationCustomRangesEnabled,
                bulkListsEnabled: settings.destinationBulkListsEnabled,
                domainNamesEnabled: settings.destinationDomainNamesEnabled
            )
        )
    }
}

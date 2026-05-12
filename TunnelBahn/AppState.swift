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
    @Published var diagnosticsText: String = "No diagnostics yet."

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
                self?.syncDestinationRoutingFileWithPreferences()
                self?.domainResolutionCoordinator.isConnected = false
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
        let snapshot = profileRoutingStore.snapshot(for: profileID)
        settings.routingMode = snapshot.routingMode
        settings.enforceDestinationFiltering = snapshot.enforceDestinationFiltering
        appRuleStore.replaceAll(snapshot.appRules)
        destinationRuleStore.replaceAll(
            customRules: snapshot.customCidrRules,
            bulkGroups: snapshot.bulkGroups,
            domainRules: snapshot.domainRules
        )
        domainResolutionCoordinator.resolveAll()
        syncDestinationRoutingFileWithPreferences()
    }

    /// Persists current live state as the snapshot for the selected profile.
    func saveCurrentSnapshot() {
        guard let profileID = profileStore.selectedProfileID else { return }
        saveSnapshot(for: profileID)
    }

    private func saveSnapshot(for profileID: UUID) {
        let snapshot = ProfileRoutingSnapshot(
            routingMode: settings.routingMode,
            enforceDestinationFiltering: settings.enforceDestinationFiltering,
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
    func connectSelectedProfile(rules: [AppRule]) async {
        guard let profile = profileStore.selectedProfile else { return }
        await domainResolutionCoordinator.resolveAllAndWait()
        await vpnManager.connect(
            profile: profile,
            rules: rules,
            destinationCidrStrings: destinationRuleStore.enabledFlattenedCidrs()
        )
    }

    /// Writes `destination-routing.json` to match Routing settings + rules (tunnel up or down).
    /// Skipped while a connect is in progress or when a split-tunnel profile is active —
    /// `connect()` writes the authoritative AllowedIPs-based filter for split-tunnel profiles,
    /// and a concurrent write here would overwrite it with stale generic preference values.
    func syncDestinationRoutingFileWithPreferences() {
        guard !vpnManager.isBusy, !vpnManager.stats.perAppSplitTunnelActive else { return }
        vpnManager.syncDestinationRoutingFromHostActivity(
            enforceFiltering: settings.enforceDestinationFiltering,
            flattenedRangeStrings: destinationRuleStore.enabledFlattenedCidrs()
        )
    }
}

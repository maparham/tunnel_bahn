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
        bindChildStores()

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
        destinationRuleStore.replaceAll(customRules: snapshot.customCidrRules, bulkGroups: snapshot.bulkGroups)
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
            bulkGroups: destinationRuleStore.bulkGroups
        )
        profileRoutingStore.save(snapshot: snapshot, for: profileID)
    }

    /// Writes `destination-routing.json` to match Routing settings + rules (tunnel up or down).
    func syncDestinationRoutingFileWithPreferences() {
        vpnManager.syncDestinationRoutingFromHostActivity(
            enforceFiltering: settings.enforceDestinationFiltering,
            flattenedRangeStrings: destinationRuleStore.enabledFlattenedCidrs()
        )
    }
}

import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    var settings: AppSettings
    var profileStore: ProfileStore
    var appDiscovery: AppDiscoveryService
    var appRuleStore: AppRuleStore
    var destinationRuleStore: DestinationRuleStore
    var resourceMonitor: ResourceMonitor
    var vpnManager: VPNManager
    private var cancellables: Set<AnyCancellable> = []

    @Published var selectedTab: Int = 0
    @Published var diagnosticsText: String = "No diagnostics yet."

    init() {
        let settings = AppSettings()
        let profileStore = ProfileStore()
        let appDiscovery = AppDiscoveryService()
        let appRuleStore = AppRuleStore()
        let destinationRuleStore = DestinationRuleStore()

        self.settings = settings
        self.profileStore = profileStore
        self.appDiscovery = appDiscovery
        self.appRuleStore = appRuleStore
        self.destinationRuleStore = destinationRuleStore
        let resourceMonitor = ResourceMonitor()
        self.resourceMonitor = resourceMonitor
        self.vpnManager = VPNManager(settings: settings, resourceMonitor: resourceMonitor)
        bindChildStores()
    }

    private func bindChildStores() {
        settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        profileStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        appDiscovery.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        appRuleStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        destinationRuleStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        vpnManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

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
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Writes `destination-routing.json` to match Routing settings + rules (tunnel up or down).
    func syncDestinationRoutingFileWithPreferences() {
        vpnManager.syncDestinationRoutingFromHostActivity(
            enforceFiltering: settings.enforceDestinationFiltering,
            flattenedRangeStrings: destinationRuleStore.enabledFlattenedCidrs()
        )
    }
}

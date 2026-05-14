import Foundation

@MainActor
final class AppSettings: ObservableObject {
    enum RoutingMode: String, CaseIterable, Codable {
        case fullTunnel = "full_tunnel"
        case appTunnel = "app_tunnel"
    }

    @Published var autoReconnect: Bool {
        didSet { save() }
    }

    @Published var launchAtLogin: Bool {
        didSet { save() }
    }

    /// Set by AppState when a profile is selected; not persisted independently.
    @Published var routingMode: RoutingMode = .fullTunnel

    /// One-time initialization guard for app-tunnel mode defaults (select all apps).
    @Published var perAppDefaultsInitialized: Bool {
        didSet { save() }
    }

    @Published var diagnosticsLevel: String {
        didSet { save() }
    }

    /// After connect, wait for NEVPNStatus.connected then run HTTPS/DNS probes (log prefix `APPSPLIT_PROBE`).
    @Published var runTunnelConnectivityProbe: Bool {
        didSet { save() }
    }

    /// Merge the host app into `NEAppRule` so TunnelBahn-initiated probes use the tunnel under app-tunnel VPN.
    @Published var includeHostAppInPerAppRulesForProbe: Bool {
        didSet { save() }
    }

    /// Set by AppState when a profile is selected; not persisted independently.
    @Published var enforceDestinationFiltering: Bool = false

    @Published var showTrafficRates: Bool {
        didSet { save() }
    }

    /// Set by AppState when a profile is selected; not persisted independently.
    @Published var destinationBulkListsEnabled: Bool = true

    /// Set by AppState when a profile is selected; not persisted independently.
    @Published var destinationCustomRangesEnabled: Bool = true

    /// Set by AppState when a profile is selected; not persisted independently.
    @Published var destinationDomainNamesEnabled: Bool = true

    private enum Keys {
        static let autoReconnect = "autoReconnect"
        static let launchAtLogin = "launchAtLogin"
        static let perAppDefaultsInitialized = "perAppDefaultsInitialized"
        static let diagnosticsLevel = "diagnosticsLevel"
        static let runTunnelConnectivityProbe = "runTunnelConnectivityProbe"
        static let includeHostAppInPerAppRulesForProbe = "includeHostAppInPerAppRulesForProbe"
        static let showTrafficRates = "showTrafficRates"
    }

    init() {
        autoReconnect = AppGroupStore.defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
        launchAtLogin = AppGroupStore.defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        perAppDefaultsInitialized = AppGroupStore.defaults.object(forKey: Keys.perAppDefaultsInitialized) as? Bool ?? false
        diagnosticsLevel = AppGroupStore.defaults.string(forKey: Keys.diagnosticsLevel) ?? "info"
        runTunnelConnectivityProbe = AppGroupStore.defaults.object(forKey: Keys.runTunnelConnectivityProbe) as? Bool ?? true
        includeHostAppInPerAppRulesForProbe =
            AppGroupStore.defaults.object(forKey: Keys.includeHostAppInPerAppRulesForProbe) as? Bool ?? true
        if let migrated = AppGroupStore.defaults.object(forKey: Keys.showTrafficRates) as? Bool {
            showTrafficRates = migrated
        } else if let legacy = UserDefaults.standard.object(forKey: Keys.showTrafficRates) as? Bool {
            showTrafficRates = legacy
            AppGroupStore.defaults.set(legacy, forKey: Keys.showTrafficRates)
            UserDefaults.standard.removeObject(forKey: Keys.showTrafficRates)
        } else {
            showTrafficRates = true
        }
    }

    private func save() {
        AppGroupStore.defaults.set(autoReconnect, forKey: Keys.autoReconnect)
        AppGroupStore.defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        AppGroupStore.defaults.set(perAppDefaultsInitialized, forKey: Keys.perAppDefaultsInitialized)
        AppGroupStore.defaults.set(diagnosticsLevel, forKey: Keys.diagnosticsLevel)
        AppGroupStore.defaults.set(runTunnelConnectivityProbe, forKey: Keys.runTunnelConnectivityProbe)
        AppGroupStore.defaults.set(includeHostAppInPerAppRulesForProbe, forKey: Keys.includeHostAppInPerAppRulesForProbe)
        AppGroupStore.defaults.set(showTrafficRates, forKey: Keys.showTrafficRates)
    }
}

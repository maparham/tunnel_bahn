import Foundation

@MainActor
final class AppSettings: ObservableObject {
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

    /// Set by AppState when a profile is selected; not persisted independently.
    @Published var destinationFilterMode: DestinationFilterMode = .include

    /// Profile-wide: when true, routed apps' DNS is not redirected to the tunnel
    /// resolver. Set by AppState when a profile is selected; not persisted independently.
    @Published var resolveDNSLocally: Bool = false

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
        showTrafficRates = AppGroupStore.defaults.object(forKey: Keys.showTrafficRates) as? Bool ?? true
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

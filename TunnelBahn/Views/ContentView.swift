import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: Tab = .profiles

    enum Tab: String, CaseIterable {
        case profiles = "Profiles"
        case apps = "Apps"
        case status = "Status"
        case diagnostics = "Diagnostics"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .profiles: "doc.badge.plus"
            case .apps: "square.grid.2x2"
            case .status: "network"
            case .diagnostics: "ladybug"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case .profiles:
                ProfilesView(
                    profileStore: appState.profileStore,
                    vpnManager: appState.vpnManager,
                    settings: appState.settings,
                    appRuleStore: appState.appRuleStore
                )
            case .apps: AppsView()
            case .status: StatusView()
            case .diagnostics: DiagnosticsView()
            case .settings: SettingsView()
            }
        }
    }
}

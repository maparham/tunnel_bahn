import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: Tab = .profiles

    enum Tab: String, CaseIterable {
        case profiles = "Profiles"
        case status = "Monitoring"
        case speedTest = "Speed Test"
        case logs = "Logs"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .profiles: "doc.badge.plus"
            case .status: "network"
            case .speedTest: "gauge.with.needle"
            case .logs: "doc.text.magnifyingglass"
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
            #if DEBUG
            // Dev-only build stamp: helps confirm the running app matches the
            // current source. Hidden in release builds shipped to end users.
            .safeAreaInset(edge: .bottom) {
                BuildStampView()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            #endif
        } detail: {
            switch selectedTab {
            case .profiles:
                ProfilesView(
                    profileStore: appState.profileStore,
                    vpnManager: appState.vpnManager,
                    settings: appState.settings,
                    appRuleStore: appState.appRuleStore,
                    destinationRuleStore: appState.destinationRuleStore
                )
            case .status: StatusView()
            case .speedTest: SpeedTestView(service: appState.speedTestService)
            case .logs: LogsView(store: appState.logCaptureStore)
            case .settings: SettingsView()
            }
        }
    }
}

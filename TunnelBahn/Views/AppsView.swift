import AppKit
import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var appState: AppState

    private var rulesLocked: Bool {
        switch appState.vpnManager.stats.state {
        case .connected, .connecting, .reconnecting, .disconnecting:
            return true
        case .disconnected, .error:
            return false
        }
    }

    private var selectedAppRules: [AppRule] {
        appState.appRuleStore.rules
            .filter { $0.action == .routeVPN }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedCount: Int {
        selectedAppRules.count
    }

    private var canEnableAppTunnelMode: Bool {
        AppConstants.isPerAppSplitTunnelEnabled && selectedCount > 0
    }

    private var routingModeBinding: Binding<AppSettings.RoutingMode> {
        Binding(
            get: { appState.settings.routingMode },
            set: { newMode in
                if newMode == .appTunnel, !canEnableAppTunnelMode { return }
                appState.settings.routingMode = newMode
            }
        )
    }

    private static let tunnelAllAppsTooltip =
        "All network traffic from every app is routed through the VPN."

    private static let tunnelSelectedAppsTooltip =
        "Only the apps you select are routed through the VPN. Everything else goes directly to the internet."

    private static let appTunnelWarningTooltip =
        "This mode only protects selected apps. All other apps connect directly to the internet. This can expose your real IP address and DNS queries to third parties."

    private static func attributed(_ string: String, bold: [String]) -> AttributedString {
        var result = AttributedString(string)
        for word in bold {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: word) {
                result[range].font = .callout.bold()
                searchStart = range.upperBound
            }
        }
        return result
    }

    /// Apps shown in "All Apps"; excludes any already in the selected (VPN) list.
    private var discoverableAppsExcludingSelected: [DiscoveredApp] {
        appState.appDiscovery.filteredApps.filter { !isSelected($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        RadioButton(
                            isOn: appState.settings.routingMode == .fullTunnel,
                            label: "Tunnel all apps",
                            disabled: rulesLocked
                        ) { routingModeBinding.wrappedValue = .fullTunnel }
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.tunnelAllAppsTooltip)
                    }
                    HStack(spacing: 6) {
                        RadioButton(
                            isOn: appState.settings.routingMode == .appTunnel,
                            label: "Tunnel selected apps",
                            disabled: rulesLocked || !canEnableAppTunnelMode
                        ) { routingModeBinding.wrappedValue = .appTunnel }
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.tunnelSelectedAppsTooltip)
                    }
                }

                Spacer()

                Button("Refresh App List") {
                    appState.appDiscovery.refresh()
                }
            }

            if !AppConstants.isPerAppSplitTunnelEnabled {
                Text(
                    "App-tunnel routing is off in this build: every connect is a full tunnel (all apps). The list below is ignored until split tunnel is re-enabled in code."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if rulesLocked {
                Text("Disconnect the VPN to edit app routing rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if AppConstants.isPerAppSplitTunnelEnabled {
                let isAppTunnel = appState.settings.routingMode == .appTunnel
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        GroupBox("Running Apps") {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Search applications", text: $appState.appDiscovery.searchText)
                                    .textFieldStyle(.roundedBorder)

                                List(discoverableAppsExcludingSelected) { app in
                                    HStack(spacing: 12) {
                                        Image(nsImage: app.icon)
                                            .resizable()
                                            .frame(width: 24, height: 24)
                                        VStack(alignment: .leading) {
                                            Text(app.displayName)
                                                .font(.headline)
                                            Text(app.bundleIdentifier)
                                                .foregroundStyle(.secondary)
                                                .font(.caption)
                                        }
                                        Spacer()
                                        Button {
                                            addSelectedApp(app)
                                        } label: {
                                            Image(systemName: "plus.circle")
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(rulesLocked)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .frame(minHeight: 180)

                                Button("Add App…") {
                                    Task {
                                        if let app = await appState.appDiscovery.pickAndRegisterApp() {
                                            appState.appRuleStore.setRule(for: app, action: .routeVPN)
                                        }
                                    }
                                }
                                .disabled(rulesLocked)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 10) {
                        GroupBox {
                            if selectedAppRules.isEmpty {
                                Label("Add at least one app to enable this mode.", systemImage: "info.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                List(selectedAppRules, id: \.appPath) { rule in
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading) {
                                            Text(rule.displayName)
                                                .font(.headline)
                                            Text(rule.bundleIdentifier)
                                                .foregroundStyle(.secondary)
                                                .font(.caption)
                                        }
                                        Spacer()
                                        Button {
                                            removeSelectedApp(rule)
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(rulesLocked)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .frame(minHeight: 140)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("Selected Apps")
                                    .foregroundStyle(isAppTunnel ? Color.accentColor : Color.secondary)
                                if isAppTunnel {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                        .instantTooltip(Self.appTunnelWarningTooltip)
                                }
                            }
                        }
                        .opacity(isAppTunnel ? 1 : 0.5)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            // Populate the list on first open.
            if appState.appDiscovery.apps.isEmpty {
                appState.appDiscovery.refresh()
            }
            // Handle invalid state: app-tunnel mode with zero selected apps
            autoSwitchToFullTunnelIfNoSelection()
        }
        .onChange(of: selectedCount) { _, newValue in
            if newValue == 0 {
                autoSwitchToFullTunnelIfNoSelection()
            }
        }
    }

    private func isSelected(_ app: DiscoveredApp) -> Bool {
        appState.appRuleStore.action(for: app.appPath) == .routeVPN
    }

    private func addSelectedApp(_ app: DiscoveredApp) {
        appState.appRuleStore.setRule(for: app, action: .routeVPN)
    }

    private func removeSelectedApp(_ rule: AppRule) {
        let app = DiscoveredApp(
            displayName: rule.displayName,
            bundleIdentifier: rule.bundleIdentifier,
            appPath: rule.appPath,
            icon: NSWorkspace.shared.icon(forFile: rule.appPath)
        )
        appState.appRuleStore.setRule(for: app, action: .bypass)
        autoSwitchToFullTunnelIfNoSelection()
    }

    private func autoSwitchToFullTunnelIfNoSelection() {
        guard AppConstants.isPerAppSplitTunnelEnabled else { return }
        guard appState.settings.routingMode == .appTunnel else { return }
        guard !rulesLocked else { return }

        if selectedCount == 0 {
            appState.settings.routingMode = .fullTunnel
        }
    }
}


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

    private var routingModeSelection: Binding<AppSettings.RoutingMode> {
        Binding(
            get: { appState.settings.routingMode },
            set: { newValue in
                if newValue == .appTunnel, !canEnableAppTunnelMode { return }
                appState.settings.routingMode = newValue
            }
        )
    }

    private var appTunnelRadioLabel: String {
        if canEnableAppTunnelMode {
            return "Tunnel selected apps only"
        }
        if AppConstants.isPerAppSplitTunnelEnabled {
            return "Tunnel selected apps only (select at least one app)"
        }
        return "Tunnel selected apps only"
    }

    /// Apps shown in “All Apps”; excludes any already in the selected (VPN) list.
    private var discoverableAppsExcludingSelected: [DiscoveredApp] {
        appState.appDiscovery.filteredApps.filter { !isSelected($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Routing Mode")
                    .font(.title2.bold())
                Spacer()
                Button("Refresh App List") {
                    appState.appDiscovery.refresh()
                }
            }

            if !AppConstants.isPerAppSplitTunnelEnabled {
                Picker("Mode", selection: routingModeSelection) {
                    Text("Full Tunnel (all apps)").tag(AppSettings.RoutingMode.fullTunnel)
                    Text(appTunnelRadioLabel).tag(AppSettings.RoutingMode.appTunnel)
                        .disabled(!canEnableAppTunnelMode)
                }
                .pickerStyle(.radioGroup)
                .disabled(rulesLocked)
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
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        routingModeRadioRow(
                            mode: .fullTunnel,
                            label: "Full Tunnel (all apps)",
                            rowDisabled: false
                        )
                        GroupBox("All Apps") {
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
                                .frame(minHeight: 220)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 10) {
                        routingModeRadioRow(
                            mode: .appTunnel,
                            label: appTunnelRadioLabel,
                            rowDisabled: !canEnableAppTunnelMode
                        )
                        GroupBox("Selected Apps") {
                            if selectedAppRules.isEmpty {
                                Text("No apps selected.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                        }
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

    @ViewBuilder
    private func routingModeRadioRow(mode: AppSettings.RoutingMode, label: String, rowDisabled: Bool) -> some View {
        let selected = appState.settings.routingMode == mode
        let effectiveDisabled = rulesLocked || rowDisabled

        Button {
            guard !effectiveDisabled else { return }
            routingModeSelection.wrappedValue = mode
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "smallcircle.filled.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(effectiveDisabled ? .secondary : .primary)
                Text(label)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(effectiveDisabled ? .secondary : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(effectiveDisabled)
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

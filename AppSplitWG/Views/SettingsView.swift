import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var launchError: String?

    private var rulesLocked: Bool {
        appState.vpnManager.stats.state != .disconnected
    }

    var body: some View {
        Form {
            Section("Connectivity") {
                Toggle("Auto reconnect", isOn: $appState.settings.autoReconnect)
                Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
                    .onChange(of: appState.settings.launchAtLogin) { _, newValue in
                        do {
                            try LaunchAtLoginService.setEnabled(newValue)
                        } catch {
                            launchError = error.localizedDescription
                        }
                    }
            }

            Section("Diagnostics") {
                Picker("Log Level", selection: $appState.settings.diagnosticsLevel) {
                    Text("Error").tag("error")
                    Text("Info").tag("info")
                    Text("Debug").tag("debug")
                }
                Toggle(
                    "Tunnel connectivity probe after connect",
                    isOn: $appState.settings.runTunnelConnectivityProbe
                )
                Toggle(
                    "Include AppSplit WG in per-app rules (for probe)",
                    isOn: $appState.settings.includeHostAppInPerAppRulesForProbe
                )
                .disabled(!AppConstants.isPerAppSplitTunnelEnabled)
                Text(
                    "When connected, waits for NEVPNStatus.connected, refreshes public IP, then runs HTTPS/DNS checks. Log grep: APPSPLIT_PROBE. Phase full_tunnel vs per_app_host_included vs per_app_host_excluded shows whether the host app is allowed to use the tunnel under per-app VPN."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Security") {
                Label("Private keys are stored in Keychain only.", systemImage: "key.fill")
                Label("Profiles and app rules are stored in app group container.", systemImage: "folder.badge.gearshape")
            }
        }
        .padding()
        .alert("Launch At Login Error", isPresented: .constant(launchError != nil), actions: {
            Button("OK") { launchError = nil }
        }, message: {
            Text(launchError ?? "Unknown error")
        })
    }
}

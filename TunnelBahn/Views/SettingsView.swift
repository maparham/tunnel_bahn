import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var launchError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsSection("General") {
                    Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
                        .onChange(of: appState.settings.launchAtLogin) { _, newValue in
                            do {
                                try LaunchAtLoginService.setEnabled(newValue)
                            } catch {
                                launchError = error.localizedDescription
                            }
                        }
                    Toggle("Auto reconnect", isOn: $appState.settings.autoReconnect)
                    Toggle("Show traffic rates in menu bar", isOn: $appState.settings.showTrafficRates)
                }

                settingsSection("Diagnostics") {
                    HStack(spacing: 10) {
                        Text("Log level")
                        Picker("", selection: $appState.settings.diagnosticsLevel) {
                            Text("Error").tag("error")
                            Text("Info").tag("info")
                            Text("Debug").tag("debug")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Toggle(
                        "Run connectivity check after connect",
                        isOn: $appState.settings.runTunnelConnectivityProbe
                    )
                    .help("After the VPN connects, automatically checks that the tunnel is working by verifying your public IP and making a test HTTPS/DNS request.")
                    Toggle(
                        "Route this app through the VPN during the check",
                        isOn: $appState.settings.includeHostAppInPerAppRulesForProbe
                    )
                    .disabled(!AppConstants.isPerAppSplitTunnelEnabled)
                    .help("When using per-app VPN rules, TunnelBahn itself is normally excluded from the tunnel. Turn this on to route TunnelBahn through the VPN while the connectivity check runs, so the check tests the tunnel directly.")
                }

                Spacer()
            }
            .padding(20)
        }
        .alert("Launch At Login Error", isPresented: .constant(launchError != nil), actions: {
            Button("OK") { launchError = nil }
        }, message: {
            Text(launchError ?? "Unknown error")
        })
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.leading, 4)
        }
    }
}

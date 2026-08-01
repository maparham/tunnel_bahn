import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var launchError: String?
    @State private var backupMode: BackupMode? = nil
    @State private var backupError: String? = nil
    @State private var importSuccessSummary: String? = nil
    @State private var isResetConfirmationPresented = false
    private let backupService = BackupService()

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
                    Toggle(isOn: $appState.settings.runTunnelConnectivityProbe) {
                        HStack(spacing: 6) {
                            Text("Run connectivity check after connect")
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                                .instantTooltip("After connect, verifies the tunnel works via a public-IP check and a test HTTPS/DNS request.")
                        }
                    }
                }

                settingsSection("Backup & Restore") {
                    HStack(spacing: 10) {
                        Button("Export") { triggerExport() }
                        Button("Import") { triggerImport() }
                        Button("Reset") { isResetConfirmationPresented = true }
                            .foregroundStyle(.red)
                    }
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
        .alert("Backup Error", isPresented: .constant(backupError != nil), actions: {
            Button("OK") { backupError = nil }
        }, message: {
            Text(backupError ?? "Unknown error")
        })
        .alert("Import Complete", isPresented: .constant(importSuccessSummary != nil), actions: {
            Button("OK") { importSuccessSummary = nil }
        }, message: {
            Text(importSuccessSummary ?? "")
        })
        .alert("Reset All Settings?", isPresented: $isResetConfirmationPresented, actions: {
            Button("Reset Everything", role: .destructive) {
                appState.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        }, message: {
            Text("This will permanently delete all profiles, app routing rules, destination routing rules, and reset general settings to defaults. This cannot be undone.")
        })
        .sheet(item: $backupMode) { mode in
            BackupSheet(
                mode: mode,
                onComplete: { options, policy, url in
                    switch mode {
                    case .export:
                        performExport(options: options, destinationURL: url)
                    case .import:
                        performImport(mode: mode, options: options, policy: policy)
                    }
                    backupMode = nil
                },
                onCancel: { backupMode = nil }
            )
        }
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

    // MARK: - Backup / Restore

    private func triggerExport() {
        backupMode = .export
    }

    private func triggerImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import TunnelBahn Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let backup = try backupService.decode(from: data)
            backupMode = .import(backup: backup)
        } catch {
            backupError = error.localizedDescription
        }
    }

    private func performExport(options: BackupOptions, destinationURL: URL?) {
        guard let url = destinationURL else { return }
        do {
            let backup = try backupService.buildBackup(
                options: options,
                profileStore: appState.profileStore,
                profileRoutingStore: appState.profileRoutingStore,
                appSettings: appState.settings
            )
            let data = try backupService.encode(backup)
            try data.write(to: url, options: .atomic)
        } catch {
            backupError = error.localizedDescription
        }
    }

    private func performImport(mode: BackupMode, options: BackupOptions, policy: ProfileConflictPolicy) {
        guard case let .import(backup) = mode else { return }
        do {
            let summary = try backupService.applyBackup(
                backup,
                options: options,
                conflictPolicy: policy,
                profileStore: appState.profileStore,
                profileRoutingStore: appState.profileRoutingStore,
                appSettings: appState.settings
            )
            // Reload live stores so appRuleStore/destinationRuleStore/settings reflect the
            // imported snapshot for the currently-selected profile immediately.
            appState.applySnapshot(for: appState.profileStore.selectedProfileID)
            importSuccessSummary = summary.description
        } catch {
            backupError = error.localizedDescription
        }
    }
}

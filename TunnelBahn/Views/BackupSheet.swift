import SwiftUI
import AppKit

enum BackupMode: Identifiable {
    case export
    case `import`(backup: AppBackup)

    var id: String {
        switch self {
        case .export: "export"
        case .import: "import"
        }
    }
}

struct BackupSheet: View {
    let mode: BackupMode
    /// For export: called with (options, policy, destinationURL). destinationURL is non-nil.
    /// For import: called with (options, policy, nil).
    let onComplete: (BackupOptions, ProfileConflictPolicy, URL?) -> Void
    let onCancel: () -> Void

    @State private var includeSettings = true
    @State private var includeProfiles = true
    @State private var includeAppRouting = true
    @State private var includeDestinationRouting = true
    @State private var conflictPolicy: ProfileConflictPolicy = .replaceByName

    private var isExport: Bool {
        if case .export = mode { return true }
        return false
    }

    private var fileSummary: String? {
        guard case let .import(backup) = mode else { return nil }
        var parts: [String] = []
        if let profiles = backup.profiles {
            parts.append("\(profiles.count) profile\(profiles.count == 1 ? "" : "s")")
        }
        if backup.appSettings != nil { parts.append("general settings") }
        return parts.isEmpty ? "No data found in file" : "File contains: \(parts.joined(separator: ", "))"
    }

    private var currentOptions: BackupOptions {
        BackupOptions(
            includeSettings: includeSettings,
            includeProfiles: includeProfiles,
            includeAppRouting: includeAppRouting && includeProfiles,
            includeDestinationRouting: includeDestinationRouting && includeProfiles
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isExport ? "Export Backup" : "Import Backup")
                .font(.title3.bold())

            if let summary = fileSummary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox("What to include") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("General Settings", isOn: $includeSettings)

                    Toggle("Profiles", isOn: $includeProfiles)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("App routing rules", isOn: $includeAppRouting)
                            .disabled(!includeProfiles)
                        Toggle("Destination routing rules", isOn: $includeDestinationRouting)
                            .disabled(!includeProfiles)
                    }
                    .padding(.leading, 20)
                }
                .padding(4)
            }

            if !isExport {
                GroupBox("If a profile already exists") {
                    Picker("", selection: $conflictPolicy) {
                        Text("Replace existing").tag(ProfileConflictPolicy.replaceByName)
                        Text("Keep both").tag(ProfileConflictPolicy.keepBoth)
                        Text("Skip duplicate").tag(ProfileConflictPolicy.skip)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .padding(4)
                }
            }

            if isExport {
                Text("The exported file contains your WireGuard private keys. Keep it secure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("App access bookmarks are machine-specific and will not be restored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isExport ? "Export…" : "Import") {
                    if isExport {
                        // Run NSSavePanel while the sheet is still presented — no dismissal race.
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.json]
                        panel.nameFieldStringValue = "TunnelBahn-Backup-\(formatter.string(from: .now)).json"
                        panel.title = "Export TunnelBahn Backup"
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        onComplete(currentOptions, conflictPolicy, url)
                    } else {
                        onComplete(currentOptions, conflictPolicy, nil)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!includeSettings && !includeProfiles)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Editor fields shown when a profile's transport is `.ssh`. Mirrors the layout conventions of
/// `ProfileEditorSheet` (caption label above a rounded-border field). The private key is entered
/// either by importing a file or pasting PEM/OpenSSH text; it is written to the shared-access-group
/// Keychain by the parent on save (never persisted in the profile JSON). Host-key trust is
/// established via TOFU on first connect and is intentionally not surfaced here (Task 9).
struct SSHProfileEditorFields: View {
    @Binding var host: String
    @Binding var port: String
    @Binding var username: String
    /// PEM / OpenSSH private-key text. Empty when the user has not supplied a new key this session.
    @Binding var pastedKey: String

    /// True when the profile already has a private key stored in the Keychain (editing an existing
    /// SSH profile). Derived from the profile, not from runtime state — no-flicker rule.
    let hasStoredKey: Bool

    @State private var isImportingKey = false
    @State private var importError: String?

    private var looksLikeRSA: Bool {
        let text = pastedKey
        return text.contains("BEGIN RSA PRIVATE KEY") || text.contains("ssh-rsa")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("SSH Server") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Host")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("example.com or 203.0.113.5", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .instantTooltip("Hostname or IP address of the SSH server to tunnel through.")

                    Text("Port")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("22", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        .instantTooltip("TCP port of the SSH server. Defaults to 22.")

                    Text("Username")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("SSH login user", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .instantTooltip("The user account to authenticate as on the SSH server.")
                }
                .padding(.top, 4)
            }

            GroupBox("Private Key") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("Import Key File…") {
                            isImportingKey = true
                        }
                        .instantTooltip("Load an ed25519 or ECDSA private key file (e.g. id_ed25519).")

                        if hasStoredKey && pastedKey.isEmpty {
                            Label("A key is already stored", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Or paste the private key (ed25519 or ECDSA, PEM/OpenSSH format)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $pastedKey)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .instantTooltip("Leave blank when editing to keep the existing stored key.")

                    if looksLikeRSA {
                        Label(
                            "RSA keys are not supported. Use an ed25519 or ECDSA key.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    if let importError {
                        Text(importError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.top, 4)
            }
        }
        .fileImporter(
            isPresented: $isImportingKey,
            allowedContentTypes: [.data, .text, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        do {
            guard let url = try result.get().first else { return }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            let contents = try String(contentsOf: url, encoding: .utf8)
            pastedKey = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            importError = "Could not read key file: \(error.localizedDescription)"
        }
    }
}

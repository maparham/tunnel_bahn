import SwiftUI

/// Editor fields for the WireGuard TCP (WebSocket/TLS) wrapper sub-mode. Shown under the WG
/// Peer section when the wrapper toggle is on. Carries no secrets, so nothing is written to the
/// Keychain — the values persist in the profile JSON.
struct WireGuardTCPWrapperEditorFields: View {
    @Binding var enabled: Bool
    @Binding var serverHost: String
    @Binding var serverPort: String
    @Binding var tls: Bool
    @Binding var verifyCert: Bool
    @Binding var pathPrefix: String
    @Binding var forwardHost: String
    @Binding var forwardPort: String

    var body: some View {
        GroupBox("TCP Wrapper (WebSocket/TLS)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Carry WireGuard over a TCP WebSocket (for UDP-blocked networks)", isOn: $enabled)
                    .instantTooltip("Wraps WireGuard's UDP in a TLS WebSocket to a wstunnel server so it works where UDP is blocked.")

                if enabled {
                    Text("Server (host:port)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("server IP or hostname", text: $serverHost)
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Text(":").foregroundStyle(.secondary)
                        TextField("443", text: $serverPort)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 80)
                    }
                    .instantTooltip("Where the wrapper connects (the wstunnel server). Usually port 443.")

                    Toggle("Use TLS (wss)", isOn: $tls)
                        .instantTooltip("On = wss (TLS). Off = plaintext ws for a non-TLS server.")
                    Toggle("Verify server certificate", isOn: $verifyCert)
                        .instantTooltip("Off matches wstunnel and is required for bare-IP servers whose cert won't validate.")

                    Text("Secret path prefix").font(.caption).foregroundStyle(.secondary)
                    TextField("path prefix from your server", text: $pathPrefix)
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        .instantTooltip("The secret WebSocket path prefix the server routes on. Upgrade path is /<prefix>/events.")

                    Text("Server-side forward target (host:port)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("127.0.0.1", text: $forwardHost)
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Text(":").foregroundStyle(.secondary)
                        TextField("51840", text: $forwardPort)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 80)
                    }
                    .instantTooltip("The WireGuard listener behind the wstunnel server, usually 127.0.0.1:51840.")
                }
            }
            .padding(.top, 4)
        }
    }
}

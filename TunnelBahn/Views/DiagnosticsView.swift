import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var managerDiagnostics = ""
    @State private var extensionDiagnostics = ""
    @State private var isLoadingExtensionDiag = false
    @State private var verificationResults = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VPN Diagnostics")
                .font(.title2.bold())
            
            GroupBox("Manager Configuration") {
                ScrollView {
                    Text(managerDiagnostics.isEmpty ? "Click 'Refresh' to load diagnostics" : managerDiagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
                
                HStack {
                    Button("Refresh Manager Diagnostics") {
                        refreshManagerDiagnostics()
                    }
                    
                    Spacer()
                    
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(managerDiagnostics, forType: .string)
                    }
                    .disabled(managerDiagnostics.isEmpty)
                }
            }
            
            GroupBox("Extension Diagnostics") {
                ScrollView {
                    Text(extensionDiagnostics.isEmpty ? "Connect VPN then click 'Load Extension Diagnostics'" : extensionDiagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                
                HStack {
                    Button("Load Extension Diagnostics") {
                        loadExtensionDiagnostics()
                    }
                    .disabled(appState.vpnManager.stats.state != .connected || isLoadingExtensionDiag)
                    
                    Spacer()
                    
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(extensionDiagnostics, forType: .string)
                    }
                    .disabled(extensionDiagnostics.isEmpty)
                    
                    if isLoadingExtensionDiag {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
            
            GroupBox("App-Tunnel VPN Verification") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To verify app-tunnel split tunneling is working:")
                        .font(.headline)
                    
                    Text("""
                    1. Set "Unmatched apps" to "Bypass VPN" in Settings (required for app-tunnel split)
                    2. In Apps tab, toggle ONLY Firefox to "Route via VPN"
                    3. Connect to VPN
                    4. Check Manager Diagnostics shows:
                       - Routing Method: sourceApplication (app-tunnel VPN)
                       - On-Demand Enabled = true
                       - At least 1 App Rule for Firefox
                    5. Open Safari and visit: https://api.ipify.org
                       → Should show your ISP's public IP (bypassing VPN)
                    6. Open Firefox and visit: https://api.ipify.org
                       → Should show VPN server's public IP
                    7. Run Terminal command: curl https://api.ipify.org
                       → Should show your ISP's public IP (bypassing VPN)
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    
                    if !verificationResults.isEmpty {
                        Divider()
                        Text(verificationResults)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    
                    Button("Run Automated Verification") {
                        runVerification()
                    }
                    .disabled(appState.vpnManager.stats.state != .connected)
                }
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            refreshManagerDiagnostics()
        }
    }
    
    private func refreshManagerDiagnostics() {
        managerDiagnostics = appState.vpnManager.getManagerDiagnostics()
    }
    
    private func loadExtensionDiagnostics() {
        isLoadingExtensionDiag = true
        Task {
            extensionDiagnostics = await appState.vpnManager.loadDiagnostics()
            isLoadingExtensionDiag = false
        }
    }
    
    private func runVerification() {
        verificationResults = "Running verification...\n"
        
        Task {
            // Check manager configuration
            let diag = appState.vpnManager.getManagerDiagnostics()
            
            var results = "=== VERIFICATION RESULTS ===\n\n"
            
            // Parse diagnostics to match getManagerDiagnostics() output
            let hasCorrectRoutingMethod = diag.contains("sourceApplication (app-tunnel VPN)")
            let hasOnDemandEnabled = diag.contains("On-Demand Enabled: true")
            let hasNoAppRules = diag.contains("No app rules configured (full tunnel will route ALL traffic)") ||
                diag.contains("No app rules configured (app-tunnel VPN will route NO apps)")
            let hasAppRules = !hasNoAppRules
            
            results += "Manager Configuration:\n"
            results += "  \(hasCorrectRoutingMethod ? "✅" : "❌") Routing Method is sourceApplication\n"
            results += "  \(hasOnDemandEnabled ? "✅" : "❌") On-Demand is enabled\n"
            results += "  \(hasAppRules ? "✅" : "❌") App Rules are configured\n\n"
            
            if hasCorrectRoutingMethod && hasOnDemandEnabled && hasAppRules {
                results += "✅ Configuration looks correct for app-tunnel VPN!\n\n"
                results += "Next steps:\n"
                results += "1. Test with Safari (should bypass): https://api.ipify.org\n"
                results += "2. Test with Firefox (should use VPN): https://api.ipify.org\n"
                results += "3. Compare the IPs - they should be different!\n"
            } else {
                results += "❌ Configuration has issues. App-tunnel VPN may not work.\n\n"
                if !hasCorrectRoutingMethod {
                    results += "ACTION: Disconnect and reconnect to trigger migration.\n"
                }
                if !hasOnDemandEnabled {
                    results += "ACTION: This is a bug - On-Demand should be enabled.\n"
                }
                if !hasAppRules {
                    results += "ACTION: Add at least one app in the Apps tab.\n"
                }
            }
            
            verificationResults = results
        }
    }
}

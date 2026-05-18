import Foundation
import NetworkExtension
import OSLog

/// Manages the `NETransparentProxyManager` configuration that powers app-tunnel TX/RX
/// accounting. Lifecycle is bound to the packet tunnel's connection state by `VPNManager`.
///
/// Why a separate manager:
/// - The packet tunnel (`NETunnelProviderManager`) and the transparent proxy
///   (`NETransparentProxyManager`) are independent OS-managed configurations. Treating them
///   separately avoids accidentally tearing one down while configuring the other.
@MainActor
final class PerAppStatsProxyManager {
    private static let osLog = Logger(subsystem: "com.tunnelbahn.mac", category: "PerAppStatsProxy")

    static let extensionBundleIdentifier = "com.tunnelbahn.mac.transparentproxy"
    static let managerDescription = "TunnelBahn App-Tunnel Stats"

    private var manager: NETransparentProxyManager?

    /// True when the proxy is enabled and connected (or connecting). Best-effort signal
    /// for the UI/host-side polling.
    var isActive: Bool {
        guard let manager else { return false }
        return manager.isEnabled && (manager.connection.status == .connected || manager.connection.status == .connecting)
    }

    /// Make a `NEAppRule` that matches the transparent proxy extension itself. The packet
    /// tunnel's rule list MUST include this rule so that the relay traffic the extension
    /// emits via `NWConnection` is also routed through the WireGuard tunnel rather than
    /// the system default route.
    static func extensionAppRule() -> NEAppRule {
        let requirement = #"anchor apple generic and identifier "\#(extensionBundleIdentifier)""#
        return NEAppRule(signingIdentifier: extensionBundleIdentifier, designatedRequirement: requirement)
    }

    /// Configure (creating if necessary) the transparent proxy manager and start it.
    ///
    func enable() async throws {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        let matching = managers.first(where: { $0.localizedDescription == Self.managerDescription })

        let target = matching ?? NETransparentProxyManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.extensionBundleIdentifier
        proto.serverAddress = "TunnelBahn App-Tunnel Stats"
        target.protocolConfiguration = proto
        target.localizedDescription = Self.managerDescription
        target.isEnabled = true

        try await target.saveToPreferences()
        try await target.loadFromPreferences()

        try target.connection.startVPNTunnel()
        manager = target
        debugLog("transparent proxy started")
    }

    /// Disable and stop the transparent proxy manager. Idempotent.
    func disable() async {
        guard let manager else {
            // Try to find one that may have been left enabled from a prior session.
            do {
                let managers = try await NETransparentProxyManager.loadAllFromPreferences()
                if let stale = managers.first(where: { $0.localizedDescription == Self.managerDescription }) {
                    stale.connection.stopVPNTunnel()
                    if stale.isEnabled {
                        stale.isEnabled = false
                        try? await stale.saveToPreferences()
                        try? await stale.loadFromPreferences()
                    }
                    let deadline = Date().addingTimeInterval(5)
                    while Date() < deadline {
                        let status = stale.connection.status
                        if status == .disconnected || status == .invalid { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            } catch {
                debugLog("disable: loadAll failed: \(error.localizedDescription)")
            }
            return
        }
        manager.connection.stopVPNTunnel()
        if manager.isEnabled {
            manager.isEnabled = false
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                debugLog("disable: save failed: \(error.localizedDescription)")
            }
        }
        // Wait for the extension process to actually stop so that the next enable()
        // always triggers a fresh startProxy (and reads the updated config files).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let status = manager.connection.status
            if status == .disconnected || status == .invalid {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        debugLog("transparent proxy stopped (status=\(manager.connection.status.rawValue))")
    }

    private func debugLog(_ message: String) {
        Self.osLog.debug("\(message, privacy: .public)")
    }
}

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
    private static let osLog = AppLog(subsystem: "com.tunnelbahn.mac", category: "PerAppStatsProxy")

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
    ///
    /// The designated requirement is extracted from the bundled extension binary at
    /// runtime via `SecCodeCopyDesignatedRequirement`. A hardcoded `anchor apple generic`
    /// string only matches Developer ID + Mac App Store chains and silently fails to
    /// bind to development-signed builds (the kernel checks the rule's DR against the
    /// running process's full code signature and drops the packets if any clause
    /// — e.g. `certificate leaf[subject.CN]` — doesn't match).
    static func extensionAppRule() -> NEAppRule {
        let requirement = bundledExtensionDesignatedRequirement()
            ?? #"anchor apple generic and identifier "\#(extensionBundleIdentifier)""#
        return NEAppRule(signingIdentifier: extensionBundleIdentifier, designatedRequirement: requirement)
    }

    private static func bundledExtensionDesignatedRequirement() -> String? {
        let extPath = Bundle.main.bundlePath
            + "/Contents/Library/SystemExtensions/\(extensionBundleIdentifier).systemextension"
        guard FileManager.default.fileExists(atPath: extPath) else {
            osLog.notice("extensionAppRule: bundled extension not found at \(extPath); falling back to hardcoded DR")
            return nil
        }
        let dr = NEAppRuleBuilder.designatedRequirementString(forAppAtPath: extPath) { msg in
            Self.osLog.notice("extensionAppRule DR: \(msg)")
        }
        if let dr {
            osLog.notice("extensionAppRule: resolved DR from bundled extension: \(dr)")
        }
        return dr
    }

    /// Configure (creating if necessary) the transparent proxy manager and start it.
    ///
    func enable(config: TransparentProxyRuntimeConfig) async throws {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        let matching = managers.first(where: { $0.localizedDescription == Self.managerDescription })

        let target = matching ?? NETransparentProxyManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.extensionBundleIdentifier
        proto.serverAddress = "TunnelBahn App-Tunnel Stats"
        proto.providerConfiguration = [
            TransparentProxyRuntimeConfig.providerConfigurationKey: try TransparentProxyRuntimeConfig.encodeBase64(config) as NSString,
        ]
        target.protocolConfiguration = proto
        target.localizedDescription = Self.managerDescription
        target.isEnabled = true

        // Fail-closed gap minimization (P3, window b): with on-demand, macOS keeps the proxy
        // provider running and restarts it promptly when matching traffic appears — shrinking the
        // no-proxy window during which a routed app's *new* connections would egress directly
        // (en0) and leak the real ISP IP. Mirrors the packet tunnel's on-demand rule in
        // `VPNManager.configureManager`.
        //
        // NOTE: a transparent proxy has no kernel-level packet block while its provider process is
        // down — `includedNetworkRules` only apply while it runs — so this *minimizes*, it does not
        // *eliminate*, the crash/restart leak window. The P1/P2 fixes are what keep the proxy from
        // needing a restart at all (recovery is in-process), so this window rarely opens.
        let connectRule = NEOnDemandRuleConnect()
        connectRule.interfaceTypeMatch = .any
        target.onDemandRules = [connectRule]
        target.isOnDemandEnabled = true

        try await target.saveToPreferences()
        try await target.loadFromPreferences()

        try target.connection.startVPNTunnel()
        manager = target

        // Verify the proxy provider actually launched. Returning success on startVPNTunnel()
        // alone lets the caller report a fully-connected split-tunnel session while selected
        // apps' flows are never intercepted and egress directly (silent leak). Mirror the
        // packet tunnel's connect wait: a short grace absorbs the transient .disconnected
        // right after startVPNTunnel before failing on a settled stop state.
        let graceDeadline = Date().addingTimeInterval(3)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let status = target.connection.status
            if status == .connected {
                debugLog("transparent proxy started")
                return
            }
            if (status == .invalid || status == .disconnected), Date() > graceDeadline {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let finalStatus = target.connection.status
        Self.osLog.notice("enable: transparent proxy did not reach connected (status=\(finalStatus.rawValue))")
        throw NSError(
            domain: "TunnelBahn.PerAppStatsProxy",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The transparent proxy extension did not start (status \(finalStatus.rawValue)). Selected apps would bypass the tunnel."
            ]
        )
    }

    /// Disable and stop the transparent proxy manager. Idempotent.
    func disable() async {
        guard let manager else {
            // Try to find one that may have been left enabled from a prior session.
            do {
                let managers = try await NETransparentProxyManager.loadAllFromPreferences()
                if let stale = managers.first(where: { $0.localizedDescription == Self.managerDescription }) {
                    // Clear on-demand before stopping, else macOS auto-restarts the provider.
                    if stale.isOnDemandEnabled || stale.isEnabled {
                        stale.isOnDemandEnabled = false
                        stale.onDemandRules = nil
                        stale.isEnabled = false
                        try? await stale.saveToPreferences()
                        try? await stale.loadFromPreferences()
                    }
                    stale.connection.stopVPNTunnel()
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
        // Clear on-demand before stopping, else macOS immediately auto-restarts the provider
        // (mirrors VPNManager's disconnect). Then stop the tunnel.
        if manager.isOnDemandEnabled || manager.isEnabled {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = nil
            manager.isEnabled = false
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                debugLog("disable: save failed: \(error.localizedDescription)")
            }
        }
        manager.connection.stopVPNTunnel()
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

    /// Live-push the merged destination CIDR set to the *running* proxy extension so it can
    /// widen `includedNetworkRules` without a reconnect. This is the only host→proxy channel
    /// that crosses the uid boundary: the host (user) and the proxy (root) resolve the App
    /// Group container to different directories, so a shared file can't carry mid-session
    /// updates — but `sendProviderMessage` rides the NE config machinery, not the filesystem.
    /// Returns true once the extension acks (or false on cast failure / timeout).
    @discardableResult
    func pushDestinationRanges(enforce: Bool, ranges: [String]) async -> Bool {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            Self.osLog.notice("pushDestinationRanges: proxy connection is not a provider session; cannot live-update")
            return false
        }
        let payload: [String: Any] = ["cmd": "setDestinations", "enforce": enforce, "ranges": ranges]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let race = SingleFireBox()
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(3))
                race.fire { continuation.resume(returning: false) }
            }
            do {
                try session.sendProviderMessage(data) { _ in
                    // Fire first, then cancel: cancelling wakes the sleeping timeout task, and
                    // doing so before firing would let it win the race with a spurious false.
                    race.fire { continuation.resume(returning: true) }
                    timeoutTask.cancel()
                }
            } catch {
                Self.osLog.notice("pushDestinationRanges: sendProviderMessage threw \(error.localizedDescription)")
                timeoutTask.cancel()
                race.fire { continuation.resume(returning: false) }
            }
        }
    }

    /// Pull the running proxy extension's current per-app stats over the provider-message
    /// channel. Files can't carry this data: the host (user) and proxy (root) resolve the App
    /// Group container to different directories and the sandbox blocks the root extension from
    /// writing into the user's container, so `sendProviderMessage` is the only path that crosses
    /// the uid boundary. Returns nil on cast failure, timeout, or undecodable reply.
    func fetchStats() async -> PerAppTransferStats? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        guard let request = try? JSONSerialization.data(withJSONObject: ["cmd": "getStats"]) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<PerAppTransferStats?, Never>) in
            let race = SingleFireBox()
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(2))
                race.fire { continuation.resume(returning: nil) }
            }
            do {
                try session.sendProviderMessage(request) { response in
                    race.fire {
                        guard let response else { continuation.resume(returning: nil); return }
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        continuation.resume(returning: try? decoder.decode(PerAppTransferStats.self, from: response))
                    }
                    timeoutTask.cancel()
                }
            } catch {
                Self.osLog.notice("fetchStats: sendProviderMessage threw \(error.localizedDescription)")
                timeoutTask.cancel()
                race.fire { continuation.resume(returning: nil) }
            }
        }
    }

    /// Pull the proxy extension's own CPU/memory over IPC (the resource file can't cross the uid
    /// boundary either). Returns nil on cast failure, timeout, or unparseable reply.
    func fetchResourceUsage() async -> (cpu: Double, memory: UInt64)? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        guard let request = try? JSONSerialization.data(withJSONObject: ["cmd": "getResourceStats"]) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<(cpu: Double, memory: UInt64)?, Never>) in
            let race = SingleFireBox()
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(2))
                race.fire { continuation.resume(returning: nil) }
            }
            do {
                try session.sendProviderMessage(request) { response in
                    race.fire {
                        guard let response,
                              let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                              let cpu = (obj["cpu"] as? NSNumber)?.doubleValue,
                              let memory = (obj["memory"] as? NSNumber)?.uint64Value
                        else { continuation.resume(returning: nil); return }
                        continuation.resume(returning: (cpu, memory))
                    }
                    timeoutTask.cancel()
                }
            } catch {
                timeoutTask.cancel()
                race.fire { continuation.resume(returning: nil) }
            }
        }
    }

    private func debugLog(_ message: String) {
        Self.osLog.debug("\(message)")
    }
}

/// Guarantees exactly one continuation resume when racing `sendProviderMessage` against a timeout.
private final class SingleFireBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        body()
    }
}

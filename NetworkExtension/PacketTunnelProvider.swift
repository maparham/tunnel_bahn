import Foundation
import Darwin
import NetworkExtension
import os.log

public final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var adapter: BoringTunAdapter?
    private var relayServer: PacketTunnelRelayServer?
    private let logger = AppLog(subsystem: "com.tunnelbahn.mac.networkextension", category: "PacketTunnelProvider")
    // Tagged with `resourceSampleQueueKey` so `sampleResources()` can detect when it is already
    // running on this queue and call the sampler directly instead of dispatching `sync` onto
    // itself (which would deadlock).
    private static let resourceSampleQueueKey = DispatchSpecificKey<Void>()
    private let resourceSampleQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.tunnelbahn.mac.networkextension.resourcesample", qos: .utility)
        queue.setSpecific(key: PacketTunnelProvider.resourceSampleQueueKey, value: ())
        return queue
    }()
    private var resourceSampleTimer: DispatchSourceTimer?
    private let resourceSampler = ProcessResourceSampler()
    private static let resourceSampleInterval: DispatchTimeInterval = .seconds(2)

    override public func startTunnel(options _: [String: NSObject]? = nil) async throws {
        logger.log("startTunnel invoked")
        try AppGroupStore.ensureSharedDirectories()
        let loadedRuntime = try loadRuntimeStateWithSource()
        let runtime = loadedRuntime.state
        logger.log("runtime state source: \(loadedRuntime.source.rawValue)")
        logRuntimeProfileSummary(runtime.profile, source: loadedRuntime.source.rawValue)
        if let routes = runtime.appTunnelIncludedRoutes, !routes.isEmpty {
            logger.notice("destination app-tunnel included routes count=\(routes.count)")
        }
        adapter = BoringTunAdapter(provider: self)
        do {
            try await adapter?.start(
                with: runtime.profile,
                secrets: runtime.secrets,
                appTunnelIncludedRoutes: runtime.appTunnelIncludedRoutes
            )
        } catch {
            logger.error("startTunnel failed: \(error.localizedDescription)")
            throw error
        }
        if let runtimeConfiguration = await adapter?.runtimeConfiguration() {
            logger.log("wireguard runtimeConfiguration after start:\n\(runtimeConfiguration)")
        } else {
            logger.error("wireguard runtimeConfiguration unavailable after start")
        }
        let endpointSummary = runtime.profile.peers.first?.endpoint ?? "nil"
        logger.notice(
            "[APPSPLIT_EXT_SUMMARY] outcome=started source=\(loadedRuntime.source.rawValue) profile=\(runtime.profile.name) peers=\(runtime.profile.peers.count) endpoint=\(endpointSummary)"
        )
        if let adapter, let tunnelIPv4 = Self.primaryIPv4Address(from: runtime.profile) {
            if let relay = SmoltcpRelayBridge(tunnelIPv4: tunnelIPv4) {
                adapter.attachRelayBridge(relay)
                if let server = PacketTunnelRelayServer(relayBridge: relay, packetQueue: adapter.relayPacketQueue) {
                    relayServer = server
                    server.start()
                    logger.notice("smoltcp relay + UNIX-socket bridge started tunnelIP=\(tunnelIPv4)")
                } else {
                    logger.error("PacketTunnelRelayServer init failed (socket URL unavailable)")
                }
            } else {
                logger.error("SmoltcpRelayBridge init failed for tunnelIP=\(tunnelIPv4)")
            }
        }
        logger.log("startTunnel completed adapter started")
        startResourceSampler()
    }

    override public func stopTunnel(with _: NEProviderStopReason) async {
        resourceSampleTimer?.cancel()
        resourceSampleTimer = nil
        relayServer?.stop()
        relayServer = nil
        await adapter?.stop()
        adapter = nil
    }

    private static func primaryIPv4Address(from profile: WireGuardProfile) -> String? {
        profile.interface.addresses
            .first(where: { $0.contains(".") && $0.contains("/") })
            .flatMap { $0.split(separator: "/").first }
            .map(String.init)
    }

    override public func handleAppMessage(_ messageData: Data) async -> Data? {
        let command = String(data: messageData, encoding: .utf8) ?? ""
        if command == "runtimeConfiguration" {
            guard let runtime = await adapter?.runtimeConfiguration() else { return nil }
            return runtime.data(using: .utf8)
        }
        if command == "tunnelInterfaceName" {
            do {
                let loadedRuntime = try loadRuntimeStateWithSource()
                if let name = Self.interfaceName(matchingTunnelAddressIn: loadedRuntime.state.profile) {
                    return name.data(using: .utf8)
                }
            } catch {
                logger.error("tunnelInterfaceName lookup failed: \(error.localizedDescription)")
            }
            return nil
        }
        if command == "diagnostics" {
            return await diagnosticsPayload().data(using: .utf8)
        }
        if command == "resourceStats" {
            // The host can't read this extension's resource file across the uid boundary, so it
            // pulls our own CPU/memory over IPC instead. Reuses the same sampler as the timer path
            // so the host sees the smoothed time-delta value, not a divergent snapshot.
            let sample = sampleResources()
            let payload: [String: Any] = [
                "cpu": sample.cpuPercent,
                "memory": sample.memoryBytes,
            ]
            return try? JSONSerialization.data(withJSONObject: payload)
        }
        return "TunnelBahn Network Extension active".data(using: .utf8)
    }

    private func diagnosticsPayload() async -> String {
        var lines: [String] = []
        lines.append("=== PACKET TUNNEL EXTENSION DIAGNOSTICS ===")
        lines.append("extension: \(Bundle.main.bundleIdentifier ?? "unknown")")

        if let proto = protocolConfiguration as? NETunnelProviderProtocol {
            lines.append("providerBundleIdentifier: \(proto.providerBundleIdentifier ?? "nil")")
            lines.append("serverAddress: \(proto.serverAddress ?? "nil")")
        }

        do {
            let loadedRuntime = try loadRuntimeStateWithSource()
            let runtime = loadedRuntime.state
            let iface = runtime.profile.interface
            lines.append("")
            lines.append("Profile:")
            lines.append("  runtime.source: \(loadedRuntime.source.rawValue)")
            lines.append("  name: \(runtime.profile.name)")
            lines.append("  interface.addresses: \(iface.addresses.joined(separator: ", "))")
            lines.append("  interface.dnsServers: \(iface.dnsServers.joined(separator: ", "))")
            lines.append("  interface.mtu: \(iface.mtu.map(String.init) ?? "nil")")
            if let peer = runtime.profile.peers.first {
                lines.append("  peer.endpoint: \(peer.endpoint)")
                lines.append("  peer.allowedIPs: \(peer.allowedIPs.joined(separator: ", "))")
                lines.append("  peer.keepalive: \(peer.persistentKeepalive.map(String.init) ?? "nil")")
            }
        } catch {
            lines.append("")
            lines.append("Failed to load runtime profile: \(error.localizedDescription)")
        }

        if let runtime = await adapter?.runtimeConfiguration() {
            lines.append("")
            lines.append("WireGuard runtimeConfiguration:")
            lines.append(runtime)
        } else {
            lines.append("")
            lines.append("WireGuard runtimeConfiguration: unavailable")
        }

        return lines.joined(separator: "\n")
    }

    private func loadRuntimeState() throws -> TunnelRuntimeState {
        try loadRuntimeStateWithSource().state
    }

    private func loadRuntimeStateWithSource() throws -> LoadedRuntimeState {
        guard let stateURL = SharedPaths.stateFileURL() else {
            throw NSError(
                domain: "TunnelBahn.NetworkExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing shared runtime state URL."]
            )
        }
        do {
            let data = try Data(contentsOf: stateURL)
            logger.log("loaded runtime state from app group file")
            let state = try JSONDecoder().decode(TunnelRuntimeState.self, from: data)
            return LoadedRuntimeState(state: state, source: .appGroupFile)
        } catch {
            // If the App Group state file is missing (common during early install / dev builds),
            // fall back to the providerConfiguration payload the app saved with the tunnel config.
            if let proto = protocolConfiguration as? NETunnelProviderProtocol,
               let b64 = proto.providerConfiguration?["runtimeStateB64"] as? String,
               let data = Data(base64Encoded: b64)
            {
                logger.log("loaded runtime state from providerConfiguration")
                let state = try JSONDecoder().decode(TunnelRuntimeState.self, from: data)
                return LoadedRuntimeState(state: state, source: .providerConfiguration)
            }
            logger.error("failed to load runtime state: \(error.localizedDescription)")
            throw error
        }
    }

    private func startResourceSampler() {
        let timer = DispatchSource.makeTimerSource(queue: resourceSampleQueue)
        timer.schedule(deadline: .now() + Self.resourceSampleInterval, repeating: Self.resourceSampleInterval)
        timer.setEventHandler { [weak self] in
            self?.sampleAndPublishExtensionResources()
        }
        timer.resume()
        resourceSampleTimer = timer
    }

    private func sampleAndPublishExtensionResources() {
        // Runs on `resourceSampleQueue` (via the sample timer).
        let sample = sampleResources()
        var merged = ExtensionResourceStore.read()
        merged.packetTunnelCPU = sample.cpuPercent
        merged.packetTunnelMemory = sample.memoryBytes
        merged.lastUpdate = .now
        merged.schemaVersion = ExtensionResourceStats.currentSchemaVersion
        do {
            try ExtensionResourceStore.write(merged)
        } catch {
            logger.error("failed to write extension resource stats: \(error.localizedDescription)")
        }
    }

    /// Serializes `resourceSampler` on `resourceSampleQueue`. The sampler carries time-delta state
    /// between calls and is not thread-safe, while the `resourceStats` IPC reply arrives on a
    /// different queue than the sample timer — funneling both through one queue keeps the smoothed
    /// value coherent.
    private func sampleResources() -> ProcessResourceSampler.Sample {
        if DispatchQueue.getSpecific(key: Self.resourceSampleQueueKey) != nil {
            return resourceSampler.sample()
        }
        return resourceSampleQueue.sync { resourceSampler.sample() }
    }

    private func logRuntimeProfileSummary(_ profile: WireGuardProfile, source: String) {
        let addresses = profile.interface.addresses.joined(separator: ", ")
        let dns = profile.interface.dnsServers.joined(separator: ", ")
        let mtu = profile.interface.mtu.map(String.init) ?? "nil"
        logger.log(
            "runtime profile summary source=\(source) name=\(profile.name) addresses=[\(addresses)] dns=[\(dns)] mtu=\(mtu) peers=\(profile.peers.count)"
        )
        for (index, peer) in profile.peers.enumerated() {
            let allowedJoined = peer.allowedIPs.joined(separator: ", ")
            let keepaliveStr = peer.persistentKeepalive.map(String.init) ?? "nil"
            logger.log(
                "runtime peer[\(index)] endpoint=\(peer.endpoint) allowedIPs=\(allowedJoined) keepalive=\(keepaliveStr)"
            )
        }
    }

    /// Finds the utun interface that carries the tunnel's primary IPv4 address.
    private static func interfaceName(matchingTunnelAddressIn profile: WireGuardProfile) -> String? {
        guard let v4CIDR = profile.interface.addresses.first(where: { $0.contains(".") && $0.contains("/") }),
              let address = v4CIDR.split(separator: "/").first.map(String.init),
              !address.isEmpty
        else {
            return nil
        }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(sa.pointee.sa_len)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if String(cString: host) == address {
                return String(cString: ptr.pointee.ifa_name)
            }
        }
        return nil
    }
}

private struct LoadedRuntimeState {
    let state: TunnelRuntimeState
    let source: RuntimeStateSource
}

private enum RuntimeStateSource: String {
    case appGroupFile = "appGroupFile"
    case providerConfiguration = "providerConfiguration"
}

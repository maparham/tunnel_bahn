import Foundation
import Darwin
import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var adapter: BoringTunAdapter?
    private let logger = Logger(subsystem: "com.tunnelbahn.mac.networkextension", category: "PacketTunnelProvider")
    private let resourceSampleQueue = DispatchQueue(label: "com.tunnelbahn.mac.networkextension.resourcesample", qos: .utility)
    private var resourceSampleTimer: DispatchSourceTimer?
    private static let resourceSampleInterval: DispatchTimeInterval = .seconds(2)

    override func startTunnel(options _: [String: NSObject]? = nil) async throws {
        logger.log("startTunnel invoked")
        try AppGroupStore.ensureSharedDirectories()
        let loadedRuntime = try loadRuntimeStateWithSource()
        let runtime = loadedRuntime.state
        logger.log("runtime state source: \(loadedRuntime.source.rawValue, privacy: .public)")
        logRuntimeProfileSummary(runtime.profile, source: loadedRuntime.source.rawValue)
        adapter = BoringTunAdapter(provider: self)
        try await adapter?.start(with: runtime.profile)
        if let runtimeConfiguration = await adapter?.runtimeConfiguration() {
            logger.log("wireguard runtimeConfiguration after start:\n\(runtimeConfiguration, privacy: .public)")
        } else {
            logger.error("wireguard runtimeConfiguration unavailable after start")
        }
        let endpointSummary = runtime.profile.peers.first?.endpoint ?? "nil"
        logger.notice(
            "[APPSPLIT_EXT_SUMMARY] outcome=started source=\(loadedRuntime.source.rawValue, privacy: .public) profile=\(runtime.profile.name, privacy: .public) peers=\(runtime.profile.peers.count) endpoint=\(endpointSummary, privacy: .public)"
        )
        logger.log("startTunnel completed adapter started")
        startResourceSampler()
    }

    override func stopTunnel(with _: NEProviderStopReason) async {
        resourceSampleTimer?.cancel()
        resourceSampleTimer = nil
        await adapter?.stop()
        adapter = nil
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let command = String(data: messageData, encoding: .utf8) ?? ""
        if command == "runtimeConfiguration" {
            guard let runtime = await adapter?.runtimeConfiguration() else { return nil }
            return runtime.data(using: .utf8)
        }
        if command == "diagnostics" {
            return await diagnosticsPayload().data(using: .utf8)
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

    private func loadRuntimeState() throws -> RuntimeState {
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
            let state = try JSONDecoder().decode(RuntimeState.self, from: data)
            return LoadedRuntimeState(state: state, source: .appGroupFile)
        } catch {
            // If the App Group state file is missing (common during early install / dev builds),
            // fall back to the providerConfiguration payload the app saved with the tunnel config.
            if let proto = protocolConfiguration as? NETunnelProviderProtocol,
               let b64 = proto.providerConfiguration?["runtimeStateB64"] as? String,
               let data = Data(base64Encoded: b64)
            {
                logger.log("loaded runtime state from providerConfiguration")
                let state = try JSONDecoder().decode(RuntimeState.self, from: data)
                return LoadedRuntimeState(state: state, source: .providerConfiguration)
            }
            logger.error("failed to load runtime state: \(error.localizedDescription, privacy: .public)")
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
        let cpu = Self.readCPUUsagePercent()
        let memory = Self.readResidentMemoryBytes()
        var merged = ExtensionResourceStore.read()
        merged.packetTunnelCPU = cpu
        merged.packetTunnelMemory = memory
        merged.lastUpdate = .now
        merged.schemaVersion = ExtensionResourceStats.currentSchemaVersion
        do {
            try ExtensionResourceStore.write(merged)
        } catch {
            logger.error("failed to write extension resource stats: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func readResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private static func readCPUUsagePercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let task = mach_task_self_
        guard task_threads(task, &threadList, &threadCount) == KERN_SUCCESS, let threads = threadList else {
            return 0
        }
        defer {
            let address = vm_address_t(UInt(bitPattern: threads))
            let byteCount = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(task, address, byteCount)
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            if threadInfo.flags & Int32(TH_FLAGS_IDLE) == 0 {
                total += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    private func logRuntimeProfileSummary(_ profile: WireGuardProfile, source: String) {
        let addresses = profile.interface.addresses.joined(separator: ", ")
        let dns = profile.interface.dnsServers.joined(separator: ", ")
        let mtu = profile.interface.mtu.map(String.init) ?? "nil"
        logger.log(
            "runtime profile summary source=\(source, privacy: .public) name=\(profile.name, privacy: .public) addresses=[\(addresses, privacy: .public)] dns=[\(dns, privacy: .public)] mtu=\(mtu, privacy: .public) peers=\(profile.peers.count)"
        )
        for (index, peer) in profile.peers.enumerated() {
            let allowedJoined = peer.allowedIPs.joined(separator: ", ")
            let keepaliveStr = peer.persistentKeepalive.map(String.init) ?? "nil"
            logger.log(
                "runtime peer[\(index)] endpoint=\(peer.endpoint, privacy: .public) allowedIPs=\(allowedJoined, privacy: .public) keepalive=\(keepaliveStr, privacy: .public)"
            )
        }
    }
}

private struct RuntimeState: Codable {
    let profile: WireGuardProfile
}

private struct LoadedRuntimeState {
    let state: RuntimeState
    let source: RuntimeStateSource
}

private enum RuntimeStateSource: String {
    case appGroupFile = "appGroupFile"
    case providerConfiguration = "providerConfiguration"
}

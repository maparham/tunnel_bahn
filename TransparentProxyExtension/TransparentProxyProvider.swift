import Foundation
import Darwin
import Network
import NetworkExtension
import os.log

/// Transparent proxy provider that observes (and relays) flows for the apps the user has
/// chosen to route through the VPN. Its only purpose is app-tunnel TX/RX accounting; the
/// actual VPN data plane is still handled by the existing `PacketTunnelProvider`.
///
/// Why a relay and not just observation:
/// - `NETransparentProxyProvider.handleNewFlow` returning `false` lets the OS handle the flow
///   normally (no bytes seen). Returning `true` requires us to take ownership of the flow,
///   which is the only way to count payload bytes.
/// - For flows from apps NOT in the app-tunnel routing list we return `false` immediately, so
///   the OS handles them and we incur no overhead.
final class TransparentProxyProvider: NETransparentProxyProvider {
    private static let log = Logger(
        subsystem: "com.tunnelbahn.mac.transparentproxy",
        category: "Provider"
    )

    private let aggregator = PerAppCounterAggregator()
    private let destinationAggregator = PerDestinationCounterAggregator()
    private let flowQueue = DispatchQueue(label: "com.tunnelbahn.mac.transparentproxy.flows", qos: .userInitiated)
    private let flushQueue = DispatchQueue(label: "com.tunnelbahn.mac.transparentproxy.flush", qos: .utility)
    private var flushTimer: DispatchSourceTimer?

    // Keep relay objects alive for the lifetime of a flow. Without this, relays are
    // deallocated immediately after `handleNewFlow` returns, and no bytes are ever relayed/counted.
    private let activeRelaysLock = NSLock()
    private var activeRelays: [ObjectIdentifier: AnyObject] = [:]

    /// Cached snapshot of routed-app signing identifiers, refreshed on each flush so the
    /// hot path of `handleNewFlow` doesn't have to re-read AppGroup every time.
    private let routedFiltersLock = NSLock()
    private var routedSigningIdentifiers: Set<String> = []
    /// When true (full-tunnel / all-traffic accounting), relay and count every flow that has a signing ID.
    private var routeAllIdentifiedFlows = false

    private let destinationLock = NSLock()
    /// When false, flows that pass signing-ID eligibility are relayed for any remote.
    /// When true, relay only IPv4/v6 literals whose address matches at least one CIDR snapshot.
    private var enforceDestinationFiltering = false
    private var destinationRawCIDRs: [String] = []

    private static let flushInterval: DispatchTimeInterval = .milliseconds(1500)
    private static let perAppRoutedSigningIDsDefaultsKey = "perAppRoutedSigningIdentifiers"
    private static let perAppRouteAllFlowsDefaultsKey = "perAppRouteAllIdentifiedFlows"

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        Self.log.notice("startProxy invoked")
        refreshRoutedSigningIdentifiers()
        refreshDestinationConfig()

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = buildIncludedNetworkRules()

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }
            self.startFlushTimer()
            Self.log.notice("startProxy completed")
            completionHandler(nil)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Self.log.notice("stopProxy reason=\(reason.rawValue, privacy: .public)")
        flushTimer?.cancel()
        flushTimer = nil
        flushOnce()
        aggregator.clear()
        destinationAggregator.clear()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let signingID = flow.metaData.sourceAppSigningIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signingID.isEmpty else {
            return false
        }
        
        let routed = isRouted(signingID)
        Self.log.notice("handleNewFlow: signingID=\(signingID, privacy: .public) isRouted=\(routed, privacy: .public) flowType=\(String(describing: type(of: flow)), privacy: .public)")
        
        guard routed else {
            return false
        }

        let flowKey = ObjectIdentifier(flow)

        if let tcp = flow as? NEAppProxyTCPFlow {
            let remoteLiteral = literalRemoteHostname(from: tcp)
            let relay = TCPFlowRelay(
                flow: tcp,
                signingID: signingID,
                queue: flowQueue,
                onTx: { [weak self] bytes in
                    self?.aggregator.addTx(bytes, signingID: signingID)
                    if let remoteLiteral {
                        self?.destinationAggregator.addTx(bytes, signingID: signingID, remoteLiteral: remoteLiteral)
                    }
                },
                onRx: { [weak self] bytes in
                    self?.aggregator.addRx(bytes, signingID: signingID)
                    if let remoteLiteral {
                        self?.destinationAggregator.addRx(bytes, signingID: signingID, remoteLiteral: remoteLiteral)
                    }
                },
                onClose: { [weak self] in
                    guard let self else { return }
                    self.activeRelaysLock.lock()
                    self.activeRelays.removeValue(forKey: flowKey)
                    self.activeRelaysLock.unlock()
                }
            )
            activeRelaysLock.lock()
            activeRelays[flowKey] = relay
            activeRelaysLock.unlock()
            relay.start()
            return true
        }
        if let udp = flow as? NEAppProxyUDPFlow {
            let relay = UDPFlowRelay(
                flow: udp,
                signingID: signingID,
                queue: flowQueue,
                onTx: { [weak self] in self?.aggregator.addTx($0, signingID: signingID) },
                onRx: { [weak self] in self?.aggregator.addRx($0, signingID: signingID) },
                onClose: { [weak self] in
                    guard let self else { return }
                    self.activeRelaysLock.lock()
                    self.activeRelays.removeValue(forKey: flowKey)
                    self.activeRelaysLock.unlock()
                }
            )
            activeRelaysLock.lock()
            activeRelays[flowKey] = relay
            activeRelaysLock.unlock()
            relay.start()
            return true
        }

        Self.log.error("handleNewFlow: routed but unsupported flow type=\(String(describing: type(of: flow)), privacy: .public)")
        return false
    }

    private func isRouted(_ signingID: String) -> Bool {
        routedFiltersLock.lock()
        defer { routedFiltersLock.unlock() }
        if routeAllIdentifiedFlows {
            return !signingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return routedSigningIdentifiers.contains(signingID)
    }

    private func refreshRoutedSigningIdentifiers() {
        // Prefer the shared file written by the host app; CFPreferences-backed app-group defaults
        // can fail inside extensions on some macOS configurations.
        Self.log.notice("refreshRoutedSigningIdentifiers called")
        
        guard let fileURL = SharedPaths.perAppRoutedSigningIdentifiersFileURL() else {
            Self.log.notice("refreshRoutedSigningIdentifiers: fileURL is nil")
            return loadFromUserDefaultsOrFallback()
        }
        Self.log.notice("refreshRoutedSigningIdentifiers: fileURL=\(fileURL.path, privacy: .public)")
        
        guard let data = try? Data(contentsOf: fileURL) else {
            Self.log.notice("refreshRoutedSigningIdentifiers: failed to read file")
            return loadFromUserDefaultsOrFallback()
        }
        Self.log.notice("refreshRoutedSigningIdentifiers: read \(data.count) bytes")
        
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            Self.log.notice("refreshRoutedSigningIdentifiers: JSON parse failed or empty")
            return loadFromUserDefaultsOrFallback()
        }

        if dict["routeAllIdentifiedFlows"] as? Bool == true {
            routedFiltersLock.lock()
            routeAllIdentifiedFlows = true
            routedSigningIdentifiers = []
            routedFiltersLock.unlock()
            Self.log.notice("refreshRoutedSigningIdentifiers: routeAllIdentifiedFlows=true (full-traffic accounting)")
            return
        }

        routeAllIdentifiedFlows = false
        guard let fromFile = dict["signingIdentifiers"] as? [String],
              !fromFile.isEmpty else {
            Self.log.notice("refreshRoutedSigningIdentifiers: signingIdentifiers missing or empty")
            return loadFromUserDefaultsOrFallback()
        }

        var ids = Set(
            fromFile.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        // Terminal.app spawns tools whose signing ID is the tool itself (e.g. curl/ssh),
        // not com.apple.Terminal. If Terminal is routed, route these common tools too.
        if ids.contains("com.apple.Terminal") {
            ids.formUnion(["com.apple.curl", "com.apple.ssh"])
        }
        routedFiltersLock.lock()
        routedSigningIdentifiers = ids
        routedFiltersLock.unlock()
        Self.log.notice("refreshRoutedSigningIdentifiers: loaded \(ids.count, privacy: .public) IDs from shared file: \(ids.sorted().joined(separator: ","), privacy: .public)")
    }
    
    private func loadFromUserDefaultsOrFallback() {
        // UserDefaults with a suite name (kCFPreferencesAnyUser) is not accessible from inside
        // Network Extension processes — macOS logs a CFPreferences warning and returns empty data.
        // The shared file written by the host app is the authoritative source and is always written
        // before the proxy starts. Treat a missing file as an empty routing set rather than
        // attempting a UserDefaults read that will warn and return nothing useful.
        Self.log.notice("loadFromUserDefaultsOrFallback: shared file unavailable; routing set will be empty until next proxy cycle")
        routedFiltersLock.lock()
        routeAllIdentifiedFlows = false
        routedSigningIdentifiers = []
        routedFiltersLock.unlock()
    }

    /// Builds the NENetworkRules for the proxy's includedNetworkRules.
    /// When destination filtering is enforced (split-tunnel), only intercept flows whose
    /// remote is within the AllowedIPs CIDRs — all other flows are left to the OS and
    /// exit via the routing table (en0 for internet) without ever entering the proxy.
    /// This avoids the need for any bypass relay mechanism entirely.
    private func buildIncludedNetworkRules() -> [NENetworkRule] {
        destinationLock.lock()
        let enforce = enforceDestinationFiltering
        let cidrs = destinationRawCIDRs
        destinationLock.unlock()

        let catchAll: [NENetworkRule] = [
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .UDP, direction: .outbound),
        ]

        guard enforce, !cidrs.isEmpty else { return catchAll }

        var rules: [NENetworkRule] = []
        for cidr in cidrs {
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { continue }
            let networkIP = String(parts[0])
            let endpoint = NWHostEndpoint(hostname: networkIP, port: "0")
            rules.append(NENetworkRule(remoteNetwork: endpoint, remotePrefix: prefix, localNetwork: nil, localPrefix: 0, protocol: .TCP, direction: .outbound))
            rules.append(NENetworkRule(remoteNetwork: endpoint, remotePrefix: prefix, localNetwork: nil, localPrefix: 0, protocol: .UDP, direction: .outbound))
        }

        if rules.isEmpty {
            // All CIDRs were unparseable — intercept nothing rather than falling back to catch-all,
            // which would route internet traffic into the tunnel (opposite of split-tunnel intent).
            Self.log.error("buildIncludedNetworkRules: all CIDRs unparseable — using empty rule set")
            return []
        }
        Self.log.notice("buildIncludedNetworkRules: split-tunnel \(rules.count, privacy: .public) rules for \(cidrs.count, privacy: .public) CIDRs")
        return rules
    }

    private func literalRemoteHostname(from flow: NEAppProxyFlow) -> String? {
        guard let tcp = flow as? NEAppProxyTCPFlow else { return nil }
        return normalizedLiteralIPv4Or6(hostnameFrom(remote: tcp.remoteEndpoint))
    }

    private func hostnameFrom(remote endpoint: NSObject?) -> String? {
        guard let hostEndpoint = endpoint as? NWHostEndpoint else { return nil }
        let name = hostEndpoint.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// NWHost hostname string must already be IPv4/IPv6 literal (no resolver); strips `%scope` suffix.
    private func normalizedLiteralIPv4Or6(_ hostname: String?) -> String? {
        guard var raw = hostname, !raw.isEmpty else { return nil }
        if let pct = raw.firstIndex(of: "%") {
            raw = String(raw[..<pct])
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, raw, &v4) == 1 {
            return raw
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, raw, &v6) == 1 {
            return raw
        }
        return nil
    }

    private func refreshDestinationConfig() {
        Self.log.notice("refreshDestinationConfig called")
        guard let fileURL = SharedPaths.destinationRangesFileURL() else {
            Self.log.notice("refreshDestinationConfig fileURL nil")
            applyDestinationPayload(enforce: false, rawCIDRs: [])
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            Self.log.notice("refreshDestinationConfig: file missing/unreadable \(fileURL.lastPathComponent, privacy: .public)")
            applyDestinationPayload(enforce: false, rawCIDRs: [])
            return
        }
        do {
            let payload = try JSONDecoder().decode(DestinationRoutingFilePayload.self, from: data)
            Self.log.notice(
                "refreshDestinationConfig: enforce=\(payload.enforceDestinationFiltering, privacy: .public) ranges=\(payload.ranges.count, privacy: .public)"
            )
            applyDestinationPayload(enforce: payload.enforceDestinationFiltering, rawCIDRs: payload.ranges)
        } catch {
            Self.log.notice(
                "refreshDestinationConfig decode failed \(error.localizedDescription, privacy: .public)"
            )
            applyDestinationPayload(enforce: false, rawCIDRs: [])
        }
    }

    private func applyDestinationPayload(enforce: Bool, rawCIDRs: [String]) {
        destinationLock.lock()
        let changed = enforce != enforceDestinationFiltering || rawCIDRs != destinationRawCIDRs
        enforceDestinationFiltering = enforce
        destinationRawCIDRs = rawCIDRs
        destinationLock.unlock()

        guard changed else { return }
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = buildIncludedNetworkRules()
        setTunnelNetworkSettings(settings) { error in
            if let error {
                Self.log.error("applyDestinationPayload setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flushOnce()
        }
        timer.resume()
        flushTimer = timer
    }

    private func flushOnce() {
        refreshRoutedSigningIdentifiers()
        refreshDestinationConfig()
        let rules = PerAppIdentityMap.loadActiveRules()
        let rolledUp = aggregator.rollup(rules: rules)
        let perDestination = destinationAggregator.rollupToRows(rules: rules)
        Self.log.notice(
            "flushOnce: rules=\(rules.count, privacy: .public) rolledUp=\(rolledUp.count, privacy: .public) destinations=\(perDestination.count, privacy: .public)"
        )
        let stats = PerAppTransferStats(
            schemaVersion: PerAppTransferStats.currentSchemaVersion,
            apps: rolledUp,
            lastUpdate: .now,
            perDestination: perDestination
        )
        do {
            try PerAppTransferStore.write(stats)
        } catch {
            Self.log.error("failed to flush app-tunnel stats: \(error.localizedDescription, privacy: .public)")
        }

        flushExtensionResourceStats()
    }

    private func flushExtensionResourceStats() {
        let cpu = Self.readCPUUsagePercent()
        let memory = Self.readResidentMemoryBytes()
        var merged = ExtensionResourceStore.read()
        merged.transparentProxyCPU = cpu
        merged.transparentProxyMemory = memory
        merged.lastUpdate = .now
        merged.schemaVersion = ExtensionResourceStats.currentSchemaVersion
        do {
            try ExtensionResourceStore.write(merged)
        } catch {
            Self.log.error("failed to flush extension resource stats: \(error.localizedDescription, privacy: .public)")
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
}

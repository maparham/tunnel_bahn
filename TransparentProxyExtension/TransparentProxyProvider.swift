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

    private static let flushInterval: DispatchTimeInterval = .milliseconds(1500)
    private static let perAppRoutedSigningIDsDefaultsKey = "perAppRoutedSigningIdentifiers"
    private static let perAppRouteAllFlowsDefaultsKey = "perAppRouteAllIdentifiedFlows"

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        Self.log.notice("startProxy invoked")
        refreshRoutedSigningIdentifiers()

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let tcpAny = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .TCP,
            direction: .outbound
        )
        let udpAny = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .UDP,
            direction: .outbound
        )
        settings.includedNetworkRules = [tcpAny, udpAny]

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
            let relay = TCPFlowRelay(
                flow: tcp,
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
        if AppGroupStore.defaults.bool(forKey: Self.perAppRouteAllFlowsDefaultsKey) {
            routedFiltersLock.lock()
            routeAllIdentifiedFlows = true
            routedSigningIdentifiers = []
            routedFiltersLock.unlock()
            Self.log.notice("loadFromUserDefaultsOrFallback: routeAllIdentifiedFlows from UserDefaults")
            return
        }

        routeAllIdentifiedFlows = false
        let persisted = (AppGroupStore.defaults.array(forKey: Self.perAppRoutedSigningIDsDefaultsKey) as? [String]) ?? []
        Self.log.notice("loadFromUserDefaultsOrFallback: read \(persisted.count) from UserDefaults")
        var ids = Set(
            persisted.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        // Backward compatibility: if the host app hasn't persisted resolved NEAppRule IDs yet,
        // fall back to AppRuleStore + curated helper mapping.
        if ids.isEmpty {
            Self.log.notice("loadFromUserDefaultsOrFallback: empty, falling back to AppRuleStore")
            let rules = PerAppIdentityMap.loadActiveRules().filter { $0.action == .routeVPN }
            for rule in rules {
                let trimmed = rule.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    ids.insert(trimmed)
                }
            }
            for (signingID, displayName) in PerAppSigningCatalog.knownRollupBySigningIdentifier {
                if rules.contains(where: { $0.displayName == displayName }) {
                    ids.insert(signingID)
                }
            }
            Self.log.notice("loadFromUserDefaultsOrFallback: fallback produced \(ids.count) IDs")
        }

        if ids.contains("com.apple.Terminal") {
            ids.formUnion(["com.apple.curl", "com.apple.ssh"])
        }

        routedFiltersLock.lock()
        routedSigningIdentifiers = ids
        routedFiltersLock.unlock()
        Self.log.notice("loadFromUserDefaultsOrFallback: final count=\(ids.count, privacy: .public), ids=\(ids.sorted().joined(separator: ","), privacy: .public)")
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
        let rules = PerAppIdentityMap.loadActiveRules()
        let rolledUp = aggregator.rollup(rules: rules)
        Self.log.notice("flushOnce: rules=\(rules.count, privacy: .public) rolledUp=\(rolledUp.count, privacy: .public)")
        let stats = PerAppTransferStats(
            schemaVersion: PerAppTransferStats.currentSchemaVersion,
            apps: rolledUp,
            lastUpdate: .now
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

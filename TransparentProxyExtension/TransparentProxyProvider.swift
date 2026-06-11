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
public final class TransparentProxyProvider: NETransparentProxyProvider {
    private static let log = AppLog(
        subsystem: "com.tunnelbahn.mac.transparentproxy",
        category: "Provider"
    )

    private let aggregator = PerAppCounterAggregator()
    private let destinationAggregator = PerDestinationCounterAggregator()
    private let flowQueue = DispatchQueue(label: "com.tunnelbahn.mac.transparentproxy.flows", qos: .userInitiated)
    // Tagged with `flushQueueKey` so `sampleResources()` can detect when it is already running on
    // this queue and call the sampler directly instead of dispatching `sync` onto itself (deadlock).
    private static let flushQueueKey = DispatchSpecificKey<Void>()
    private let flushQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.tunnelbahn.mac.transparentproxy.flush", qos: .utility)
        queue.setSpecific(key: TransparentProxyProvider.flushQueueKey, value: ())
        return queue
    }()
    private var flushTimer: DispatchSourceTimer?
    private let resourceSampler = ProcessResourceSampler()

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
    /// When true, `includedNetworkRules` are narrowed to the destination CIDRs so only flows
    /// to those ranges are delivered to `handleNewFlow`. Relays use `RelayCreateOutboundConnection`
    /// bound to `tunnelInterfaceName` so outbound connections exit via the WireGuard utun interface.
    private var enforceDestinationFiltering = false
    private var destinationRawCIDRs: [String] = []
    /// Domain-rule names (lowercased) for SNI routing. When non-empty and filtering is enforced,
    /// the proxy enters "SNI mode": it intercepts ALL routed-app TCP, peeks each flow's TLS SNI,
    /// and tunnels name/IP matches while sending the rest straight out en0. Empty = IP-only.
    private var destinationDomainNames: [String] = []
    /// Prepared form of `destinationRawCIDRs`, rebuilt only when the CIDR set changes, so the
    /// per-flow SNI decider can IP-match without re-parsing CIDR strings on the hot path.
    private var cachedPreparedRanges: [IPCIDRMatcher.PreparedRange] = []
    /// The WireGuard utun interface name (e.g. "utun3"), populated from
    /// `TransparentProxyRuntimeConfig.packetTunnelInterfaceName` on each config refresh.
    private var tunnelInterfaceName: String?

    /// Suffix match: `api.x.com` matches rule `x.com`; `notx.com` does not. `names` are lowercased.
    private static func sniMatches(_ host: String, names: [String]) -> Bool {
        let h = host.lowercased()
        for name in names where !name.isEmpty {
            if h == name || h.hasSuffix("." + name) { return true }
        }
        return false
    }

    // Last-logged snapshot of the flushOnce summary line — used to suppress
    // repeated identical heartbeats so only real changes get logged.
    private var lastLoggedFlushSummary: (rules: Int, rolledUp: Int, destinations: Int)?

    /// Latest per-app stats, JSON-encoded, served to the host over `sendProviderMessage`
    /// (`cmd:"getStats"`). The host (user) and this extension (root) resolve the App Group
    /// container to different directories and the sandbox forbids the root extension from
    /// writing into the user's container, so a shared file can't carry stats to the host —
    /// the IPC channel is the only path that crosses the uid boundary. Refreshed by `flushOnce`.
    private let statsLock = NSLock()
    private var latestStatsPayload: Data?
    private static let statsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Signing IDs that look like other transparent-proxy extensions whose flows have reached us.
    /// When non-empty, macOS is delivering some flows to a competing proxy before ours — and that
    /// proxy's outbound NWConnections (which we then see) reveal its identity. Persisted on change
    /// so the host app can warn the user.
    private let foreignProxyLock = NSLock()
    private var observedForeignProxySigningIDs: Set<String> = []

    private static let flushInterval: DispatchTimeInterval = .milliseconds(1500)
    private static let perAppRoutedSigningIDsDefaultsKey = "perAppRoutedSigningIdentifiers"
    private static let perAppRouteAllFlowsDefaultsKey = "perAppRouteAllIdentifiedFlows"

    override public func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        Self.log.notice("startProxy invoked")
        // The relay client is a process-singleton; on a reconnect the proxy extension process
        // is reused while the tunnel extension recreates its UDS listener at the same path.
        // Without dropping the cached socket here, the next openFlow writes to a dead server-side
        // fd, the reply never arrives, and curl hangs forever.
        TransparentProxyRelayClient.shared.reset(reason: "startProxy")
        refreshRoutedSigningIdentifiers()
        refreshDestinationConfig()
        // Reset the observed-competitor list on a fresh start. If the user removed the competing
        // proxy between connects, this prevents a stale warning from persisting forever.
        foreignProxyLock.lock()
        observedForeignProxySigningIDs.removeAll()
        foreignProxyLock.unlock()
        persistObservedForeignProxySigningIDs([])

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = buildIncludedNetworkRules()

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self.startFlushTimer()
            Self.log.notice("startProxy completed")
            completionHandler(nil)
        }
    }

    override public func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Self.log.notice("stopProxy reason=\(reason.rawValue)")
        flushTimer?.cancel()
        flushTimer = nil
        flushOnce()
        aggregator.clear()
        destinationAggregator.clear()
        // The extension process is reused across stop/start, and `applyDestinationPayload` now
        // unions (never replaces). Clear the per-session destination set here so the next
        // session starts from its own providerConfiguration baseline instead of inheriting the
        // previous profile's CIDRs. (Done in stopProxy, not startProxy, so an appMessage that
        // races ahead of the next startProxy isn't wiped.)
        destinationLock.lock()
        destinationRawCIDRs = []
        enforceDestinationFiltering = false
        tunnelInterfaceName = nil
        destinationDomainNames = []
        cachedPreparedRanges = []
        destinationLock.unlock()
        completionHandler()
    }

    /// Live destination-set updates pushed by the host app.
    ///
    /// Why this channel exists: the host (user uid) and these system extensions (root uid)
    /// resolve the App Group container to *different* directories, so the host cannot hand us
    /// an updated `destination-routing.json` — that file, read in `refreshDestinationConfig`,
    /// only ever exists in our own (root) container. `providerConfiguration` likewise carries
    /// only the connect-time snapshot. So when a routed domain resolves to a *new* IP
    /// mid-session (e.g. a CDN's second A record), the host pushes the merged destination set
    /// here and we widen `includedNetworkRules` live. Without it, flows to the newly-learned
    /// IP are never diverted to the proxy and silently bypass the tunnel.
    public override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
            let cmd = obj["cmd"] as? String
        else { return nil }

        switch cmd {
        case "setDestinations":
            let incoming = (obj["ranges"] as? [String]) ?? []
            let snapshot = currentDestinationState()
            // Only apply once destination filtering is already active. If `enforce` is false the
            // proxy is either still starting (its providerConfiguration baseline hasn't run yet)
            // or in full-funnel mode where destination ranges gate nothing. Applying now would
            // publish a *catch-all* includedNetworkRules set (buildIncludedNetworkRules returns
            // catch-all when !enforce) and `startProxy` would immediately re-narrow it — a double
            // setTunnelNetworkSettings on connect that leaves macOS diverting nothing, so flows
            // bypass the tunnel until a reconnect. The connect-time providerConfiguration already
            // carries the current ranges; genuinely new mid-session IPs arrive here once `enforce`
            // is true (the proxy is up) and are applied then — which is the whole point of this
            // channel. `enforce`/`iface` stay pinned so a message can never flip either.
            guard snapshot.enforce else {
                return try? JSONSerialization.data(withJSONObject: ["ok": false, "reason": "filtering-inactive"])
            }
            applyDestinationPayload(enforce: true, rawCIDRs: incoming, ifaceName: snapshot.iface, source: "appMessage")
            let ack: [String: Any] = ["ok": true, "count": currentDestinationState().cidrs.count]
            return try? JSONSerialization.data(withJSONObject: ack)
        case "getStats":
            // Per-app stats can't reach the host via the shared file (uid boundary + sandbox);
            // hand back the latest JSON-encoded snapshot cached by `flushOnce`. The lock is taken
            // inside a synchronous helper so no `NSLock` is held across this async function's
            // suspension points (Swift 6 rejects lock/unlock in async contexts).
            return currentStatsPayload() ?? (try? Self.statsEncoder.encode(PerAppTransferStats.empty))
        case "getResourceStats":
            // Same uid-boundary reason as getStats — hand back this extension's own CPU/memory.
            // `sampleResources()` hops onto `flushQueue` so it shares the smoothed time-delta
            // state with the flush-timer path instead of returning a divergent reading.
            let sample = sampleResources()
            let payload: [String: Any] = [
                "cpu": sample.cpuPercent,
                "memory": sample.memoryBytes,
            ]
            return try? JSONSerialization.data(withJSONObject: payload)
        default:
            return nil
        }
    }

    /// Synchronous (lock-taking) read of the current destination state, kept out of the async
    /// `handleAppMessage` so no `NSLock` is acquired across a suspension point.
    private func currentDestinationState() -> (cidrs: [String], enforce: Bool, iface: String?) {
        destinationLock.lock()
        defer { destinationLock.unlock() }
        return (destinationRawCIDRs, enforceDestinationFiltering, tunnelInterfaceName)
    }

    /// Synchronous (lock-taking) read of the cached stats payload, kept out of the async
    /// `handleAppMessage` so no `NSLock` is acquired across a suspension point.
    private func currentStatsPayload() -> Data? {
        statsLock.lock()
        defer { statsLock.unlock() }
        return latestStatsPayload
    }

    /// Order-preserving, de-duplicated union of CIDR strings (trims whitespace, drops empties).
    private static func unionPreservingOrder(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in a + b {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { continue }
            out.append(t)
        }
        return out
    }

    override public func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let signingID = flow.metaData.sourceAppSigningIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signingID.isEmpty else {
            return false
        }
        
        let routed = isRouted(signingID)
        let remote = literalRemoteHostname(from: flow) ?? "unknown"
        let flowTypeName = String(describing: type(of: flow))

        destinationLock.lock()
        // Whenever we intercept a flow we want it exiting via the WireGuard tunnel —
        // that's the whole point of routing the app. The UDS+smoltcp relay
        // (`startTunnelConnection` in TCPFlowRelay) is the only path that reliably
        // reaches utun from this extension's process, since NECP refuses explicit
        // utun binding and `setMetadata` alone doesn't redirect off en0. Destination
        // filtering still narrows WHICH flows are intercepted via `includedNetworkRules`;
        // it no longer gates the tunnel-vs-direct decision here.
        let routeThroughTunnel = true
        let ifaceName = tunnelInterfaceName
        let cidrCount = destinationRawCIDRs.count
        let enforce = enforceDestinationFiltering
        let domainNames = destinationDomainNames
        let preparedRanges = cachedPreparedRanges
        destinationLock.unlock()
        // SNI mode: filtering on AND domain rules present. `includedNetworkRules` is catch-all for
        // TCP in this mode, so we peek each routed TCP flow's TLS SNI and route by name; UDP stays
        // IP-narrowed upstream so it needs no special handling here.
        let sniMode = enforce && !domainNames.isEmpty

        // Detail line at .debug only: in SNI mode `includedNetworkRules` is catch-all TCP, so this
        // fires for EVERY TCP connection from EVERY app on the machine (most are immediately
        // released below). Keeping it at .notice floods the log; the routed `decision=intercept`
        // line below carries what matters at .notice.
        Self.log.debug(
            "[APPSPLIT_FLOW] signingID=\(signingID) remote=\(remote) flowType=\(flowTypeName) routed=\(routed) sniMode=\(sniMode) destCIDRcount=\(cidrCount) iface=\(ifaceName ?? "nil")"
        )

        // Competing-proxy hints only consult flows we decline (`!routed`). In full-traffic /
        // `routeAllIdentifiedFlows` mode every identified flow is routed, so this path stays cold by
        // design — warnings are aimed at explicit per-app selection, where shadowing hurts.
        if !routed {
            noteForeignProxyIfApplicable(signingID)
        }

        guard routed else {
            // .debug: one of these per system-wide non-routed TCP flow in SNI mode — pure noise.
            Self.log.debug("[APPSPLIT_FLOW] decision=release reason=not-routed signingID=\(signingID)")
            return false
        }

        // Destinations on the local network (RFC-1918 / loopback / link-local) aren't reachable
        // across the WireGuard tunnel — the peer has no route back to a private address, so a
        // tunneled flow black-holes. Decline the flow so the OS routes it directly. TCP carries its
        // destination at flow-open (checked here); UDP's remote isn't known until the first datagram,
        // so it's filtered per-datagram in UDPFlowRelay instead.
        if let literal = literalRemoteHostname(from: flow), IPCIDRMatcher.isLocalLiteral(literal) {
            Self.log.notice("[APPSPLIT_FLOW] decision=bypass-local signingID=\(signingID) remote=\(literal)")
            return false
        }

        Self.log.notice("[APPSPLIT_FLOW] decision=intercept signingID=\(signingID) remote=\(remote) routeThroughTunnel=\(routeThroughTunnel)")

        let flowKey = ObjectIdentifier(flow)

        if let tcp = flow as? NEAppProxyTCPFlow {
            let remoteLiteral = literalRemoteHostname(from: tcp)

            // In SNI mode, hand the relay a decider that peeks the TLS ClientHello and routes by
            // hostname: tunnel if the SNI matches a domain rule (suffix) OR the remote IP is in a
            // fixed-IP/resolved CIDR; otherwise direct/en0. Captures only value snapshots + statics,
            // so it's free of `self` and safe to run on the relay's queue.
            let routeDecider: ((Data) -> Bool)? = sniMode ? { firstChunk in
                let sni = TLSClientHelloSNI.serverName(from: firstChunk)
                let ipMatch = remoteLiteral.map { IPCIDRMatcher.literalMatches($0, ranges: preparedRanges) } ?? false
                let tunnel: Bool
                let reason: String
                if let sni {
                    if Self.sniMatches(sni, names: domainNames) {
                        tunnel = true; reason = "sni"
                    } else if ipMatch {
                        tunnel = true; reason = "ip"
                    } else {
                        tunnel = false; reason = "unmatched"
                    }
                } else if ipMatch {
                    // No SNI (non-TLS, or a ClientHello fragmented across segments) → fall back to IP.
                    tunnel = true; reason = "ip-nosni"
                } else {
                    tunnel = false; reason = "no-sni"
                }
                // Summary at .notice carries decision + reason but NO hostname (privacy + volume);
                // the full detail with the SNI hostname is logged at .debug only.
                let decision = tunnel ? "tunnel" : "direct"
                Self.log.notice("[APPSPLIT_SNI] decision=\(decision) reason=\(reason) signingID=\(signingID)")
                Self.log.debug("[APPSPLIT_SNI] detail decision=\(decision) reason=\(reason) host=\(sni ?? "nil") remote=\(remoteLiteral ?? "nil") signingID=\(signingID)")
                return tunnel
            } : nil

            let relay = TCPFlowRelay(
                flow: tcp,
                signingID: signingID,
                routeThroughTunnel: routeThroughTunnel,
                tunnelInterfaceName: ifaceName,
                queue: flowQueue,
                routeDecider: routeDecider,
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
                routeThroughTunnel: routeThroughTunnel,
                tunnelInterfaceName: ifaceName,
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

        Self.log.error("handleNewFlow: routed but unsupported flow type=\(String(describing: type(of: flow)))")
        return false
    }

    /// Records `signingID` as a competing transparent proxy if it matches a known proxy-extension
    /// signature pattern AND is not one of our own bundles. Persists the cumulative set on change.
    private func noteForeignProxyIfApplicable(_ signingID: String) {
        guard looksLikeTransparentProxyExtension(signingID) else { return }
        foreignProxyLock.lock()
        let inserted = observedForeignProxySigningIDs.insert(signingID).inserted
        let snapshot = observedForeignProxySigningIDs
        foreignProxyLock.unlock()
        guard inserted else { return }
        Self.log.notice(
            "noted foreign transparent proxy signingID=\(signingID) totalObserved=\(snapshot.count)"
        )
        persistObservedForeignProxySigningIDs(snapshot)
    }

    private func looksLikeTransparentProxyExtension(_ signingID: String) -> Bool {
        let lower = signingID.lowercased()
        // Ignore our own family — both the host app and our extensions can show up here.
        if lower.hasPrefix("com.tunnelbahn.mac") { return false }
        // Heuristic: NE proxy/filter extensions ship with bundle IDs ending in one of these tokens.
        return lower.hasSuffix(".proxy")
            || lower.hasSuffix(".transparentproxy")
            || lower.hasSuffix(".appproxy")
            || lower.hasSuffix(".networkextension")
            || lower.contains(".transparentproxy.")
            || lower.contains(".appproxy.")
    }

    private func persistObservedForeignProxySigningIDs(_ ids: Set<String>) {
        guard let url = SharedPaths.observedForeignProxySigningIDsFileURL() else { return }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "signingIdentifiers": Array(ids).sorted(),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("persistObservedForeignProxySigningIDs failed: \(error.localizedDescription)")
        }
    }

    private func isRouted(_ signingID: String) -> Bool {
        routedFiltersLock.lock()
        defer { routedFiltersLock.unlock() }
        if routeAllIdentifiedFlows {
            return !signingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return routedSigningIdentifiers.contains(signingID)
    }

    private func runtimeConfigFromProvider() -> TransparentProxyRuntimeConfig? {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else { return nil }
        return TransparentProxyRuntimeConfig.decode(from: proto.providerConfiguration)
    }

    private func refreshRoutedSigningIdentifiers() {
        if let config = runtimeConfigFromProvider() {
            applySigningSnapshot(
                routeAllIdentifiedFlows: config.routeAllIdentifiedFlows,
                signingIdentifiers: config.signingIdentifiers,
                source: "providerConfiguration"
            )
            return
        }

        // Prefer the shared file written by the host app; CFPreferences-backed app-group defaults
        // can fail inside extensions on some macOS configurations.
        guard let fileURL = SharedPaths.perAppRoutedSigningIdentifiersFileURL() else {
            Self.log.notice("refreshRoutedSigningIdentifiers: fileURL is nil")
            return loadFromUserDefaultsOrFallback()
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            Self.log.notice("refreshRoutedSigningIdentifiers: failed to read file")
            return loadFromUserDefaultsOrFallback()
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            Self.log.notice("refreshRoutedSigningIdentifiers: JSON parse failed or empty")
            return loadFromUserDefaultsOrFallback()
        }

        if dict["routeAllIdentifiedFlows"] as? Bool == true {
            applySigningSnapshot(routeAllIdentifiedFlows: true, signingIdentifiers: [], source: "sharedFile")
            return
        }

        guard let fromFile = dict["signingIdentifiers"] as? [String],
              !fromFile.isEmpty else {
            Self.log.notice("refreshRoutedSigningIdentifiers: signingIdentifiers missing or empty")
            return loadFromUserDefaultsOrFallback()
        }

        applySigningSnapshot(
            routeAllIdentifiedFlows: false,
            signingIdentifiers: fromFile,
            source: "sharedFile"
        )
    }

    private func applySigningSnapshot(
        routeAllIdentifiedFlows: Bool,
        signingIdentifiers fromFile: [String],
        source: String
    ) {
        if routeAllIdentifiedFlows {
            routedFiltersLock.lock()
            let wasAll = self.routeAllIdentifiedFlows
            self.routeAllIdentifiedFlows = true
            routedSigningIdentifiers = []
            routedFiltersLock.unlock()
            if !wasAll {
                Self.log.notice("refreshRoutedSigningIdentifiers: routeAllIdentifiedFlows=true source=\(source)")
            }
            return
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
        let previousIDs = routedSigningIdentifiers
        let wasRouteAll = routeAllIdentifiedFlows
        self.routeAllIdentifiedFlows = false
        routedSigningIdentifiers = ids
        routedFiltersLock.unlock()
        if wasRouteAll || ids != previousIDs {
            Self.log.notice(
                "refreshRoutedSigningIdentifiers: loaded \(ids.count) IDs source=\(source): \(ids.sorted().joined(separator: ","))"
            )
        }
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
        let hasDomainNames = !destinationDomainNames.isEmpty
        destinationLock.unlock()
        return buildIncludedNetworkRules(enforce: enforce, cidrs: cidrs, hasDomainNames: hasDomainNames)
    }

    /// Pure rule builder over an explicit destination-state snapshot. Kept off the
    /// `destinationLock` so a caller that has *just* written the state (under the lock) can pass
    /// exactly what it wrote. The previous version re-read the locked fields here, which let a
    /// concurrent `stopProxy` zero them between the write and this read and publish the catch-all
    /// rule set (full-tunnel for routed apps). The no-arg overload above reads a fresh locked
    /// snapshot, which is the right behavior for `startProxy`.
    private func buildIncludedNetworkRules(enforce: Bool, cidrs: [String], hasDomainNames: Bool) -> [NENetworkRule] {
        let catchAll: [NENetworkRule] = [
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .UDP, direction: .outbound),
        ]

        // SNI mode: filtering on AND domain rules present. Intercept ALL outbound TCP so the proxy
        // can peek every flow's TLS SNI (the leaking CDN IPs are in no CIDR), but keep UDP narrowed
        // to the known CIDRs — QUIC can't be SNI-peeked here, so it stays on the IP filter (same
        // coverage as before). The per-TCP-flow decider tunnels SNI/IP matches; the rest exit en0.
        if enforce && hasDomainNames {
            let catchAllTCP = NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .TCP, direction: .outbound)
            let udpRules = udpInterceptRules(for: cidrs)
            Self.log.notice("buildIncludedNetworkRules: SNI mode — catch-all TCP + \(udpRules.count) UDP CIDR rules")
            return [catchAllTCP] + udpRules
        }

        guard enforce, !cidrs.isEmpty else { return catchAll }

        var rules: [NENetworkRule] = []
        for cidr in cidrs {
            let routingCIDR = Self.widenIPv4HostRoute(cidr)
            let parts = routingCIDR.split(separator: "/")
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
        Self.log.notice("buildIncludedNetworkRules: split-tunnel \(rules.count) rules for \(cidrs.count) CIDRs")
        return rules
    }

    /// UDP-only intercept rules for the given CIDRs (widening /32 host routes to /24 for CDN
    /// rotation), used in SNI mode where TCP is catch-all but UDP stays IP-narrowed.
    private func udpInterceptRules(for cidrs: [String]) -> [NENetworkRule] {
        var rules: [NENetworkRule] = []
        for cidr in cidrs {
            let routingCIDR = Self.widenIPv4HostRoute(cidr)
            let parts = routingCIDR.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { continue }
            let endpoint = NWHostEndpoint(hostname: String(parts[0]), port: "0")
            rules.append(NENetworkRule(remoteNetwork: endpoint, remotePrefix: prefix, localNetwork: nil, localPrefix: 0, protocol: .UDP, direction: .outbound))
        }
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

    /// Widen resolved /32 host routes to /24 so CDN address rotation still matches intercept rules.
    private static func widenIPv4HostRoute(_ cidr: String) -> String {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix == 32 else { return cidr }
        let ip = String(parts[0])
        guard ip.contains(".") else { return cidr }
        var octets = ip.split(separator: ".")
        guard octets.count == 4 else { return cidr }
        octets[3] = "0"
        return "\(octets.joined(separator: "."))/24"
    }

    private func refreshDestinationConfig() {
        if let config = runtimeConfigFromProvider() {
            applyDestinationPayload(
                enforce: config.destinationRouting.enforceDestinationFiltering,
                rawCIDRs: config.destinationRouting.ranges,
                ifaceName: config.packetTunnelInterfaceName,
                source: "providerConfiguration",
                domainNames: config.destinationRouting.domainNames
            )
            return
        }

        guard let fileURL = SharedPaths.destinationRangesFileURL() else {
            Self.log.notice("refreshDestinationConfig fileURL nil")
            applyDestinationPayload(enforce: false, rawCIDRs: [], ifaceName: nil, source: "none")
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            Self.log.notice("refreshDestinationConfig: file missing/unreadable \(fileURL.lastPathComponent)")
            applyDestinationPayload(enforce: false, rawCIDRs: [], ifaceName: nil, source: "none")
            return
        }
        do {
            let payload = try JSONDecoder().decode(DestinationRoutingFilePayload.self, from: data)
            applyDestinationPayload(
                enforce: payload.enforceDestinationFiltering,
                rawCIDRs: payload.ranges,
                ifaceName: nil,
                source: "sharedFile",
                domainNames: payload.domainNames
            )
        } catch {
            Self.log.notice(
                "refreshDestinationConfig decode failed \(error.localizedDescription)"
            )
            applyDestinationPayload(enforce: false, rawCIDRs: [], ifaceName: nil, source: "none")
        }
    }

    /// `domainNames == nil` leaves the SNI name set unchanged (used by the appMessage live-push,
    /// which only ever carries newly-resolved IPs — names are static for a session). A non-nil
    /// value replaces the set (lowercased).
    private func applyDestinationPayload(enforce: Bool, rawCIDRs: [String], ifaceName: String?, source: String, domainNames: [String]? = nil) {
        destinationLock.lock()
        // Union, never replace, within a session. Three writers race for this set — `startProxy`
        // (providerConfiguration baseline), the 1.5s `flushOnce` (re-reads the same baseline), and
        // host `appMessage` pushes (newly-resolved IPs) — and they can arrive in any order. A
        // replace let whichever ran last win, so a providerConfiguration re-apply would wipe an
        // appMessage's freshly-learned IP (and vice versa). Unioning makes order irrelevant. The
        // set is cleared in `stopProxy` so it can't accumulate across sessions (the extension
        // process is reused across stop/start). Shrinking only happens on reconnect — the safe
        // direction for a split-tunnel filter.
        let merged = Self.unionPreservingOrder(destinationRawCIDRs, rawCIDRs)
        let rangesChanged = merged != destinationRawCIDRs
        let newNames = domainNames?.map { $0.lowercased() } ?? destinationDomainNames
        let namesChanged = newNames != destinationDomainNames
        let changed = enforce != enforceDestinationFiltering || rangesChanged || namesChanged
        enforceDestinationFiltering = enforce
        destinationRawCIDRs = merged
        destinationDomainNames = newNames
        if rangesChanged {
            cachedPreparedRanges = IPCIDRMatcher.prepare(merged)
        }
        if let ifaceName {
            tunnelInterfaceName = ifaceName
        }
        destinationLock.unlock()

        guard changed else { return }
        // Log the actual SNI names (capped) — not just the count — so a "count right, string wrong"
        // mismatch (trailing dot, casing) is visible here instead of only inferable per-flow.
        let namesPreview = newNames.prefix(12).joined(separator: ",")
        Self.log.notice(
            "applyDestinationPayload: enforce=\(enforce) ranges=\(merged.count) domains=\(newNames.count) names=[\(namesPreview)] iface=\(ifaceName ?? "nil") source=\(source)"
        )
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // Build from the snapshot we just wrote under the lock (`enforce`/`merged`/`newNames`),
        // NOT a fresh re-read: a concurrent `stopProxy` could zero the destination state between
        // the unlock above and rule-building, making a re-read return — and publish — the
        // catch-all set (full-tunnel for routed apps) instead of the CIDR-narrowed rules.
        settings.includedNetworkRules = buildIncludedNetworkRules(
            enforce: enforce, cidrs: merged, hasDomainNames: !newNames.isEmpty
        )
        setTunnelNetworkSettings(settings) { error in
            if let error {
                Self.log.error("applyDestinationPayload setTunnelNetworkSettings failed: \(error.localizedDescription)")
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
        let summary = (rules: rules.count, rolledUp: rolledUp.count, destinations: perDestination.count)
        if lastLoggedFlushSummary.map({ $0 != summary }) ?? true {
            lastLoggedFlushSummary = summary
            Self.log.notice(
                "flushOnce: rules=\(summary.rules) rolledUp=\(summary.rolledUp) destinations=\(summary.destinations)"
            )
        }
        let stats = PerAppTransferStats(
            schemaVersion: PerAppTransferStats.currentSchemaVersion,
            apps: rolledUp,
            lastUpdate: .now,
            perDestination: perDestination
        )
        // Cache for the host's `getStats` IPC pull — this, not the file write below, is what
        // actually reaches the host across the uid boundary.
        if let payload = try? Self.statsEncoder.encode(stats) {
            statsLock.lock()
            latestStatsPayload = payload
            statsLock.unlock()
        }
        do {
            try PerAppTransferStore.write(stats)
        } catch {
            Self.log.error("failed to flush app-tunnel stats: \(error.localizedDescription)")
        }

        flushExtensionResourceStats()
    }

    private func flushExtensionResourceStats() {
        // Runs on `flushQueue` (via the flush timer). `sampleResources()` keeps all sampler
        // access on that one queue so its cross-sample state can't race the IPC reader.
        let sample = sampleResources()
        var merged = ExtensionResourceStore.read()
        merged.transparentProxyCPU = sample.cpuPercent
        merged.transparentProxyMemory = sample.memoryBytes
        merged.lastUpdate = .now
        merged.schemaVersion = ExtensionResourceStats.currentSchemaVersion
        do {
            try ExtensionResourceStore.write(merged)
        } catch {
            Self.log.error("failed to flush extension resource stats: \(error.localizedDescription)")
        }
    }

    /// Serializes `resourceSampler` on `flushQueue`. The sampler carries time-delta state between
    /// calls and is not thread-safe, while `getResourceStats` IPC arrives on a different queue than
    /// the flush timer — funneling both through `flushQueue` keeps the smoothed value coherent.
    private func sampleResources() -> ProcessResourceSampler.Sample {
        if DispatchQueue.getSpecific(key: Self.flushQueueKey) != nil {
            return resourceSampler.sample()
        }
        return flushQueue.sync { resourceSampler.sample() }
    }
}

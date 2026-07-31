import Foundation
import Network
import NetworkExtension
import os.log

/// UDP relay between an `NEAppProxyUDPFlow` and outbound datagram sockets.
/// Tunnel path (WG mode): per-destination XPC relay flows into the packet-tunnel's smoltcp
/// stack (`TransparentProxyRelayClient.openFlow(isTCP: false)` → BoringTun), mirroring
/// `TCPFlowRelay.startTunnelConnection`. The previous `RelayOutboundConnection` (raw
/// `nw_connection`) path followed SYSTEM routing — the extension's own sockets are not
/// captured by the per-app VPN — so every "tunneled" datagram silently egressed on the real
/// interface (measured: 0 inner-UDP packets reached the server; DNS leaked to the local
/// resolver). Direct path (local/LAN destinations) still uses plain `NWConnection`.
final class UDPFlowRelay {
    private static let log = AppLog(
        subsystem: "com.tunnelbahn.mac.transparentproxy",
        category: "UDPRelay"
    )

    private static let relayFailureError = NSError(
        domain: "com.tunnelbahn.mac.transparentproxy",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Relay to destination failed"]
    )

    private let flow: NEAppProxyUDPFlow
    private let signingID: String
    private let routeThroughTunnel: Bool
    /// True in SSH-transport mode. SSH forwards only TCP, so the tunnel path
    /// (`RelayOutboundConnection` → WG utun) has no backing in this mode; would-be-tunneled
    /// datagrams are dropped instead of dialed. Never routes them via `sendViaDirect` — that would
    /// leak the traffic outside the tunnel. See project memory: SSH transport UDP no-leak.
    private let dropTunneledUDP: Bool
    /// WG mode: tunnel-side DNS resolver IP. A tunneled app's UDP DNS query aimed at a
    /// local/private resolver (which `shouldBypassLocal` would hand to the — possibly
    /// hijacking — local resolver) is instead rewritten to this server and relayed THROUGH
    /// the tunnel. Responses are written back to the app as if they came from the original
    /// resolver, so the redirect is invisible to the app. nil = disabled (SSH mode).
    private let tunnelDNSHost: String?
    private let tunnelInterfaceName: String?
    /// Session-static destination-filter semantics. In `.exclude` mode `tunnelRanges()` holds
    /// the DIRECT set: a matching datagram exits via `sendViaDirect`, everything else tunnels,
    /// and the private-range tunnel override in `shouldBypassLocal` never applies.
    private let filterMode: DestinationFilterMode
    private let queue: DispatchQueue
    /// Live snapshot of the user's configured tunnel destination ranges (CIDRs + resolved domain
    /// IPs). A closure, not a value: resolved-domain IPs are live-pushed mid-session, and UDP
    /// decides per-datagram, so each decision must see the current set.
    private let tunnelRanges: () -> [IPCIDRMatcher.PreparedRange]
    private let onTx: (UInt64) -> Void
    private let onRx: (UInt64) -> Void
    private let onClose: () -> Void

    /// One XPC relay flow per original destination. `pending` buffers datagrams that arrive
    /// between the openFlow request and its reply (the reply is async); `isOpen` flips once and
    /// `pending` drains in order. All mutation on `queue`.
    private final class TunnelUDPFlow {
        let flowID: UInt64
        var isOpen = false
        var pending: [Data] = []
        init(flowID: UInt64) { self.flowID = flowID }
    }

    /// Cap on datagrams buffered while an open is in flight (a QUIC burst can be large; DNS
    /// needs only a few). Beyond this, drop — UDP semantics.
    private static let maxPendingPerDestination = 32

    // Tunnel path: keyed by ORIGINAL "host:port" (even when DNS-redirected, so responses map
    // back to the endpoint the app actually targeted).
    private var tunnelFlows: [String: TunnelUDPFlow] = [:]
    // Direct path: keyed by "host:port"
    private var nwConnections: [String: NWConnection] = [:]
    private var legacyEndpoints: [String: NWHostEndpoint] = [:]
    // Exclude-match memoization: in exclude mode the linear CIDR scan would otherwise run
    // per datagram against a country-size list (~5-8k ranges) for ALL routed UDP (QUIC
    // included) — unlike include mode, where interception is CIDR-narrowed upstream and the
    // autoclosure keeps the scan off the hot path. Keyed by destination host; the exclude
    // set can only GROW mid-session (appMessage pushes resolved excluded-domain IPs), so
    // invalidate on size change. A stale entry errs toward tunneling — the safe direction.
    // All access on `queue` (same discipline as the connection dictionaries).
    private var excludeVerdictCache: [String: Bool] = [:]
    private var excludeCacheRangeCount = -1
    /// Guards the one-shot `didCloseOnce` test-and-set against finish paths arriving on different
    /// queues (NE flow callbacks vs the relay connection's queue). See `TCPFlowRelay.closeLock`.
    private let closeLock = NSLock()
    private var didCloseOnce = false
    /// One-shot guard so the `[APPSPLIT_SSH] udp-drop` line logs once per flow, not once per
    /// datagram (a dropped QUIC flow can retransmit at high rate).
    private var loggedUDPDropOnce = false

    init(
        flow: NEAppProxyUDPFlow,
        signingID: String,
        routeThroughTunnel: Bool,
        dropTunneledUDP: Bool,
        filterMode: DestinationFilterMode = .include,
        tunnelDNSHost: String? = nil,
        tunnelInterfaceName: String?,
        queue: DispatchQueue,
        tunnelRanges: @escaping () -> [IPCIDRMatcher.PreparedRange],
        onTx: @escaping (UInt64) -> Void,
        onRx: @escaping (UInt64) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.flow = flow
        self.signingID = signingID
        self.routeThroughTunnel = routeThroughTunnel
        self.dropTunneledUDP = dropTunneledUDP
        self.filterMode = filterMode
        self.tunnelDNSHost = tunnelDNSHost
        self.tunnelInterfaceName = tunnelInterfaceName
        self.queue = queue
        self.tunnelRanges = tunnelRanges
        self.onTx = onTx
        self.onRx = onRx
        self.onClose = onClose
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("UDP flow.open failed: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            Self.log.notice(
                "UDP flow.open succeeded signingID=\(self.signingID) tunnel=\(self.routeThroughTunnel)"
            )
            self.queue.async {
                self.relayAppToRemote()
            }
        }
    }

    private func relayAppToRemote() {
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self else { return }
            if let error {
                Self.log.debug("UDP readDatagrams error: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            guard let datagrams, let endpoints, !datagrams.isEmpty else {
                Self.log.debug("UDP readDatagrams empty (EOF?) signingID=\(self.signingID)")
                self.finishSuccessfully()
                return
            }
            // Hop to `queue` before touching the connection dictionaries. `send` mutates
            // tunnelFlows/nwConnections/legacyEndpoints, but `readDatagrams` delivers on the NE flow's
            // callback queue — not `queue` — so doing it inline raced the receive/teardown paths and
            // corrupted the dictionaries (the SIGSEGV in `scheduleDirectTeardown` →
            // `removeValue(forKey:)`). Serialize all dictionary access onto `queue`.
            self.queue.async {
                for (datagram, legacyEndpoint) in zip(datagrams, endpoints) {
                    guard let hostEndpoint = legacyEndpoint as? NWHostEndpoint else { continue }
                    self.send(datagram: datagram, to: hostEndpoint)
                }
                self.relayAppToRemote()
            }
        }
    }

    private func send(datagram: Data, to legacyEndpoint: NWHostEndpoint) {
        let key = endpointKey(legacyEndpoint)
        legacyEndpoints[key] = legacyEndpoint

        // Per-destination decision: a private/local address (the system DNS resolver typically lives
        // on one) can't be reached through the WireGuard peer, so it must go direct even when the
        // flow is otherwise routed — otherwise DNS and LAN traffic black-hole. UDP's remote is only
        // known here (per datagram), which is why this can't be decided up in handleNewFlow.
        // Same predicate as the TCP flow-open check (IPCIDRMatcher.shouldBypassLocal): a
        // routable-private destination the user explicitly configured to tunnel is not bypassed.
        // tunnelRanges() (a lock-guarded live read) is only evaluated for local-literal remotes,
        // via the predicate's autoclosure.
        // Exclude mode: a destination in the user's ranges goes DIRECT (tunnelRanges holds the
        // exclude set); and a listed private CIDR can never mean "tunnel", so the bypass check
        // gets no override ranges. Include mode is byte-for-byte the previous behavior.
        let excluded = filterMode == .exclude && isExcluded(legacyEndpoint.hostname)
        var useTunnel = routeThroughTunnel
            && !excluded
            && !IPCIDRMatcher.shouldBypassLocal(
                legacyEndpoint.hostname,
                tunnelRanges: filterMode == .exclude ? [] : tunnelRanges()
            )
        // DNS redirect (WG mode only): a routed app's DNS query to a local/private resolver
        // would bypass to the — possibly hijacking/sinkholing — local network. Rewrite it to the
        // tunnel-side resolver and relay it through the tunnel instead. The flow key stays the
        // ORIGINAL endpoint, so responses are written back `sentBy` the resolver the app asked.
        var targetHost = legacyEndpoint.hostname
        var targetPort = legacyEndpoint.port
        if routeThroughTunnel, !dropTunneledUDP, !useTunnel, !excluded,
           legacyEndpoint.port == "53", let redirect = tunnelDNSHost {
            useTunnel = true
            targetHost = redirect
            targetPort = "53"
        }
        if useTunnel && dropTunneledUDP {
            // SSH transport: no WG utun backs the tunnel path, so a would-be-tunneled datagram
            // is dropped here — deterministically, and WITHOUT falling through to sendViaDirect,
            // which would leak it outside the tunnel. The local-resolver/LAN bypass path above
            // (the `else` below) is untouched: only the tunnel branch is affected.
            if !loggedUDPDropOnce {
                loggedUDPDropOnce = true
                Self.log.debug(
                    "[APPSPLIT_SSH] udp-drop signingID=\(self.signingID) remote=\(legacyEndpoint.hostname):\(legacyEndpoint.port)"
                )
            }
            return
        }
        if useTunnel {
            sendViaTunnel(datagram: datagram, key: key, targetHost: targetHost, targetPort: targetPort)
        } else {
            sendViaDirect(datagram: datagram, to: legacyEndpoint, key: key)
        }
    }

    /// Memoized exclude-set membership for `host` (see `excludeVerdictCache` doc).
    private func isExcluded(_ host: String) -> Bool {
        let ranges = tunnelRanges()
        if ranges.count != excludeCacheRangeCount {
            excludeVerdictCache.removeAll()
            excludeCacheRangeCount = ranges.count
        }
        if let cached = excludeVerdictCache[host] { return cached }
        let verdict = IPCIDRMatcher.literalMatches(host, ranges: ranges)
        excludeVerdictCache[host] = verdict
        return verdict
    }

    // MARK: - Tunnel path (XPC → packet-tunnel smoltcp UDP → BoringTun)

    /// Runs on `queue`. Opens (once per destination) an XPC relay flow into the packet tunnel's
    /// smoltcp stack and sends each datagram over it. Fail-closed: if the open fails, datagrams
    /// are dropped — never re-dialed on the real interface (that would leak tunnel traffic).
    private func sendViaTunnel(datagram: Data, key: String, targetHost: String, targetPort: String) {
        if let existing = tunnelFlows[key] {
            if existing.isOpen {
                onTx(UInt64(datagram.count))
                TransparentProxyRelayClient.shared.sendPayload(flowID: existing.flowID, data: datagram) { _ in }
            } else if existing.pending.count < Self.maxPendingPerDestination {
                existing.pending.append(datagram)
            }
            return
        }
        guard let port = UInt16(targetPort) else {
            Self.log.error("UDP tunnel invalid target port signingID=\(self.signingID) target=\(targetHost):\(targetPort)")
            return
        }
        let tunnelFlow = TunnelUDPFlow(flowID: TCPFlowRelay.allocateFlowID())
        tunnelFlow.pending.append(datagram)
        tunnelFlows[key] = tunnelFlow
        Self.log.notice(
            "UDP tunnel XPC open signingID=\(self.signingID) key=\(key) target=\(targetHost):\(targetPort) flowID=\(tunnelFlow.flowID)"
        )
        TransparentProxyRelayClient.shared.openFlow(
            flowID: tunnelFlow.flowID,
            remoteHost: targetHost,
            remotePort: port,
            isTCP: false,
            onReceive: { [weak self] data in
                guard let self else { return }
                self.queue.async {
                    guard let legacy = self.legacyEndpoints[key] else { return }
                    self.onRx(UInt64(data.count))
                    self.flow.writeDatagrams([data], sentBy: [legacy]) { writeError in
                        if let writeError {
                            Self.log.debug("UDP writeDatagrams error: \(writeError.localizedDescription)")
                        }
                    }
                }
            },
            onClose: { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    // Per-destination teardown only (a UDP flow multiplexes many remotes); the
                    // app flow itself stays up. Removing the entry lets a later datagram retry.
                    if let cur = self.tunnelFlows[key], cur === tunnelFlow {
                        self.tunnelFlows.removeValue(forKey: key)
                    }
                    if let error {
                        Self.log.debug("UDP tunnel XPC flow closed key=\(key): \(error)")
                    }
                }
            }
        ) { [weak self] ok in
            guard let self else { return }
            self.queue.async {
                guard let cur = self.tunnelFlows[key], cur === tunnelFlow else { return }
                let pending = tunnelFlow.pending
                tunnelFlow.pending = []
                if ok {
                    tunnelFlow.isOpen = true
                    for d in pending {
                        self.onTx(UInt64(d.count))
                        TransparentProxyRelayClient.shared.sendPayload(flowID: tunnelFlow.flowID, data: d) { _ in }
                    }
                } else {
                    // Fail closed: drop buffered datagrams, remove the entry so a retransmit
                    // can retry the open (e.g. tunnel not ready yet during connect).
                    Self.log.error("UDP tunnel XPC open failed signingID=\(self.signingID) key=\(key)")
                    self.tunnelFlows.removeValue(forKey: key)
                }
            }
        }
    }

    // MARK: - Direct path

    private func sendViaDirect(datagram: Data, to legacyEndpoint: NWHostEndpoint, key: String) {
        if nwConnections[key] == nil {
            guard let conn = makeDirectConnection(to: legacyEndpoint) else { return }
            nwConnections[key] = conn
            startDirectReadLoop(on: conn, key: key)
            conn.start(queue: queue)
        }
        // Direct path bytes never traversed the WireGuard tunnel (this datagram went to a
        // local/private dest, e.g. the system DNS resolver), so they must NOT be added to the
        // per-app tunnel accounting — mirrors TCPFlowRelay.countTx gating on routeThroughTunnel.
        guard let conn = nwConnections[key] else { return }
        conn.send(content: datagram, completion: .contentProcessed { [weak self, weak conn] error in
            if let error {
                // Per-destination failure only — see the matching note in sendViaTunnel.
                Self.log.debug("UDP direct send error: \(error.localizedDescription)")
                self?.scheduleDirectTeardown(key: key, connection: conn)
            }
        })
    }

    private func makeDirectConnection(to legacyEndpoint: NWHostEndpoint) -> NWConnection? {
        guard let modern = EndpointBridge.modernize(legacyEndpoint) else { return nil }
        Self.log.notice(
            "UDP direct NWConnection signingID=\(self.signingID) remote=\(legacyEndpoint.hostname):\(legacyEndpoint.port)"
        )
        return NWConnection(to: modern, using: .udp)
    }

    private func startDirectReadLoop(on connection: NWConnection, key: String) {
        // `[weak connection]` avoids a connection↔handler retain cycle; teardown is
        // always deferred (never run the release synchronously inside this handler).
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                self?.scheduleDirectTeardown(key: key, connection: connection)
            default:
                break
            }
        }
        directReceiveLoop(on: connection, key: key)
    }

    private func directReceiveLoop(on connection: NWConnection, key: String) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let legacy = self.legacyEndpoints[key] {
                // Direct-path receive bytes did not traverse the tunnel — do not count them into
                // per-app tunnel accounting (see the matching note in sendViaDirect).
                self.flow.writeDatagrams([data], sentBy: [legacy]) { writeError in
                    if let writeError {
                        Self.log.debug("UDP writeDatagrams error: \(writeError.localizedDescription)")
                    }
                }
            }
            if let error {
                Self.log.debug("UDP direct receive error: \(error.localizedDescription)")
                self.scheduleDirectTeardown(key: key, connection: connection)
                return
            }
            if isComplete {
                self.scheduleDirectTeardown(key: key, connection: connection)
                return
            }
            self.directReceiveLoop(on: connection, key: key)
        }
    }

    /// Lifetime-safe teardown of one direct NWConnection. Always hops to `queue`
    /// (serial) so we never drop the connection's last reference from inside its own
    /// state/receive callback — that synchronous release is a use-after-free that
    /// segfaults in objc_release. Idempotent via an identity check so repeated
    /// state transitions (and `cancelAll`) can't double-free.
    private func scheduleDirectTeardown(key: String, connection: NWConnection?) {
        queue.async { [weak self] in
            guard let self, let connection, self.nwConnections[key] === connection else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            self.nwConnections.removeValue(forKey: key)
            self.legacyEndpoints.removeValue(forKey: key)
        }
    }

    // MARK: - Lifecycle

    private func endpointKey(_ endpoint: NWHostEndpoint) -> String {
        "\(endpoint.hostname):\(endpoint.port)"
    }

    private func failureNSError(underlying: Error?) -> NSError {
        guard let underlying else { return Self.relayFailureError }
        return NSError(
            domain: (Self.relayFailureError as NSError).domain,
            code: (Self.relayFailureError as NSError).code,
            userInfo: [
                NSLocalizedDescriptionKey: (Self.relayFailureError as NSError).localizedDescription,
                NSUnderlyingErrorKey: underlying,
            ]
        )
    }

    private func takeFinishToken() -> Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        if didCloseOnce { return false }
        didCloseOnce = true
        return true
    }

    private func finishSuccessfully() {
        guard takeFinishToken() else { return }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        cancelAll()
        onClose()
    }

    private func finishDueToFailure(underlying: Error? = nil) {
        guard takeFinishToken() else { return }
        let err = failureNSError(underlying: underlying)
        flow.closeReadWithError(err)
        flow.closeWriteWithError(err)
        cancelAll()
        onClose()
    }

    private func cancelAll() {
        // Serialize onto `queue` with all other connection-dictionary access. `finish*` (and thus
        // `cancelAll`) is also invoked from NE flow callbacks, so mutating these dicts inline raced
        // `removeValue` running on `queue` and corrupted them. Strong `self` so the connections are
        // still cancelled even if this async holds the last reference.
        queue.async {
            for tunnelFlow in self.tunnelFlows.values {
                TransparentProxyRelayClient.shared.closeFlow(flowID: tunnelFlow.flowID)
            }
            self.tunnelFlows.removeAll(keepingCapacity: false)
            for conn in self.nwConnections.values {
                // Clear the handler first so the .cancelled transition can't re-enter
                // teardown while we're dropping the reference here.
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
            self.nwConnections.removeAll(keepingCapacity: false)
            self.legacyEndpoints.removeAll(keepingCapacity: false)
        }
    }
}

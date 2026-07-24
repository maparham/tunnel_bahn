import Foundation
import Network
import NetworkExtension
import os.log

/// UDP relay between an `NEAppProxyUDPFlow` and outbound datagram sockets.
/// When `routeThroughTunnel` is true, each per-destination connection is created via
/// `RelayOutboundConnection` which binds it to the WireGuard utun interface.
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
    private let tunnelInterfaceName: String?
    private let queue: DispatchQueue
    /// Live snapshot of the user's configured tunnel destination ranges (CIDRs + resolved domain
    /// IPs). A closure, not a value: resolved-domain IPs are live-pushed mid-session, and UDP
    /// decides per-datagram, so each decision must see the current set.
    private let tunnelRanges: () -> [IPCIDRMatcher.PreparedRange]
    private let onTx: (UInt64) -> Void
    private let onRx: (UInt64) -> Void
    private let onClose: () -> Void

    // Tunnel path: keyed by "host:port"
    private var relayConns: [String: RelayOutboundConnection] = [:]
    // Direct path: keyed by "host:port"
    private var nwConnections: [String: NWConnection] = [:]
    private var legacyEndpoints: [String: NWHostEndpoint] = [:]
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
            // relayConns/nwConnections/legacyEndpoints, but `readDatagrams` delivers on the NE flow's
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
        let useTunnel = routeThroughTunnel
            && !IPCIDRMatcher.shouldBypassLocal(legacyEndpoint.hostname, tunnelRanges: tunnelRanges())
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
            sendViaTunnel(datagram: datagram, to: legacyEndpoint, key: key)
        } else {
            sendViaDirect(datagram: datagram, to: legacyEndpoint, key: key)
        }
    }

    // MARK: - Tunnel path

    private func sendViaTunnel(datagram: Data, to legacyEndpoint: NWHostEndpoint, key: String) {
        if relayConns[key] == nil {
            guard let conn = makeTunnelConnection(to: legacyEndpoint) else { return }
            relayConns[key] = conn
            startTunnelReadLoop(on: conn, key: key)
            conn.start(queue: queue) { [weak self, weak conn] (isReady: Bool, error: Error?) in
                guard let self else { return }
                if !isReady {
                    Self.log.debug("UDP tunnel conn failed for key=\(key): \(error?.localizedDescription ?? "cancelled")")
                    self.scheduleTunnelTeardown(key: key, connection: conn)
                }
            }
        }
        onTx(UInt64(datagram.count))
        guard let conn = relayConns[key] else { return }
        conn.sendData(datagram) { [weak self, weak conn] (error: Error?) in
            if let error {
                // One dead destination must not kill the whole flow — a UDP flow multiplexes
                // many remotes (e.g. a racing resolver, where one ICMP-unreachable DNS server
                // would take down all the others). Tear down just this destination's
                // connection; the flow only finishes when the flow itself dies.
                Self.log.debug("UDP tunnel send error: \(error.localizedDescription)")
                self?.scheduleTunnelTeardown(key: key, connection: conn)
            }
        }
    }

    private func makeTunnelConnection(to legacyEndpoint: NWHostEndpoint) -> RelayOutboundConnection? {
        // See TCPFlowRelay.startTunnelConnection: we deliberately do NOT bind to the utun
        // interface. Routing is handled by the proxy extension's NEAppRule on the per-app
        // VPN plus [flow setMetadata:params] in RelayOutboundBridge.m.
        let conn: RelayOutboundConnection? = legacyEndpoint.hostname.withCString { hostCStr in
            legacyEndpoint.port.withCString { portCStr in
                RelayOutboundConnection.makeConnection(flow: flow,
                                                       hostname: hostCStr,
                                                       port: portCStr,
                                                       isTCP: false,
                                                       interfaceName: nil)
            }
        }
        if conn == nil {
            Self.log.error(
                "UDP RelayOutboundConnection returned nil signingID=\(self.signingID) remote=\(legacyEndpoint.hostname):\(legacyEndpoint.port)"
            )
        } else {
            Self.log.notice(
                "UDP tunnel RelayOutboundConnection signingID=\(self.signingID) remote=\(legacyEndpoint.hostname):\(legacyEndpoint.port)"
            )
        }
        return conn
    }

    private func startTunnelReadLoop(on conn: RelayOutboundConnection, key: String) {
        conn.receiveMessage { [weak self] (data: Data?, isComplete: Bool, error: Error?) in  // receiveMessage(completion:)
            guard let self else { return }
            if let data, !data.isEmpty, let legacy = self.legacyEndpoints[key] {
                self.onRx(UInt64(data.count))
                self.flow.writeDatagrams([data], sentBy: [legacy]) { writeError in
                    if let writeError {
                        Self.log.debug("UDP writeDatagrams error: \(writeError.localizedDescription)")
                    }
                }
            }
            if let error {
                Self.log.debug("UDP tunnel receive error: \(error.localizedDescription)")
                self.scheduleTunnelTeardown(key: key, connection: conn)
                return
            }
            if isComplete {
                self.scheduleTunnelTeardown(key: key, connection: conn)
                return
            }
            self.startTunnelReadLoop(on: conn, key: key)
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

    /// Tunnel-path counterpart of `scheduleDirectTeardown`: same deferred hop to `queue` (never
    /// drop the connection's last reference inside its own callback), same identity check for
    /// idempotence. Cancels before dropping — the previous bare `removeValue` leaked the
    /// connection's internal resources.
    private func scheduleTunnelTeardown(key: String, connection: RelayOutboundConnection?) {
        queue.async { [weak self] in
            guard let self, let connection, self.relayConns[key] === connection else { return }
            connection.cancel()
            self.relayConns.removeValue(forKey: key)
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
            for conn in self.relayConns.values { conn.cancel() }
            self.relayConns.removeAll(keepingCapacity: false)
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

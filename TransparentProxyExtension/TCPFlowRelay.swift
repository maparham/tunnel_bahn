import Foundation
import Network
import NetworkExtension
import os.log

/// Bidirectional TCP relay between an `NEAppProxyTCPFlow` and the real destination.
///
/// Two outbound paths:
/// - `routeThroughTunnel == true`: relay over the UDS link to the packet-tunnel ext,
///   where smoltcp + BoringTun deliver the bytes through the WireGuard utun. Used when
///   destination filtering is on (the in-CIDR subset).
/// - `routeThroughTunnel == false`: outbound is an `RelayOutboundConnection` (Network
///   framework via the ObjC bridge) which calls `-[NEAppProxyFlow setMetadata:]` on the
///   `nw_parameters_t`. That propagates the source app's identity onto the new socket,
///   so the per-app VPN's NEAppRules apply to the outbound connection. Without that,
///   the socket inherits the proxy extension's identity and exits via the default
///   route (en0), bypassing utun entirely — that was the S3 regression.
final class TCPFlowRelay {
    private static let log = AppLog(
        subsystem: "com.tunnelbahn.mac.transparentproxy",
        category: "TCPRelay"
    )

    private static let relayFailureError = NSError(
        domain: "com.tunnelbahn.mac.transparentproxy",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Relay to destination failed"]
    )

    // Monotonic flowID source. The prior `ObjectIdentifier(self).hashValue` exposed Swift's
    // pointer reuse: a deallocated TCPFlowRelay's address could be recycled by a newly
    // allocated one and collide with a stale entry in the tunnel-side relay bridge.
    private static let flowIDLock = NSLock()
    private static var nextFlowID: UInt64 = 1
    private static func allocateFlowID() -> UInt64 {
        flowIDLock.lock()
        defer { flowIDLock.unlock() }
        let id = nextFlowID
        nextFlowID &+= 1
        return id
    }

    private let flow: NEAppProxyTCPFlow
    private let signingID: String
    /// Final outbound path. A `let` for the legacy (no-peek) callers; mutated once by the SNI peek
    /// before any outbound connection is made.
    private var routeThroughTunnel: Bool
    private let tunnelInterfaceName: String?
    private let queue: DispatchQueue
    private let onTx: (UInt64) -> Void
    private let onRx: (UInt64) -> Void
    private let onClose: () -> Void
    /// When set, the relay opens the flow, peeks the first app→remote chunk (the TLS ClientHello),
    /// and calls this to decide tunnel (`true`) vs direct/en0 (`false`) BEFORE connecting outbound.
    /// nil = legacy behavior: route per the `routeThroughTunnel` passed at init, no peek.
    private let routeDecider: ((Data) -> Bool)?
    /// When true (SSH mode), a recovered SNI name is used as the outbound target so the SSH
    /// server resolves it. WG mode leaves this false and always targets the numeric IP.
    private let remoteDNS: Bool
    /// SNI recovered during the peek (lowercased) or nil. Set once in `peekFirstChunk`.
    private var sniName: String?

    private var directRelay: RelayOutboundConnection?
    private var xpcFlowID: UInt64?
    /// Guards the one-shot `didCloseOnce` test-and-set. Finish paths fire from multiple queues —
    /// the NE flow's internal callback queue (`flow.readData`/`flow.write`), the relay client's
    /// `onClose` queue, and `flowQueue` — so an unguarded read-modify-write let two of them both
    /// observe `false`, both proceed, and double-close the flow (UB per NE) plus double-invoke
    /// `onClose`. Held only for the test-and-set, never across the close calls themselves.
    private let closeLock = NSLock()
    private var didCloseOnce = false
    /// First app→remote chunk captured during the SNI peek. Replayed to the chosen outbound before
    /// the normal read loop resumes, so the server still receives the original ClientHello.
    private var pendingFirstChunk: Data?

    init(
        flow: NEAppProxyTCPFlow,
        signingID: String,
        routeThroughTunnel: Bool,
        tunnelInterfaceName: String?,
        queue: DispatchQueue,
        routeDecider: ((Data) -> Bool)? = nil,
        remoteDNS: Bool = false,
        onTx: @escaping (UInt64) -> Void,
        onRx: @escaping (UInt64) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.flow = flow
        self.signingID = signingID
        self.routeThroughTunnel = routeThroughTunnel
        self.tunnelInterfaceName = tunnelInterfaceName
        self.queue = queue
        self.routeDecider = routeDecider
        self.remoteDNS = remoteDNS
        self.onTx = onTx
        self.onRx = onRx
        self.onClose = onClose
    }

    /// Byte counters fire only for tunneled flows — direct/en0 (bypass) bytes never traversed the
    /// VPN, so counting them would inflate the per-app tunnel stats.
    private func countTx(_ n: UInt64) { if routeThroughTunnel { onTx(n) } }
    private func countRx(_ n: UInt64) { if routeThroughTunnel { onRx(n) } }

    func start() {
        guard let hostEndpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            Self.log.error("TCP flow has unsupported remoteEndpoint; dropping")
            finishDueToFailure()
            return
        }

        if routeDecider != nil {
            Self.log.debug(
                "TCP start signingID=\(self.signingID) mode=peek remote=\(hostEndpoint.hostname):\(hostEndpoint.port)"
            )
            startWithPeek(to: hostEndpoint)
            return
        }

        if routeThroughTunnel {
            Self.log.notice(
                "TCP start signingID=\(self.signingID) mode=tunnel remote=\(hostEndpoint.hostname):\(hostEndpoint.port) iface=\(self.tunnelInterfaceName ?? "nil")"
            )
            startTunnelConnection(to: hostEndpoint)
            return
        }

        Self.log.notice(
            "TCP start signingID=\(self.signingID) mode=direct remote=\(hostEndpoint.hostname):\(hostEndpoint.port) iface=\(self.tunnelInterfaceName ?? "nil")"
        )
        startDirectConnection(to: hostEndpoint)
    }

    // MARK: - SNI peek (decide route from the TLS ClientHello, then connect)

    /// Open the flow first (so the app sends its ClientHello), read that first chunk, run the
    /// decider, then connect the chosen outbound and replay the chunk. Inverts the normal
    /// connect-then-open order, which is why it needs its own send-pending helpers below.
    private func startWithPeek(to endpoint: NWHostEndpoint) {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("peek flow.open failed: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            self.queue.async { self.peekFirstChunk(endpoint: endpoint) }
        }
    }

    private func peekFirstChunk(endpoint: NWHostEndpoint) {
        flow.readData { [weak self] data, error in
            guard let self else { return }
            if let error {
                Self.log.debug("peek readData error: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            guard let data, !data.isEmpty else {
                Self.log.debug("peek readData empty (EOF) signingID=\(self.signingID)")
                self.finishSuccessfully()
                return
            }
            self.pendingFirstChunk = data
            if self.remoteDNS {
                self.sniName = TLSClientHelloSNI.serverName(from: data)
                Self.log.debug("SSH remote-DNS peek sni=\(self.sniName ?? "nil") destIP=\(endpoint.hostname) signingID=\(self.signingID)")
            }
            let tunnel = self.routeDecider?(data) ?? true
            self.routeThroughTunnel = tunnel
            self.countTx(UInt64(data.count))
            Self.log.debug(
                "TCP peek route signingID=\(self.signingID) tunnel=\(tunnel) firstLen=\(data.count) remote=\(endpoint.hostname):\(endpoint.port)"
            )
            if tunnel {
                self.connectTunnelAfterPeek(to: endpoint)
            } else {
                self.connectDirectAfterPeek(to: endpoint)
            }
        }
    }

    private func connectTunnelAfterPeek(to endpoint: NWHostEndpoint) {
        let flowID = Self.allocateFlowID()
        xpcFlowID = flowID
        guard let port = UInt16(endpoint.port) else {
            Self.log.error("peek TCP invalid remote port signingID=\(self.signingID)")
            finishDueToFailure()
            return
        }
        let targetHost = remoteDNS
            ? Self.remoteDNSTarget(sni: sniName, endpointHostname: endpoint.hostname)
            : endpoint.hostname
        Self.log.debug("SSH tunnel target signingID=\(self.signingID) host=\(targetHost) port=\(endpoint.port) sni=\(self.sniName ?? "nil") destIP=\(endpoint.hostname)")
        TransparentProxyRelayClient.shared.openFlow(
            flowID: flowID,
            remoteHost: targetHost,
            remotePort: port,
            isTCP: true,
            onReceive: { [weak self] data in self?.handleXPCPayload(data) },
            onClose: { [weak self] error in
                if let error {
                    Self.log.debug("peek XPC flow closed: \(error)")
                    self?.finishDueToFailure()
                } else {
                    self?.finishSuccessfully()
                }
            }
        ) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                Self.log.error("peek TCP XPC open failed signingID=\(self.signingID)")
                self.finishDueToFailure()
                return
            }
            // Flow is already open; replay the buffered ClientHello, then resume the read loop.
            self.queue.async { self.sendPendingThenRelayXPC() }
        }
    }

    private func sendPendingThenRelayXPC() {
        guard let flowID = xpcFlowID else { finishDueToFailure(); return }
        guard let first = pendingFirstChunk else { relayAppToRemoteXPC(); return }
        pendingFirstChunk = nil
        TransparentProxyRelayClient.shared.sendPayload(flowID: flowID, data: first) { [weak self] ok in
            guard let self else { return }
            if !ok {
                Self.log.debug("peek XPC send(first) failed signingID=\(self.signingID)")
                self.finishDueToFailure()
                return
            }
            self.relayAppToRemoteXPC()
        }
    }

    private func connectDirectAfterPeek(to endpoint: NWHostEndpoint) {
        let relay: RelayOutboundConnection? = endpoint.hostname.withCString { hostCStr in
            endpoint.port.withCString { portCStr in
                RelayOutboundConnection.makeConnection(
                    flow: flow,
                    hostname: hostCStr,
                    port: portCStr,
                    isTCP: true,
                    interfaceName: nil
                )
            }
        }
        guard let relay else {
            Self.log.error("peek TCP RelayOutboundConnection nil signingID=\(self.signingID) remote=\(endpoint.hostname):\(endpoint.port)")
            finishDueToFailure()
            return
        }
        directRelay = relay
        relay.start(queue: queue) { [weak self] isReady, error in
            guard let self else { return }
            if isReady {
                Self.log.debug("peek TCP direct ready signingID=\(self.signingID)")
                self.sendPendingThenRelayDirect()
                return
            }
            if let error {
                Self.log.error("peek TCP direct failed: \(error.localizedDescription) signingID=\(self.signingID)")
                self.finishDueToFailure(underlying: error)
            } else {
                self.finishDueToFailure()
            }
        }
    }

    private func sendPendingThenRelayDirect() {
        guard let relay = directRelay else { finishDueToFailure(); return }
        guard let first = pendingFirstChunk else {
            relayAppToRemote()
            relayRemoteToApp()
            return
        }
        pendingFirstChunk = nil
        relay.sendData(first) { [weak self] (writeError: Error?) in
            guard let self else { return }
            if let writeError {
                Self.log.debug("peek direct send(first) error: \(writeError.localizedDescription)")
                self.finishDueToFailure(underlying: writeError)
                return
            }
            self.relayAppToRemote()
            self.relayRemoteToApp()
        }
    }

    // MARK: - Tunnel path (XPC → packet-tunnel smoltcp → BoringTun)

    private func startTunnelConnection(to endpoint: NWHostEndpoint) {
        let flowID = Self.allocateFlowID()
        xpcFlowID = flowID
        guard let port = UInt16(endpoint.port) else {
            Self.log.error("TCP invalid remote port signingID=\(self.signingID)")
            finishDueToFailure()
            return
        }
        TransparentProxyRelayClient.shared.openFlow(
            flowID: flowID,
            remoteHost: endpoint.hostname,
            remotePort: port,
            isTCP: true,
            onReceive: { [weak self] data in
                self?.handleXPCPayload(data)
            },
            onClose: { [weak self] error in
                if let error {
                    Self.log.debug("XPC flow closed: \(error)")
                    self?.finishDueToFailure()
                } else {
                    self?.finishSuccessfully()
                }
            }
        ) { [weak self] ok in
            guard let self else { return }
            if ok {
                Self.log.notice("TCP XPC relay open signingID=\(self.signingID)")
                self.openProxyFlowAndStartRelayXPC()
            } else {
                // FAIL CLOSED (P3, window a): the relay/tunnel is unavailable (now bounded by the
                // client's open-reply watchdog, so this fires fast instead of hanging). We close the
                // flow with an error — we must NEVER fall back to a direct/en0 connection here, as
                // that would silently egress a routed app's traffic on the real ISP IP (the leak).
                Self.log.error("TCP XPC relay open failed signingID=\(self.signingID) — failing closed")
                self.finishDueToFailure()
            }
        }
    }

    private func openProxyFlowAndStartRelayXPC() {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("flow.open failed: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            Self.log.notice("TCP flow.open succeeded signingID=\(self.signingID)")
            self.queue.async {
                self.relayAppToRemoteXPC()
            }
        }
    }

    private func relayAppToRemoteXPC() {
        flow.readData { [weak self] data, error in
            guard let self else { return }
            if let error {
                Self.log.debug("flow.readData error: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            guard let data, !data.isEmpty else {
                Self.log.debug("flow.readData empty (EOF?) signingID=\(self.signingID)")
                // The relay protocol has no half-close, so app-side EOF finishes the whole flow
                // (a SHUT_WR-then-read client loses the response — already true when this sent a
                // bare closeFlow). The bare closeFlow also unregistered the client handlers, so
                // the server's later flowClosedPush found none: the flow never closed, `onClose`
                // never fired, and the relay leaked in activeRelays. `finishSuccessfully` both
                // sends closeFlow and performs the local finish.
                self.finishSuccessfully()
                return
            }
            self.countTx(UInt64(data.count))
            guard let flowID = self.xpcFlowID else {
                self.finishDueToFailure()
                return
            }
            TransparentProxyRelayClient.shared.sendPayload(flowID: flowID, data: data) { [weak self] ok in
                guard let self else { return }
                if !ok {
                    Self.log.debug("XPC send failed signingID=\(self.signingID)")
                    self.finishDueToFailure()
                    return
                }
                Self.log.debug(
                    "[APPSPLIT_RELAY] XPC bridge: sent payload to packet-tunnel for relay len=\(data.count)"
                )
                self.relayAppToRemoteXPC()
            }
        }
    }

    private func handleXPCPayload(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !data.isEmpty else { return }
            self.countRx(UInt64(data.count))
            Self.log.debug(
                "[APPSPLIT_RELAY] XPC bridge: received reply, wrote to flow len=\(data.count)"
            )
            self.flow.write(data) { [weak self] writeError in
                guard let self else { return }
                if let writeError {
                    Self.log.debug("flow.write error: \(writeError.localizedDescription)")
                    self.finishDueToFailure(underlying: writeError)
                }
            }
        }
    }

    // MARK: - Direct path (RelayOutboundConnection with source-app metadata)

    private func startDirectConnection(to endpoint: NWHostEndpoint) {
        // Fallback path. Explicit `nw_parameters_require_interface(utun)` is rejected
        // by NECP policy ("Path was denied by NECP policy, interface: utun4") when the
        // socket originates from this extension's process, even after `setMetadata`
        // re-attributes it to the routed source app. Empirically `setMetadata` alone
        // also fails to redirect the socket onto utun — it exits via en0.
        //
        // The reliable VPN-routed path is the UDS+smoltcp tunnel relay
        // (`startTunnelConnection`), used whenever the proxy intercepts a flow we want
        // exiting via WireGuard. This branch remains as a no-binding accounting fallback
        // for any future shape where we genuinely want OS-default routing.
        let relay: RelayOutboundConnection? = endpoint.hostname.withCString { hostCStr in
            endpoint.port.withCString { portCStr in
                RelayOutboundConnection.makeConnection(
                    flow: flow,
                    hostname: hostCStr,
                    port: portCStr,
                    isTCP: true,
                    interfaceName: nil
                )
            }
        }
        guard let relay else {
            Self.log.error(
                "TCP RelayOutboundConnection nil signingID=\(self.signingID) remote=\(endpoint.hostname):\(endpoint.port)"
            )
            finishDueToFailure()
            return
        }
        directRelay = relay
        relay.start(queue: queue) { [weak self] isReady, error in
            guard let self else { return }
            if isReady {
                Self.log.notice("TCP RelayOutboundConnection ready signingID=\(self.signingID)")
                self.openProxyFlowAndStartRelayDirect()
                return
            }
            if let error {
                Self.log.error(
                    "TCP RelayOutboundConnection failed: \(error.localizedDescription) signingID=\(self.signingID)"
                )
                self.finishDueToFailure(underlying: error)
            } else {
                self.finishDueToFailure()
            }
        }
    }

    private func openProxyFlowAndStartRelayDirect() {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("flow.open failed: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            Self.log.notice("TCP flow.open succeeded signingID=\(self.signingID)")
            self.queue.async {
                self.relayAppToRemote()
                self.relayRemoteToApp()
            }
        }
    }

    private func relayAppToRemote() {
        flow.readData { [weak self] data, error in
            guard let self else { return }
            if let error {
                Self.log.debug("flow.readData error: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            guard let data, !data.isEmpty else {
                Self.log.debug("flow.readData empty (EOF?) signingID=\(self.signingID)")
                self.signalRemoteEOF()
                return
            }
            self.countTx(UInt64(data.count))
            guard let relay = self.directRelay else {
                self.finishDueToFailure()
                return
            }
            relay.sendData(data) { [weak self] (writeError: Error?) in
                guard let self else { return }
                if let writeError {
                    Self.log.debug("remote write error: \(writeError.localizedDescription)")
                    self.finishDueToFailure(underlying: writeError)
                    return
                }
                self.relayAppToRemote()
            }
        }
    }

    private func relayRemoteToApp() {
        guard let relay = directRelay else { return }
        relay.receive(minLength: 1, maxLength: 65_536) { [weak self] (data: Data?, isComplete: Bool, error: Error?) in
            guard let self else { return }
            if let error {
                Self.log.debug("remote read error: \(error.localizedDescription)")
                self.finishDueToFailure(underlying: error)
                return
            }
            if let data, !data.isEmpty {
                self.countRx(UInt64(data.count))
                self.flow.write(data) { [weak self] writeError in
                    guard let self else { return }
                    if let writeError {
                        Self.log.debug("flow.write error: \(writeError.localizedDescription)")
                        self.finishDueToFailure(underlying: writeError)
                        return
                    }
                    // The final segment can arrive together with the close signal (data +
                    // isComplete in one callback). Honor it here — re-arming another receive
                    // instead would let a trailing RST-after-FIN convert this fully-delivered
                    // transfer into an error-close of the app flow.
                    if isComplete {
                        Self.log.debug("remote read complete (with final data) signingID=\(self.signingID)")
                        self.finishSuccessfully()
                    } else {
                        self.relayRemoteToApp()
                    }
                }
                return
            }
            if isComplete {
                Self.log.debug("remote read complete signingID=\(self.signingID)")
                self.finishSuccessfully()
            }
        }
    }

    private func signalRemoteEOF() {
        directRelay?.signalEOF()
    }

    // MARK: - SSH remote-DNS target selection

    /// Forwards to the canonical `RemoteDNSTargetSelector` (Shared/TransparentProxyRuntimeConfig.swift),
    /// which is compiled into both this extension target and the TunnelBahn app target so the app's
    /// DEBUG self-checks can exercise the same logic. Kept as a static func here (not just inlined at
    /// call sites) so Task 3's `Self.remoteDNSTarget(...)` call site is unaffected.
    static func remoteDNSTarget(sni: String?, endpointHostname: String) -> String {
        RemoteDNSTargetSelector.target(sni: sni, endpointHostname: endpointHostname)
    }

    // MARK: - Lifecycle

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
        if let flowID = xpcFlowID {
            TransparentProxyRelayClient.shared.closeFlow(flowID: flowID)
            xpcFlowID = nil
        }
        directRelay?.cancel()
        directRelay = nil
        onClose()
    }

    private func finishDueToFailure(underlying: Error? = nil) {
        guard takeFinishToken() else { return }
        let err = failureNSError(underlying: underlying)
        flow.closeReadWithError(err)
        flow.closeWriteWithError(err)
        if let flowID = xpcFlowID {
            TransparentProxyRelayClient.shared.closeFlow(flowID: flowID)
            xpcFlowID = nil
        }
        directRelay?.cancel()
        directRelay = nil
        onClose()
    }
}

/// Minimal, bounds-checked TLS ClientHello SNI extractor. Pulls the server_name (host_name) from
/// the first handshake record. Returns nil for non-TLS bytes, a fragmented/truncated ClientHello,
/// or a ClientHello with no SNI extension — callers fall back to IP-based routing in those cases.
/// Lowercased on success. ECH (encrypted ClientHello) will eventually hide this; out of scope.
enum TLSClientHelloSNI {
    static func serverName(from data: Data) -> String? {
        let b = [UInt8](data)
        let n = b.count
        var p = 0

        // TLS record header: content_type(1)=22 (handshake), version(2), length(2).
        guard n >= 5, b[0] == 0x16 else { return nil }
        p = 5
        // Handshake header: msg_type(1)=1 (ClientHello), length(3).
        guard p + 4 <= n, b[p] == 0x01 else { return nil }
        let hsLen = Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        p += 4
        // Tolerate a ClientHello whose declared length exceeds what we captured (TCP segmentation):
        // clamp the parse window to the bytes actually present.
        let hsEnd = Swift.min(p + hsLen, n)

        // client_version(2) + random(32).
        guard p + 34 <= hsEnd else { return nil }
        p += 34
        // session_id: len(1) + data.
        guard p + 1 <= hsEnd else { return nil }
        let sidLen = Int(b[p]); p += 1
        guard p + sidLen <= hsEnd else { return nil }
        p += sidLen
        // cipher_suites: len(2) + data.
        guard p + 2 <= hsEnd else { return nil }
        let csLen = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
        guard p + csLen <= hsEnd else { return nil }
        p += csLen
        // compression_methods: len(1) + data.
        guard p + 1 <= hsEnd else { return nil }
        let cmLen = Int(b[p]); p += 1
        guard p + cmLen <= hsEnd else { return nil }
        p += cmLen
        // extensions: len(2) + data.
        guard p + 2 <= hsEnd else { return nil }
        let extTotal = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
        let extEnd = Swift.min(p + extTotal, hsEnd)

        while p + 4 <= extEnd {
            let extType = Int(b[p]) << 8 | Int(b[p + 1])
            let extLen = Int(b[p + 2]) << 8 | Int(b[p + 3])
            p += 4
            guard p + extLen <= extEnd else { return nil }
            if extType == 0x0000 {  // server_name
                return parseServerNameExtension(b, start: p, end: p + extLen)
            }
            p += extLen
        }
        return nil
    }

    private static func parseServerNameExtension(_ b: [UInt8], start: Int, end: Int) -> String? {
        var p = start
        // server_name_list: len(2).
        guard p + 2 <= end else { return nil }
        let listLen = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
        let listEnd = Swift.min(p + listLen, end)
        while p + 3 <= listEnd {
            let nameType = b[p]; p += 1
            let nameLen = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
            guard p + nameLen <= listEnd else { return nil }
            if nameType == 0x00 {  // host_name
                let host = String(bytes: b[p ..< p + nameLen], encoding: .utf8)
                return host?.lowercased()
            }
            p += nameLen
        }
        return nil
    }
}

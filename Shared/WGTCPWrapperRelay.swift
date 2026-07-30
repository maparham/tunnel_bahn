import Foundation
import Network
import os

/// In-process wstunnel-v10 UDP-over-WebSocket client. Binds a loopback UDP socket (WireGuard's
/// effective endpoint) and relays each datagram to the server as one WebSocket binary frame over a
/// single TLS WebSocket connection, and back. Wire-compatible with `wstunnel` v10: path
/// `/<pathPrefix>/events`, subprotocol `v1, authorization.bearer.<jwt>`.
///
/// The WebSocket carrier is built on Network.framework `NWConnection` + `NWProtocolWebSocket`, NOT
/// `URLSessionWebSocketTask`. Inside a NEPacketTunnelProvider the extension runs as a heavily
/// sandboxed root process; URLSession's TLS trust evaluation reaches out to a system daemon the
/// sandbox blocks, so wss handshakes there fail with `-1200` even though the bare TCP connect
/// succeeds. `NWConnection` runs TLS in-process (verify handled by a `sec_protocol` block), which is
/// the sanctioned networking API for network extensions and works in that context.
final class WGTCPWrapperRelay: NSObject {
    private let config: WireGuardTCPWrapper
    private let queue = DispatchQueue(label: "com.tunnelbahn.mac.wgtcp.relay")
    private let logger = Logger(subsystem: "com.tunnelbahn.mac.networkextension", category: "WGTCPRelay")

    private var listener: NWListener?
    private var udpConnection: NWConnection?      // the single peer = BoringTun's NWUDPSession
    private var wsConnection: NWConnection?        // the wss carrier to the server
    private(set) var localUDPPort: UInt16 = 0

    // Data-plane frame counters (mutated only on `queue`). Logged first-of-direction + periodically
    // so the WG handshake round-trip is observable in the unified log without a wire capture:
    // UDP->WS counting up but WS->UDP stuck at 0 => BoringTun is sending but the server never
    // replies (framing / server-forward); both climbing => data plane is live.
    private var udpToWsCount = 0
    private var wsToUdpCount = 0
    private var wsRxCallbacks = 0   // every receiveMessage callback, pre-filter

    /// Resumed exactly once by the connection state handler — success on `.ready` (WS upgrade
    /// complete), failure on `.failed` or the timeout. `start()` awaits it.
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openResolved = false

    /// Budget for the TLS + HTTP WebSocket upgrade to complete. Generous on purpose: on
    /// UDP-blocked / heavily-throttled networks (the whole reason this transport exists) the bare
    /// TCP connect alone can be slow, so a tight budget guarantees failure on exactly the paths this
    /// feature targets. BoringTun keeps retrying the handshake, so a slow bring-up is tolerable; a
    /// false timeout is not.
    private let upgradeTimeoutSecs: Int = 30

    init(config: WireGuardTCPWrapper) {
        self.config = config
        super.init()
    }

    func start() async throws {
        do {
            try startUDPListener()
            try await startWebSocket()      // returns once the WS handshake has completed (or throws)
        } catch {
            stop()          // queue-serialized; tears down the bound listener/connection
            throw error
        }
        receiveFromWebSocket()
    }

    func stop() {
        // Fail a still-pending start() so its continuation can't leak.
        resolveOpen(.failure(NSError(domain: "WGTCPWrapperRelay", code: 5,
                                     userInfo: [NSLocalizedDescriptionKey: "relay stopped before open"])))
        // Resource teardown touches the same shared vars that receiveFromUDP and
        // receiveFromWebSocket (both on `queue`) read/write, so it must be serialized on `queue`
        // too — async, not sync, so a stop() reached from a callback already running on `queue`
        // can't deadlock.
        queue.async { [weak self] in
            guard let self else { return }
            self.wsConnection?.cancel(); self.wsConnection = nil
            self.udpConnection?.cancel(); self.udpConnection = nil
            self.listener?.cancel(); self.listener = nil
        }
    }

    // MARK: UDP side

    private func startUDPListener() throws {
        // Loopback-only: BoringTun only ever dials 127.0.0.1:<port>, and binding all interfaces
        // would let anything on the LAN inject datagrams the server would wrap toward WG. Restrict
        // ingress to loopback with an ephemeral (.any) port.
        let params = NWParameters.udp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // BoringTun uses one source port; keep the most recent as the reply target.
            // Cancel any prior connection before replacing it so a re-dial (new source port on
            // a path change) doesn't leak the old loopback NWConnection.
            self.udpConnection?.cancel()
            self.udpConnection = conn
            conn.start(queue: self.queue)
            self.receiveFromUDP(conn)
        }
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case let .failed(err): startError = err; ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        ready.wait()
        if let startError { throw startError }
        guard let port = listener.port?.rawValue else {
            throw NSError(domain: "WGTCPWrapperRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "UDP listener has no port"])
        }
        self.listener = listener
        self.localUDPPort = port
    }

    private func receiveFromUDP(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.sendToWebSocket(data)   // one datagram → one binary frame
            }
            if error == nil { self.receiveFromUDP(conn) }
        }
    }

    // MARK: WebSocket side

    private func startWebSocket() async throws {
        let scheme = config.tls ? "wss" : "ws"
        guard let url = URL(string: "\(scheme)://\(config.serverHost):\(config.serverPort)/\(config.pathPrefix)/events") else {
            throw NSError(domain: "WGTCPWrapperRelay", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad server URL"])
        }
        let jwt = WGTunnelJWT.makeUDP(forwardHost: config.forwardHost, forwardPort: config.forwardPort)

        let params: NWParameters
        if config.tls {
            let tls = NWProtocolTLS.Options()
            if !config.verifyCert {
                // wstunnel default: the reference server's cert is self-signed and will not validate
                // against a bare IP. Accept unconditionally in-process (no trustd round-trip, which
                // the extension sandbox blocks). When verifyCert is on, leave the default verify in
                // place so the system evaluates trust normally.
                sec_protocol_options_set_verify_block(
                    tls.securityProtocolOptions,
                    { _, _, complete in complete(true) },
                    queue)
            }
            // Send SNI explicitly (matches the reference client); harmless for an IP literal.
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, config.serverHost)
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }

        // The WebSocket subprotocol list carries the wstunnel request: the server selects "v1" and
        // reads the tunnel config from `authorization.bearer.<jwt>` (validated against the live
        // server). NWConnection sends these as `Sec-WebSocket-Protocol: v1, authorization.bearer.<jwt>`.
        let ws = NWProtocolWebSocket.Options()
        ws.setSubprotocols(["v1", "authorization.bearer.\(jwt)"])
        // wstunnel keeps the carrier alive with WebSocket ping/pong. Auto-pong incoming pings;
        // without this the server's keepalive ping goes unanswered and it closes the WS (observed:
        // carrier established, then dropped).
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        // NWEndpoint.url carries both the connect target (host:port) and the upgrade request path
        // (`/<pathPrefix>/events`).
        let conn = NWConnection(to: .url(url), using: params)
        self.wsConnection = conn

        // Await the HTTP upgrade completing: `.ready` fires once the WebSocket handshake succeeds.
        // A single stored continuation is resolved by whichever fires first: .ready (success),
        // .failed (failure), the timeout, or stop(). `resolveOpen` guarantees exactly-once resume.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.openContinuation = cont
                let budget = self.upgradeTimeoutSecs
                self.queue.asyncAfter(deadline: .now() + .seconds(budget)) { [weak self] in
                    self?.resolveOpen(.failure(NSError(
                        domain: "WGTCPWrapperRelay", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "WebSocket upgrade timed out after \(budget)s"])))
                }
                conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.logger.notice("[APPSPLIT_WGTCP] carrier .ready (WS upgrade complete)")
                        self.resolveOpen(.success(()))
                    case let .failed(err):
                        // Fires for a pre-open failure (fails start()) and for a post-open drop
                        // (resolveOpen is then a no-op, but the log makes the drop visible).
                        self.logger.error("[APPSPLIT_WGTCP] carrier .failed err=\(String(describing: err), privacy: .public) udp->ws=\(self.udpToWsCount, privacy: .public) ws->udp=\(self.wsToUdpCount, privacy: .public)")
                        self.resolveOpen(.failure(err))
                    case .cancelled:
                        self.logger.notice("[APPSPLIT_WGTCP] carrier .cancelled udp->ws=\(self.udpToWsCount, privacy: .public) ws->udp=\(self.wsToUdpCount, privacy: .public)")
                    case let .waiting(err):
                        // .waiting is transient (Network.framework auto-retries); keep waiting until
                        // .ready, .failed, or the timeout fires.
                        self.logger.notice("[APPSPLIT_WGTCP] carrier .waiting err=\(String(describing: err), privacy: .public)")
                    default:
                        break
                    }
                }
                conn.start(queue: self.queue)
            }
        }
    }

    /// Resume the open continuation at most once — the state handler, the timeout, and stop() can
    /// all race. First caller wins; the rest are no-ops. Must run (and only run) on `queue`.
    private func resolveOpen(_ result: Result<Void, Error>) {
        queue.async {
            guard !self.openResolved else { return }
            self.openResolved = true
            let cont = self.openContinuation
            self.openContinuation = nil
            switch result {
            case .success: cont?.resume()
            case let .failure(err): cont?.resume(throwing: err)
            }
        }
    }

    /// Send one datagram to the server as a single binary WebSocket frame.
    private func sendToWebSocket(_ data: Data) {
        guard let conn = wsConnection else { return }
        udpToWsCount += 1
        if udpToWsCount == 1 || udpToWsCount % 50 == 0 {
            logger.notice("[APPSPLIT_WGTCP] UDP->WS frames=\(self.udpToWsCount, privacy: .public) lastLen=\(data.count, privacy: .public)")
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "wgDatagram", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receiveFromWebSocket() {
        wsConnection?.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            // Unconditional raw-receive trace BEFORE any filtering: proves whether the server ever
            // sends anything back at all (vs. a frame that the isDataFrame gate silently drops, an
            // empty frame, or a receive error). Without this, "no WS->UDP line" is ambiguous.
            let op = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata).map { "\($0.opcode)" } ?? "nil-meta"
            self.wsRxCallbacks += 1
            if self.wsRxCallbacks <= 5 || self.wsRxCallbacks % 50 == 0 {
                self.logger.notice("[APPSPLIT_WGTCP] WS RX cb#\(self.wsRxCallbacks, privacy: .public) len=\(data?.count ?? -1, privacy: .public) opcode=\(op, privacy: .public) err=\(String(describing: error), privacy: .public)")
            }
            // Deliver binary/text payloads to the UDP peer; ignore control frames (close/ping/pong).
            if let data, !data.isEmpty, self.isDataFrame(context) {
                self.wsToUdpCount += 1
                if self.wsToUdpCount == 1 || self.wsToUdpCount % 50 == 0 {
                    self.logger.notice("[APPSPLIT_WGTCP] WS->UDP frames=\(self.wsToUdpCount, privacy: .public) lastLen=\(data.count, privacy: .public)")
                }
                self.udpConnection?.send(content: data, completion: .contentProcessed { _ in })
            }
            if error == nil, self.wsConnection != nil {
                self.receiveFromWebSocket()   // keep receiving
            }
            // On error the carrier is gone; stop pumping. Provider observes tunnel loss. (No
            // auto-reconnect in v1.)
        }
    }

    /// True for binary/text WebSocket messages (the ones carrying WG datagrams). A close frame or a
    /// context-less delivery is not forwarded.
    private func isDataFrame(_ context: NWConnection.ContentContext?) -> Bool {
        guard let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata else { return false }
        return meta.opcode == .binary || meta.opcode == .text
    }
}

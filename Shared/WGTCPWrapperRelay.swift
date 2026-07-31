import Foundation
import Network
import os
import Security

/// In-process wstunnel-v10 UDP-over-WebSocket client. Binds a loopback UDP socket (WireGuard's
/// effective endpoint) and relays each datagram to the server as one WebSocket binary frame over a
/// single TLS connection, and back. Wire-compatible with `wstunnel` v10: path `/<pathPrefix>/events`,
/// subprotocol `v1, authorization.bearer.<jwt>`.
///
/// The carrier is a raw `NWConnection` + `NWProtocolTLS`; the WebSocket layer (HTTP Upgrade + frame
/// codec) is hand-rolled on top rather than using `NWProtocolWebSocket`. Two reasons:
///  1. Inside a NEPacketTunnelProvider the extension is a heavily sandboxed root process;
///     URLSession's TLS trust evaluation reaches a system daemon the sandbox blocks (wss fails with
///     -1200). `NWConnection` runs TLS in-process, which is the sanctioned API for network extensions.
///  2. `NWProtocolWebSocket` MASKS every client frame (RFC 6455 mandates it, no opt-out). wstunnel
///     runs with `websocket_mask_frame: false` and does NOT unmask incoming client frames — so a
///     masked WG init arrives at wg-exit scrambled (type byte 0x7d instead of 0x01), is dropped
///     before peer attribution, and the handshake never completes. We therefore emit UNMASKED frames
///     (mask bit = 0), exactly as wstunnel's own client does.
///
/// `@unchecked Sendable`: `self` is captured by `@Sendable` dispatch/Network.framework callbacks,
/// but all mutable state is confined to the serial `queue` — every handler runs on it and
/// `stop()`/`resolveOpen` hop onto it; the few setup writes made off-queue during `start()`
/// happen-before the corresponding listener/connection is started on the queue.
final class WGTCPWrapperRelay: NSObject, @unchecked Sendable {
    private let config: WireGuardTCPWrapper
    private let queue = DispatchQueue(label: "com.tunnelbahn.mac.wgtcp.relay")
    private let logger = Logger(subsystem: "com.tunnelbahn.mac.networkextension", category: "WGTCPRelay")

    private var listener: NWListener?
    private var udpConnection: NWConnection?      // the single peer = BoringTun's NWUDPSession
    private var wsConnection: NWConnection?        // the raw TLS carrier to the server
    private(set) var localUDPPort: UInt16 = 0

    /// Carrier lifecycle: TLS connecting → HTTP Upgrade sent, awaiting 101 → open (framing).
    private enum Phase { case connecting, awaitingUpgrade, open }
    private var phase: Phase = .connecting
    /// Bytes received on the carrier not yet consumed: HTTP response headers first, then WS frames.
    private var recvBuffer = Data()

    // Data-plane frame counters (mutated only on `queue`). Logged first-of-direction + periodically
    // so the WG handshake round-trip is observable in the unified log without a wire capture:
    // UDP->WS counting up but WS->UDP stuck at 0 => BoringTun is sending but the server never
    // replies; both climbing => data plane is live.
    private var udpToWsCount = 0
    private var wsToUdpCount = 0

    /// Resumed exactly once — success once the HTTP 101 upgrade is parsed, failure on `.failed`,
    /// a non-101 response, or the timeout. `start()` awaits it.
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
            try await startCarrier()        // returns once the HTTP 101 upgrade has completed (or throws)
        } catch {
            stop()          // queue-serialized; tears down the bound listener/connection
            throw error
        }
    }

    func stop() {
        // Fail a still-pending start() so its continuation can't leak.
        resolveOpen(.failure(NSError(domain: "WGTCPWrapperRelay", code: 5,
                                     userInfo: [NSLocalizedDescriptionKey: "relay stopped before open"])))
        // Resource teardown touches the same shared vars the receive callbacks (all on `queue`)
        // read/write, so it must be serialized on `queue` too — async, not sync, so a stop() reached
        // from a callback already running on `queue` can't deadlock.
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

    // MARK: Carrier (TLS + hand-rolled WebSocket)

    private func startCarrier() async throws {
        let host = NWEndpoint.Host(config.serverHost)
        guard let port = NWEndpoint.Port(rawValue: config.serverPort) else {
            throw NSError(domain: "WGTCPWrapperRelay", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad server port"])
        }

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

        let conn = NWConnection(host: host, port: port, using: params)
        self.wsConnection = conn

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
                        // TLS is up (or bare TCP for ws://). Send the HTTP Upgrade and start reading.
                        self.logger.notice("[APPSPLIT_WGTCP] carrier TLS/TCP .ready — sending WS upgrade")
                        self.sendUpgradeRequest()
                        self.phase = .awaitingUpgrade
                        self.receiveCarrier()
                    case let .failed(err):
                        self.logger.error("[APPSPLIT_WGTCP] carrier .failed err=\(String(describing: err), privacy: .public) udp->ws=\(self.udpToWsCount, privacy: .public) ws->udp=\(self.wsToUdpCount, privacy: .public)")
                        self.resolveOpen(.failure(err))
                    case .cancelled:
                        self.logger.notice("[APPSPLIT_WGTCP] carrier .cancelled udp->ws=\(self.udpToWsCount, privacy: .public) ws->udp=\(self.wsToUdpCount, privacy: .public)")
                    case let .waiting(err):
                        // .waiting is transient (Network.framework auto-retries); keep waiting.
                        self.logger.notice("[APPSPLIT_WGTCP] carrier .waiting err=\(String(describing: err), privacy: .public)")
                    default:
                        break
                    }
                }
                conn.start(queue: self.queue)
            }
        }
    }

    private func sendUpgradeRequest() {
        let jwt = WGTunnelJWT.makeUDP(forwardHost: config.forwardHost, forwardPort: config.forwardPort)
        let wsKey = Self.randomBase64(16)
        let hostHeader = "\(config.serverHost):\(config.serverPort)"
        let request =
            "GET /\(config.pathPrefix)/events HTTP/1.1\r\n" +
            "Host: \(hostHeader)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(wsKey)\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "Sec-WebSocket-Protocol: v1, authorization.bearer.\(jwt)\r\n" +
            "\r\n"
        wsConnection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] err in
            if let err {
                self?.resolveOpen(.failure(err))
            }
        })
    }

    /// Single receive loop for the carrier. Appends to `recvBuffer`, then either parses the HTTP
    /// upgrade response (awaitingUpgrade) or drains complete WS frames (open).
    private func receiveCarrier() {
        wsConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.recvBuffer.append(data)
                switch self.phase {
                case .awaitingUpgrade: self.consumeUpgradeResponse()
                case .open: self.drainFrames()
                case .connecting: break
                }
            }
            if let error {
                self.logger.error("[APPSPLIT_WGTCP] carrier receive error=\(String(describing: error), privacy: .public)")
                self.resolveOpen(.failure(error))
                return
            }
            if isComplete {
                // Server closed the stream. Nothing more will arrive; provider observes tunnel loss.
                self.logger.notice("[APPSPLIT_WGTCP] carrier EOF udp->ws=\(self.udpToWsCount, privacy: .public) ws->udp=\(self.wsToUdpCount, privacy: .public)")
                self.resolveOpen(.failure(NSError(domain: "WGTCPWrapperRelay", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "carrier closed before upgrade"])))
                return
            }
            self.receiveCarrier()   // keep receiving
        }
    }

    /// Parse the HTTP response headers. On `101 Switching Protocols`, flip to framing; leftover
    /// bytes after the header terminator are the first WS frame(s).
    private func consumeUpgradeResponse() {
        // Header block ends at the first CRLFCRLF.
        let terminator = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let range = recvBuffer.range(of: terminator) else { return }   // headers incomplete, wait
        let headerData = recvBuffer.subdata(in: recvBuffer.startIndex..<range.lowerBound)
        recvBuffer.removeSubrange(recvBuffer.startIndex..<range.upperBound)   // keep any WS bytes that followed

        let statusLine = String(decoding: headerData, as: UTF8.self)
            .split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        guard statusLine.contains(" 101 ") else {
            logger.error("[APPSPLIT_WGTCP] upgrade rejected: \(statusLine, privacy: .public)")
            resolveOpen(.failure(NSError(domain: "WGTCPWrapperRelay", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "WebSocket upgrade failed: \(statusLine)"])))
            return
        }
        logger.notice("[APPSPLIT_WGTCP] WS upgrade complete (101)")
        phase = .open
        resolveOpen(.success(()))
        drainFrames()   // any frames that arrived in the same segment as the 101
    }

    // MARK: WebSocket frame codec (unmasked send; tolerant read)

    private struct WSOpcode {
        static let continuation: UInt8 = 0x0
        static let text: UInt8 = 0x1
        static let binary: UInt8 = 0x2
        static let close: UInt8 = 0x8
        static let ping: UInt8 = 0x9
        static let pong: UInt8 = 0xA
    }

    /// Send one datagram to the server as a single UNMASKED binary WebSocket frame.
    private func sendToWebSocket(_ data: Data) {
        guard let conn = wsConnection, phase == .open else { return }
        udpToWsCount += 1
        if udpToWsCount == 1 || udpToWsCount % 50 == 0 {
            logger.notice("[APPSPLIT_WGTCP] UDP->WS frames=\(self.udpToWsCount, privacy: .public) lastLen=\(data.count, privacy: .public)")
        }
        conn.send(content: Self.encodeFrame(opcode: WSOpcode.binary, payload: data),
                  completion: .contentProcessed { _ in })
    }

    /// Drain as many complete frames as `recvBuffer` holds. Server→client frames are unmasked.
    private func drainFrames() {
        while true {
            guard let (opcode, payload, consumed) = Self.decodeFrame(recvBuffer) else { break }
            recvBuffer.removeSubrange(recvBuffer.startIndex..<recvBuffer.startIndex.advanced(by: consumed))
            switch opcode {
            case WSOpcode.binary, WSOpcode.text, WSOpcode.continuation:
                if !payload.isEmpty {
                    wsToUdpCount += 1
                    if wsToUdpCount == 1 || wsToUdpCount % 50 == 0 {
                        logger.notice("[APPSPLIT_WGTCP] WS->UDP frames=\(self.wsToUdpCount, privacy: .public) lastLen=\(payload.count, privacy: .public)")
                    }
                    udpConnection?.send(content: payload, completion: .contentProcessed { _ in })
                }
            case WSOpcode.ping:
                // Keep the carrier alive: echo the payload back as a pong (unmasked).
                wsConnection?.send(content: Self.encodeFrame(opcode: WSOpcode.pong, payload: payload),
                                   completion: .contentProcessed { _ in })
            case WSOpcode.pong:
                break
            case WSOpcode.close:
                logger.notice("[APPSPLIT_WGTCP] server sent WS close")
                wsConnection?.cancel()
                return
            default:
                break
            }
        }
    }

    /// Encode a WebSocket frame with FIN=1, no mask (mask bit = 0). Extended length for >125 bytes.
    private static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0f))     // FIN + opcode
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))              // mask bit = 0
        } else if len < 65536 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xff))
            frame.append(UInt8(len & 0xff))
        } else {
            frame.append(127)
            var l = UInt64(len).bigEndian
            withUnsafeBytes(of: &l) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }

    /// Decode one frame from the front of `buffer`. Returns (opcode, payload, bytesConsumed) or nil
    /// if a full frame isn't buffered yet. Unmasks if the server ever sets the mask bit (it won't).
    private static func decodeFrame(_ buffer: Data) -> (opcode: UInt8, payload: Data, consumed: Int)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0f
        let masked = (bytes[1] & 0x80) != 0
        var len = Int(bytes[1] & 0x7f)
        var offset = 2
        if len == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            len = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
        } else if len == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            len = 0
            for i in 0..<8 { len = (len << 8) | Int(bytes[offset + i]) }
            offset += 8
        }
        var maskKey = [UInt8](repeating: 0, count: 4)
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<offset + 4])
            offset += 4
        }
        guard bytes.count >= offset + len else { return nil }
        var payload = Array(bytes[offset..<offset + len])
        if masked {
            for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
        }
        return (opcode, Data(payload), offset + len)
    }

    private static func randomBase64(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: continuation plumbing

    /// Resume the open continuation at most once — the state handler, the reader, the timeout, and
    /// stop() can all race. First caller wins; the rest are no-ops. Must run (and only run) on `queue`.
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
}

import Foundation
import Network

/// In-process wstunnel-v10 UDP-over-WebSocket client. Binds a loopback UDP socket (WireGuard's
/// effective endpoint) and relays each datagram to the server as one WebSocket binary frame over a
/// single TLS WebSocket connection, and back. Wire-compatible with `wstunnel` v10: path
/// `/<pathPrefix>/events`, subprotocol `v1, authorization.bearer.<jwt>`.
final class WGTCPWrapperRelay: NSObject {
    private let config: WireGuardTCPWrapper
    private let queue = DispatchQueue(label: "com.tunnelbahn.mac.wgtcp.relay")

    private var listener: NWListener?
    private var udpConnection: NWConnection?      // the single peer = BoringTun's NWUDPSession
    private var session: URLSession?
    private var wsTask: URLSessionWebSocketTask?
    private(set) var localUDPPort: UInt16 = 0

    /// Resumed exactly once by the WebSocket delegate — success on `didOpenWithProtocol`,
    /// failure on `didCompleteWithError` before open. `start()` awaits it (with a timeout).
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openResolved = false

    init(config: WireGuardTCPWrapper) {
        self.config = config
        super.init()
    }

    func start() async throws {
        do {
            try startUDPListener()
            try await startWebSocket()      // returns once the WS handshake has completed (or throws)
        } catch {
            stop()          // queue-serialized; tears down the bound listener/session/task
            throw error
        }
        receiveFromWebSocket()
    }

    func stop() {
        // Fail a still-pending start() so its continuation can't leak.
        resolveOpen(.failure(NSError(domain: "WGTCPWrapperRelay", code: 5,
                                     userInfo: [NSLocalizedDescriptionKey: "relay stopped before open"])))
        // Resource teardown touches the same shared vars that receiveFromUDP (on `queue`) and
        // receiveFromWebSocket (on the URLSession delegate queue) read/write, so it must be
        // serialized on `queue` too — async, not sync, so a stop() reached from a callback
        // already running on `queue` can't deadlock.
        queue.async { [weak self] in
            guard let self else { return }
            self.wsTask?.cancel(with: .goingAway, reason: nil)
            self.wsTask = nil
            self.session?.invalidateAndCancel()
            self.session = nil
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
                self.wsTask?.send(.data(data)) { _ in }   // one datagram → one binary frame
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
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        // URLSession sends these as `Sec-WebSocket-Protocol: v1, authorization.bearer.<jwt>` — the
        // exact header wstunnel v10 uses to carry the tunnel request. The server selects "v1",
        // which URLSession accepts (validated against the live server).
        let task = session.webSocketTask(with: url, protocols: ["v1", "authorization.bearer.\(jwt)"])
        self.session = session
        self.wsTask = task

        // Await the HTTP upgrade completing. Readiness = the `didOpenWithProtocol` delegate (NOT a
        // ping — wstunnel does not reliably pong). A single stored continuation is resolved by
        // whichever fires first: didOpen (success), didCompleteWithError (failure), the timeout, or
        // stop(). `resolveOpen` guarantees exactly-once resume, so the continuation can never leak.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.openContinuation = cont
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in   // 10s upgrade timeout
                    self?.resolveOpen(.failure(NSError(
                        domain: "WGTCPWrapperRelay", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "WebSocket upgrade timed out after 10s"])))
                }
                task.resume()
            }
        }
    }

    /// Resume the open continuation at most once — delegate callbacks, the timeout, and stop() can
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

    private func receiveFromWebSocket() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                switch message {
                case let .data(data):
                    self.udpConnection?.send(content: data, completion: .contentProcessed { _ in })
                case let .string(text):
                    self.udpConnection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
                @unknown default: break
                }
                self.receiveFromWebSocket()   // keep receiving
            case .failure:
                // WS closed/errored; stop pumping. Provider observes tunnel loss. (No auto-reconnect in v1.)
                break
            }
        }
    }
}

extension WGTCPWrapperRelay: URLSessionWebSocketDelegate {
    // Readiness signal: the upgrade completed and a subprotocol was selected.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        resolveOpen(.success(()))
    }

    // Fired on connect/TLS/upgrade failure (and on later transport errors). If it beats
    // `didOpen`, it fails `start()`; if it arrives after open, `resolveOpen` is a no-op.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let err = error ?? NSError(domain: "WGTCPWrapperRelay", code: 4,
                                   userInfo: [NSLocalizedDescriptionKey: "WebSocket closed before opening"])
        resolveOpen(.failure(err))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Skip TLS validation when verifyCert is off (wstunnel default; the reference server's
        // cert will not validate against a bare IP). When on, defer to the system default.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if config.verifyCert {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

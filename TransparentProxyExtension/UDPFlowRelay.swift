import Foundation
import Network
import NetworkExtension
import os.log

/// UDP relay between an `NEAppProxyUDPFlow` and one or more outbound `NWConnection`s
/// (UDP can fan out to multiple destinations within a single flow).
///
/// We open one outbound `NWConnection` per unique remote endpoint observed and route
/// inbound datagrams back to the proxy flow tagged with the originating endpoint, which
/// is what `NEAppProxyUDPFlow.writeDatagrams(_:sentBy:)` expects.
final class UDPFlowRelay {
    private static let log = Logger(
        subsystem: "com.tunnelbahn.mac.transparentproxy",
        category: "UDPRelay"
    )

    private let flow: NEAppProxyUDPFlow
    private let signingID: String
    private let onTx: (UInt64) -> Void
    private let onRx: (UInt64) -> Void
    private let onClose: () -> Void
    private let queue: DispatchQueue

    /// Cached connections, keyed by `"host:port"`. Each is a connected UDP socket to a
    /// specific remote endpoint.
    private var connections: [String: NWConnection] = [:]
    /// Reverse map so we can tag inbound datagrams with the legacy host endpoint the proxy
    /// flow expects in `writeDatagrams(_:sentBy:)`.
    private var legacyEndpoints: [String: NWHostEndpoint] = [:]
    private var didCloseOnce = false

    init(
        flow: NEAppProxyUDPFlow,
        signingID: String,
        queue: DispatchQueue,
        onTx: @escaping (UInt64) -> Void,
        onRx: @escaping (UInt64) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.flow = flow
        self.signingID = signingID
        self.queue = queue
        self.onTx = onTx
        self.onRx = onRx
        self.onClose = onClose
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("UDP flow.open failed: \(error.localizedDescription, privacy: .public)")
                self.cleanup()
                return
            }
            Self.log.notice("UDP flow.open succeeded signingID=\(self.signingID, privacy: .public)")
            self.queue.async {
                self.relayAppToRemote()
            }
        }
    }

    private func relayAppToRemote() {
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self else { return }
            if let error {
                Self.log.debug("UDP readDatagrams error: \(error.localizedDescription, privacy: .public)")
                self.cleanup()
                return
            }
            guard let datagrams, let endpoints, !datagrams.isEmpty else {
                Self.log.debug("UDP readDatagrams empty (EOF?) signingID=\(self.signingID, privacy: .public)")
                self.cleanup()
                return
            }
            for (datagram, legacyEndpoint) in zip(datagrams, endpoints) {
                guard let hostEndpoint = legacyEndpoint as? NWHostEndpoint else { continue }
                self.send(datagram: datagram, to: hostEndpoint)
            }
            self.queue.async {
                self.relayAppToRemote()
            }
        }
    }

    private func send(datagram: Data, to legacyEndpoint: NWHostEndpoint) {
        guard let modern = EndpointBridge.modernize(legacyEndpoint) else {
            return
        }
        let key = endpointKey(modern)
        let conn: NWConnection
        if let cached = connections[key] {
            conn = cached
        } else {
            Self.log.notice("UDP new NWConnection signingID=\(self.signingID, privacy: .public) remote=\(String(describing: modern), privacy: .public)")
            conn = NWConnection(to: modern, using: NWParameters.udp)
            legacyEndpoints[key] = legacyEndpoint
            connections[key] = conn
            startRelayingInbound(from: conn, key: key)
            conn.start(queue: queue)
        }

        onTx(UInt64(datagram.count))
        conn.send(
            content: datagram,
            completion: .contentProcessed { error in
                if let error {
                    Self.log.debug("UDP send error: \(error.localizedDescription, privacy: .public)")
                }
            }
        )
    }

    private func startRelayingInbound(from connection: NWConnection, key: String) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: key)
                self?.legacyEndpoints.removeValue(forKey: key)
            default:
                break
            }
        }
        receiveLoop(on: connection, key: key)
    }

    private func receiveLoop(on connection: NWConnection, key: String) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let legacy = self.legacyEndpoints[key] {
                self.onRx(UInt64(data.count))
                self.flow.writeDatagrams([data], sentBy: [legacy]) { writeError in
                    if let writeError {
                        Self.log.debug("UDP writeDatagrams error: \(writeError.localizedDescription, privacy: .public)")
                    }
                }
            }
            if let error {
                Self.log.debug("UDP receive error: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveLoop(on: connection, key: key)
        }
    }

    private func endpointKey(_ endpoint: Network.NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, port):
            return "\(host):\(port.rawValue)"
        default:
            return String(describing: endpoint)
        }
    }

    private func cleanup() {
        let shouldFire: Bool = {
            if didCloseOnce { return false }
            didCloseOnce = true
            return true
        }()
        guard shouldFire else { return }

        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll(keepingCapacity: false)
        legacyEndpoints.removeAll(keepingCapacity: false)
        onClose()
    }
}

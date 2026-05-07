import Foundation
import Network
import NetworkExtension
import os.log

/// Bidirectional TCP relay between an `NEAppProxyTCPFlow` (the intercepted app side) and an
/// `NWConnection` (the actual destination). Counts payload bytes in both directions and
/// reports them through the supplied closures.
///
/// Lifecycle:
/// - `start()` opens the proxy flow and the outbound `NWConnection` in parallel.
/// - When the connection is `.ready`, both relay loops are started.
/// - On any IO error, `cleanup()` is called once and forwards an `onClose` notification.
final class TCPFlowRelay {
    private static let log = Logger(
        subsystem: "com.appsplit.wg.transparentproxy",
        category: "TCPRelay"
    )

    private let flow: NEAppProxyTCPFlow
    private let signingID: String
    private let onTx: (UInt64) -> Void
    private let onRx: (UInt64) -> Void
    private let onClose: () -> Void

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var didCloseOnce = false

    init(
        flow: NEAppProxyTCPFlow,
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
        guard let hostEndpoint = flow.remoteEndpoint as? NWHostEndpoint,
              let endpoint = EndpointBridge.modernize(hostEndpoint)
        else {
            Self.log.error("TCP flow has unsupported remoteEndpoint; dropping")
            cleanup()
            return
        }

        Self.log.notice("TCP start signingID=\(self.signingID, privacy: .public) remote=\(String(describing: endpoint), privacy: .public)")
        let conn = NWConnection(to: endpoint, using: NWParameters.tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self else { return }
            switch state {
            case .ready:
                Self.log.notice("TCP NWConnection ready signingID=\(self.signingID, privacy: .public)")
                self.openProxyFlowAndStartRelay()
            case let .failed(error):
                Self.log.error("TCP NWConnection failed: \(error.localizedDescription, privacy: .public)")
                self.cleanup()
            case .cancelled:
                self.cleanup()
            case .waiting(let error):
                Self.log.notice("TCP NWConnection waiting: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func openProxyFlowAndStartRelay() {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("flow.open failed: \(error.localizedDescription, privacy: .public)")
                self.cleanup()
                return
            }
            Self.log.notice("TCP flow.open succeeded signingID=\(self.signingID, privacy: .public)")
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
                Self.log.debug("flow.readData error: \(error.localizedDescription, privacy: .public)")
                self.cleanup()
                return
            }
            guard let data, !data.isEmpty else {
                Self.log.debug("flow.readData empty (EOF?) signingID=\(self.signingID, privacy: .public)")
                self.connection?.send(content: nil, isComplete: true, completion: .idempotent)
                return
            }
            self.onTx(UInt64(data.count))
            self.connection?.send(
                content: data,
                completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if let sendError {
                        Self.log.debug("NWConnection.send error: \(sendError.localizedDescription, privacy: .public)")
                        self.cleanup()
                        return
                    }
                    self.relayAppToRemote()
                }
            )
        }
    }

    private func relayRemoteToApp() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Self.log.debug("NWConnection.receive error: \(error.localizedDescription, privacy: .public)")
                self.cleanup()
                return
            }
            if let data, !data.isEmpty {
                self.onRx(UInt64(data.count))
                self.flow.write(data) { [weak self] writeError in
                    guard let self else { return }
                    if let writeError {
                        Self.log.debug("flow.write error: \(writeError.localizedDescription, privacy: .public)")
                        self.cleanup()
                        return
                    }
                    self.relayRemoteToApp()
                }
                return
            }
            if isComplete {
                Self.log.debug("NWConnection.receive complete signingID=\(self.signingID, privacy: .public)")
                self.flow.closeReadWithError(nil)
                self.cleanup()
            }
        }
    }

    private func cleanup() {
        // Idempotent — multiple error paths can race here.
        let shouldFire: Bool = {
            if didCloseOnce { return false }
            didCloseOnce = true
            return true
        }()
        guard shouldFire else { return }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        connection?.cancel()
        onClose()
    }
}

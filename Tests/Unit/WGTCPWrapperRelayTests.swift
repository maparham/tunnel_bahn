import XCTest
import Network

final class WGTCPWrapperRelayTests: XCTestCase {
    /// Minimal echo WS server: echoes every binary message back on the same connection.
    private func startEchoWSServer() throws -> (port: UInt16, listener: NWListener) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            func pump() {
                conn.receiveMessage { data, context, _, error in
                    if let data, let context {
                        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                    }
                    if error == nil { pump() }
                }
            }
            pump()
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener.port!.rawValue, listener)
    }

    func testDatagramRoundTripsThroughRelay() async throws {
        let server = try startEchoWSServer()
        defer { server.listener.cancel() }

        let config = WireGuardTCPWrapper(
            serverHost: "127.0.0.1", serverPort: server.port, tls: false, verifyCert: false,
            pathPrefix: "tuntest", forwardHost: "127.0.0.1", forwardPort: 51840
        )
        let relay = WGTCPWrapperRelay(config: config)
        try await relay.start()
        defer { relay.stop() }

        // Send a datagram into the relay's local UDP port and expect the echo back.
        let payload = Data("wg-handshake-probe".utf8)
        let udp = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relay.localUDPPort)!, using: .udp)
        let gotEcho = expectation(description: "echo")
        udp.stateUpdateHandler = { state in
            if case .ready = state {
                udp.send(content: payload, completion: .contentProcessed { _ in })
                udp.receiveMessage { data, _, _, _ in
                    if data == payload { gotEcho.fulfill() }
                }
            }
        }
        udp.start(queue: .global())
        await fulfillment(of: [gotEcho], timeout: 8)
        udp.cancel()
    }

    func testStartThrowsWhenServerUnreachable() async {
        let config = WireGuardTCPWrapper(
            serverHost: "127.0.0.1", serverPort: 1,  // nothing listens on TCP/1
            tls: false, verifyCert: false, pathPrefix: "x", forwardHost: "127.0.0.1", forwardPort: 51840
        )
        let relay = WGTCPWrapperRelay(config: config)
        do { try await relay.start(); XCTFail("expected throw") } catch { /* expected */ }
        relay.stop()
    }
}

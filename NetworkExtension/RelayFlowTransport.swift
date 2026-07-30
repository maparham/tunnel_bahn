import Foundation

/// Result of a `sendTCP` call into a `RelayFlowTransport`.
enum SendResult {
    case ok          // bytes accepted into the transport's tx buffer
    case transient   // bytes accepted, but tx queue crossed the high-water mark — pause feeding
    case permanent   // flow missing or socket in terminal state; do not retry
}

/// Egress-bridge seam that `PacketTunnelRelayServer` depends on to open/send/close flows and
/// receive inbound payload/close callbacks, independent of the concrete transport (WireGuard's
/// `SmoltcpRelayBridge` today; an SSH-based transport later).
protocol RelayFlowTransport: AnyObject {
    var onPayloadFromFlow: ((UInt64, Data) -> Void)? { get set }
    var onFlowClosed: ((UInt64, String?) -> Void)? { get set }
    func openTCP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool
    func sendTCP(flowID: UInt64, data: Data) -> SendResult
    /// UDP flow to a fixed remote. Transports that only forward TCP (SSH `direct-tcpip`)
    /// keep the default `false`, which makes the relay server refuse the open (fail closed).
    func openUDP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool
    /// One datagram on an open UDP flow. `false` = flow unknown/not UDP (drop-on-full is `true`).
    func sendUDP(flowID: UInt64, data: Data) -> Bool
    func close(flowID: UInt64)
}

extension RelayFlowTransport {
    func openUDP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool { false }
    func sendUDP(flowID: UInt64, data: Data) -> Bool { false }
}

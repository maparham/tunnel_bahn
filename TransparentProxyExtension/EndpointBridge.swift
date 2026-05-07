import Foundation
import Network
import NetworkExtension

/// `NWEndpoint` exists in BOTH `NetworkExtension` (legacy class) and `Network` (modern enum),
/// and Swift can't disambiguate via module prefixes alone. We import the legacy one as a
/// typealias under a unique name to avoid the collision in our own code.
typealias LegacyNWEndpoint = NetworkExtension.NWHostEndpoint

/// Bridges the legacy `NWHostEndpoint` (used by `NEAppProxyFlow.remoteEndpoint` and the
/// per-datagram endpoints from `NEAppProxyUDPFlow.readDatagrams`) into the modern
/// `Network.NWEndpoint` consumed by `NWConnection`.
enum EndpointBridge {
    /// Convert a legacy host endpoint to a modern `Network.NWEndpoint`. Returns `nil` for
    /// unsupported endpoint types or unparsable ports.
    static func modernize(_ host: NWHostEndpoint) -> Network.NWEndpoint? {
        guard let port = NWEndpoint.Port(host.port) else { return nil }
        let nwHost = NWEndpoint.Host(host.hostname)
        return .hostPort(host: nwHost, port: port)
    }
}

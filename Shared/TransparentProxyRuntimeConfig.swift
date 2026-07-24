import Foundation

// DestinationRoutingFilePayload is defined in DestinationRouting.swift (same Shared module)

/// Routing snapshot passed from the host app when starting the transparent proxy.
/// System extensions run as root and often cannot read files the host wrote in the user's
/// app-group container, so this travels in `NETunnelProviderProtocol.providerConfiguration`.
struct TransparentProxyRuntimeConfig: Codable, Equatable {
    var signingIdentifiers: [String]
    var routeAllIdentifiedFlows: Bool
    var destinationRouting: DestinationRoutingFilePayload
    /// Packet tunnel interface name. When set, destination-filtered `NWConnection` relays can bind
    /// outbound connections to this utun interface as a fallback if kernel per-app routing alone is insufficient.
    var packetTunnelInterfaceName: String?
    /// True when the active profile's transport is SSH (as opposed to WireGuard). SSH forwards only
    /// TCP, so tunneled UDP has no backing path in this mode — `UDPFlowRelay` uses this to drop
    /// would-be-tunneled datagrams instead of dialing the WG-dependent `RelayOutboundConnection` path
    /// (see project memory: SSH transport UDP no-leak requirement). Defaults to `false` so legacy
    /// (pre-SSH-transport) encoded configs, which have no such key, decode to the existing WG
    /// behavior unchanged.
    var dropTunneledUDP: Bool

    static let providerConfigurationKey = "proxyConfigB64"

    init(
        signingIdentifiers: [String],
        routeAllIdentifiedFlows: Bool,
        destinationRouting: DestinationRoutingFilePayload,
        packetTunnelInterfaceName: String? = nil,
        dropTunneledUDP: Bool
    ) {
        self.signingIdentifiers = signingIdentifiers
        self.routeAllIdentifiedFlows = routeAllIdentifiedFlows
        self.destinationRouting = destinationRouting
        self.packetTunnelInterfaceName = packetTunnelInterfaceName
        self.dropTunneledUDP = dropTunneledUDP
    }

    private enum CodingKeys: String, CodingKey {
        case signingIdentifiers
        case routeAllIdentifiedFlows
        case destinationRouting
        case packetTunnelInterfaceName
        case dropTunneledUDP
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signingIdentifiers = try container.decode([String].self, forKey: .signingIdentifiers)
        routeAllIdentifiedFlows = try container.decode(Bool.self, forKey: .routeAllIdentifiedFlows)
        destinationRouting = try container.decode(DestinationRoutingFilePayload.self, forKey: .destinationRouting)
        packetTunnelInterfaceName = try container.decodeIfPresent(String.self, forKey: .packetTunnelInterfaceName)
        // Legacy configs (encoded before Task 7) have no `dropTunneledUDP` key — default false
        // preserves today's WG behavior (tunnel path never drops UDP) for any config in flight.
        dropTunneledUDP = try container.decodeIfPresent(Bool.self, forKey: .dropTunneledUDP) ?? false
    }

    static func encodeBase64(_ config: TransparentProxyRuntimeConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config)
        return data.base64EncodedString()
    }

    static func decode(from providerConfiguration: [String: Any]?) -> TransparentProxyRuntimeConfig? {
        guard let b64 = providerConfiguration?[providerConfigurationKey] as? String,
              let data = Data(base64Encoded: b64)
        else {
            return nil
        }
        return try? JSONDecoder().decode(TransparentProxyRuntimeConfig.self, from: data)
    }
}

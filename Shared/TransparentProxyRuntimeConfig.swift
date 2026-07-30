import Foundation

// DestinationRoutingFilePayload is defined in DestinationRouting.swift (same Shared module)

/// Server-side-DNS target selection (pure). Lives in a dual-target Shared file so both
/// the extension (TCPFlowRelay) and the app's DebugSelfChecks can reference it. In SSH
/// remote-DNS mode we prefer the SNI hostname (resolved on the SSH server) over the
/// app-resolved IP, which a hijacking local resolver may have sinkholed. Falls back to
/// the IP when there is no usable SNI (non-TLS, ECH, truncated ClientHello).
enum RemoteDNSTargetSelector {
    static func target(sni: String?, endpointHostname: String) -> String {
        if let sni, !sni.isEmpty { return sni }
        return endpointHostname
    }
}

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
    /// True when the active profile's transport is SSH (as opposed to WireGuard). SSH mode
    /// resolves DNS on the far end (like `ssh -D` remote DNS) to defeat local DNS hijacking;
    /// nothing consumes this yet (wired up in a later task). Defaults to `false` so legacy
    /// (pre-remote-DNS) encoded configs, which have no such key, decode to the existing
    /// local-resolution behavior unchanged, and WireGuard connects always carry `false`.
    var remoteDNSResolution: Bool
    /// WG mode: tunnel-side DNS resolver IP. A routed app's UDP DNS query aimed at a
    /// local/private resolver (the typical hijacking/sinkholing setup) is rewritten to this
    /// server and sent THROUGH the tunnel instead of being bypassed to the local resolver.
    /// `nil` (SSH mode / legacy configs) disables the redirect.
    var tunnelDNSHost: String?

    static let providerConfigurationKey = "proxyConfigB64"

    init(
        signingIdentifiers: [String],
        routeAllIdentifiedFlows: Bool,
        destinationRouting: DestinationRoutingFilePayload,
        packetTunnelInterfaceName: String? = nil,
        dropTunneledUDP: Bool,
        remoteDNSResolution: Bool,
        tunnelDNSHost: String? = nil
    ) {
        self.signingIdentifiers = signingIdentifiers
        self.routeAllIdentifiedFlows = routeAllIdentifiedFlows
        self.destinationRouting = destinationRouting
        self.packetTunnelInterfaceName = packetTunnelInterfaceName
        self.dropTunneledUDP = dropTunneledUDP
        self.remoteDNSResolution = remoteDNSResolution
        self.tunnelDNSHost = tunnelDNSHost
    }

    private enum CodingKeys: String, CodingKey {
        case signingIdentifiers
        case routeAllIdentifiedFlows
        case destinationRouting
        case packetTunnelInterfaceName
        case dropTunneledUDP
        case remoteDNSResolution
        case tunnelDNSHost
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
        // Legacy configs (encoded before this task) have no `remoteDNSResolution` key — default
        // false preserves today's local-resolution behavior for any config in flight.
        remoteDNSResolution = try container.decodeIfPresent(Bool.self, forKey: .remoteDNSResolution) ?? false
        // Legacy configs have no `tunnelDNSHost` key — nil disables the WG DNS redirect.
        tunnelDNSHost = try container.decodeIfPresent(String.self, forKey: .tunnelDNSHost)
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

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

    static let providerConfigurationKey = "proxyConfigB64"

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

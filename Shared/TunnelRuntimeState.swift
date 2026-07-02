import Foundation

/// WireGuard key material passed from the host app at connect time.
/// System extensions run as root and cannot read the user's login keychain, so secrets
/// travel in `NETunnelProviderProtocol.providerConfiguration` instead of keychain lookups.
struct TunnelSecrets: Codable, Equatable {
    let privateKey: String
    /// Peer UUID string → preshared key value.
    let presharedKeys: [String: String]
}

struct TunnelRuntimeState: Codable {
    let profile: WireGuardProfile
    /// Populated only in providerConfiguration payloads; never persisted to vpn-state.json.
    let secrets: TunnelSecrets?
    /// When set, per-app tunnel utun `includedRoutes` and outbound filtering use these CIDRs
    /// instead of the peer AllowedIPs default-route shape (destination-filtered app-tunnel).
    let appTunnelIncludedRoutes: [String]?
}

extension TunnelRuntimeState {
    static func resolveSecrets(for profile: WireGuardProfile) throws -> TunnelSecrets {
        let privateKey = try KeychainService.shared.read(account: profile.interface.privateKeyRef)
        var presharedKeys: [String: String] = [:]
        for peer in profile.peers {
            if let ref = peer.presharedKeyRef {
                presharedKeys[peer.id.uuidString] = try KeychainService.shared.read(account: ref)
            }
        }
        return TunnelSecrets(privateKey: privateKey, presharedKeys: presharedKeys)
    }
}

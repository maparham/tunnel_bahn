import Foundation

/// WireGuard key material passed from the host app at connect time.
/// System extensions run as root and cannot read the user's login keychain, so secrets
/// travel in `NETunnelProviderProtocol.providerConfiguration` instead of keychain lookups.
struct TunnelSecrets: Codable, Equatable {
    let privateKey: String
    /// Peer UUID string → preshared key value.
    let presharedKeys: [String: String]
}

/// SSH transport connection params carried to the extension. The private key itself is
/// fetched from the shared Keychain by the extension (via `privateKeyRef`), not embedded here.
struct TunnelSSHParams: Codable, Equatable {
    let host: String
    let port: UInt16
    let username: String
    let privateKeyRef: String
    /// The resolved private-key PEM, read from the Keychain **app-side** (uid 501) and carried in
    /// the providerConfiguration payload — mirroring how `TunnelSecrets` carries the WireGuard key.
    /// The root packet-tunnel extension (uid 0) cannot read the user-context Keychain item across
    /// the uid boundary, so it must receive the material here rather than reading it itself. nil in
    /// the non-secret (vpn-state.json) payload.
    let privateKeyPEM: String?
    let hostKeyFingerprint: String?
}

struct TunnelRuntimeState: Codable {
    let profile: WireGuardProfile
    /// Populated only in providerConfiguration payloads; never persisted to vpn-state.json.
    let secrets: TunnelSecrets?
    /// When set, per-app tunnel utun `includedRoutes` and outbound filtering use these CIDRs
    /// instead of the peer AllowedIPs default-route shape (destination-filtered app-tunnel).
    let appTunnelIncludedRoutes: [String]?
    /// When set, the packet tunnel keeps its default route and installs these CIDRs as
    /// utun `excludedRoutes` (full-tunnel exclude filter). Mutually exclusive with
    /// `appTunnelIncludedRoutes` by construction in VPNManager; sanitized host-side so
    /// it never contains the tunnel interface network or DNS server IPs. Optional so a
    /// stale extension decoding an old payload (or an old extension decoding this one)
    /// falls back to plain full-tunnel, which over-tunnels but never leaks.
    let appTunnelExcludedRoutes: [String]?
    /// Present when `profile.transport == .ssh`; mirrors `profile.ssh` so the packet-tunnel
    /// extension has connection params without re-deriving them from the profile.
    let ssh: TunnelSSHParams?
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

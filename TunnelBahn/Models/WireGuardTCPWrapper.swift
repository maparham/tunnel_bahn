import Foundation

/// Optional obfuscation sub-mode on a WireGuard profile: carry the peer's encapsulated
/// UDP inside a wstunnel-v10 WebSocket/TLS connection so WG works on UDP-blocked networks.
/// nil on the profile means plain WireGuard (unchanged behavior). Carries no secrets, so it
/// travels to the extension inside the profile JSON with no Keychain round-trip.
struct WireGuardTCPWrapper: Codable, Hashable {
    /// TLS/WebSocket connect target — where the relay dials (e.g. 3.139.146.5).
    var serverHost: String
    /// TCP port for the connect target (typically 443).
    var serverPort: UInt16
    /// true ⇒ wss (TLS); false ⇒ ws (plaintext, for a standalone non-TLS wstunnel server).
    var tls: Bool
    /// false (default) skips TLS cert validation, matching wstunnel's default. Required for the
    /// reference bare-IP server whose cert will not validate against the IP.
    var verifyCert: Bool
    /// Secret WebSocket path prefix the server routes on (no leading/trailing slash), e.g.
    /// tun74fd08a683078a3e0439. The upgrade path is "/<pathPrefix>/events".
    var pathPrefix: String
    /// Server-side UDP forward target the unwrapper hands datagrams to (JWT "r"), e.g. 127.0.0.1.
    var forwardHost: String
    /// Server-side UDP forward port (JWT "rp"), e.g. 51840.
    var forwardPort: UInt16
    /// Off switches the profile back to plain WireGuard while keeping these settings stored,
    /// so the user can re-enable the wrapper later without retyping them.
    var enabled: Bool = true
}

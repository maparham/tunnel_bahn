import Foundation

struct WireGuardPeer: Codable, Hashable, Identifiable {
    let id: UUID
    var publicKey: String
    var presharedKeyRef: String?
    var endpoint: String
    var allowedIPs: [String]
    var persistentKeepalive: Int?

    init(
        id: UUID = UUID(),
        publicKey: String,
        presharedKeyRef: String? = nil,
        endpoint: String,
        allowedIPs: [String],
        persistentKeepalive: Int? = nil
    ) {
        self.id = id
        self.publicKey = publicKey
        self.presharedKeyRef = presharedKeyRef
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
    }
}

struct WireGuardInterface: Codable, Hashable {
    var privateKeyRef: String
    var addresses: [String]
    var dnsServers: [String]
    var mtu: Int?
}

struct WireGuardProfile: Codable, Identifiable, Hashable {
    /// Maximum displayed length of a profile name. Enforced at the input layer (UI clamps on
    /// edit); the model itself doesn't validate.
    static let maxNameLength = 50

    var id: UUID
    var name: String
    var interface: WireGuardInterface
    var peers: [WireGuardPeer]
    var createdAt: Date
    var updatedAt: Date
    /// Which egress transport this profile uses.
    var transport: TransportKind
    /// Present only when `transport == .ssh`.
    var ssh: SSHProfile?
    /// Present only when this WG profile uses the TCP (WebSocket/TLS) wrapper sub-mode.
    var tcpWrapper: WireGuardTCPWrapper?

    init(
        id: UUID = UUID(),
        name: String,
        interface: WireGuardInterface,
        peers: [WireGuardPeer],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        transport: TransportKind = .wireguard,
        ssh: SSHProfile? = nil,
        tcpWrapper: WireGuardTCPWrapper? = nil
    ) {
        self.id = id
        self.name = name
        self.interface = interface
        self.peers = peers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transport = transport
        self.ssh = ssh
        self.tcpWrapper = tcpWrapper
    }

    /// First IPv4 interface address without CIDR prefix (for PF `route-to` on macOS).
    var firstTunnelIPv4Host: String? {
        for raw in interface.addresses {
            guard !raw.contains(":") else { continue }
            let hostPart = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
            let host = hostPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty { return host }
        }
        return nil
    }
}

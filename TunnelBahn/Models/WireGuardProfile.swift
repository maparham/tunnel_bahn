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
    /// edit); the model itself doesn't validate so legacy data with longer names still loads.
    static let maxNameLength = 50

    var id: UUID
    var name: String
    var interface: WireGuardInterface
    var peers: [WireGuardPeer]
    var createdAt: Date
    var updatedAt: Date
    /// Which egress transport this profile uses. Defaults to `.wireguard` for profiles
    /// saved before SSH transport support existed (see the defaulting `init(from:)` below).
    var transport: TransportKind
    /// Present only when `transport == .ssh`.
    var ssh: SSHProfile?

    init(
        id: UUID = UUID(),
        name: String,
        interface: WireGuardInterface,
        peers: [WireGuardPeer],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        transport: TransportKind = .wireguard,
        ssh: SSHProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.interface = interface
        self.peers = peers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transport = transport
        self.ssh = ssh
    }

    // NOTE: `encode(to:)` below is the COMPILER-SYNTHESIZED implementation (this type only defines
    // `CodingKeys` + a custom `init(from:)`, for the `transport`/`ssh` defaulting below). Synthesis
    // encodes every stored property it can see, keyed by `CodingKeys` — so any NEW stored property
    // added to this struct MUST also be added to `CodingKeys` or it will be silently dropped from
    // persistence (no compile error, no runtime error — the field just never round-trips).
    private enum CodingKeys: String, CodingKey {
        case id, name, interface, peers, createdAt, updatedAt, transport, ssh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        interface = try container.decode(WireGuardInterface.self, forKey: .interface)
        peers = try container.decode([WireGuardPeer].self, forKey: .peers)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        // Profiles saved before SSH transport support have no `transport` key on disk.
        transport = try container.decodeIfPresent(TransportKind.self, forKey: .transport) ?? .wireguard
        ssh = try container.decodeIfPresent(SSHProfile.self, forKey: .ssh)
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

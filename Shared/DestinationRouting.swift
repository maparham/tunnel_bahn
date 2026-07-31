import Darwin
import Foundation

/// Whether the destination rule set selects what to TUNNEL (`include` — the historical
/// whitelist behavior) or what to send DIRECT while everything else tunnels (`exclude`).
public enum DestinationFilterMode: String, Codable, Sendable {
    case include
    case exclude
}

public enum DestinationRouteVerdict: Equatable, Sendable {
    case tunnel
    case direct
}

/// Pure tunnel-vs-direct choice given rule-match results — the single source of truth for
/// both the TCP SNI decider and the UDP per-datagram path, so the two cannot drift.
/// `sniMatch` is nil when no SNI is available (non-TLS, fragmented ClientHello, no peek).
/// Note the fail-open inversion: include mode's no-match falls back to DIRECT; exclude
/// mode's no-match falls back to TUNNEL (unknown traffic belongs in the tunnel there).
public enum DestinationRouteDecision {
    public static func decide(mode: DestinationFilterMode, ipMatch: Bool, sniMatch: Bool?) -> DestinationRouteVerdict {
        let matchesRules = (sniMatch == true) || ipMatch
        switch mode {
        case .include: return matchesRules ? .tunnel : .direct
        case .exclude: return matchesRules ? .direct : .tunnel
        }
    }
}

/// Payload written under the shared App Group (`SharedPaths.destinationRangesFileURL`).
/// Interpreted only by `TransparentProxyProvider` alongside signing-ID snapshots.
public struct DestinationRoutingFilePayload: Codable, Equatable {
    public var enforceDestinationFiltering: Bool
    public var ranges: [String]
    /// Domain-rule names (e.g. `x.com`), lowercased. The transparent proxy matches these against
    /// each TCP flow's TLS SNI to route by hostname — solving the CDN/anycast case where the
    /// browser connects to an IP the host resolver never returned. Empty = no SNI routing (the
    /// proxy keeps its IP-only behavior). Suffix-matched, so `x.com` also covers `api.x.com`.
    public var domainNames: [String]
    public var filterMode: DestinationFilterMode

    public init(enforceDestinationFiltering: Bool, ranges: [String], domainNames: [String] = [], filterMode: DestinationFilterMode = .include) {
        self.enforceDestinationFiltering = enforceDestinationFiltering
        self.ranges = ranges
        self.domainNames = domainNames
        self.filterMode = filterMode
    }
}

public enum DestinationRoutingFileStore {
    public static func write(_ payload: DestinationRoutingFilePayload, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }
}

/// Prepare CIDR literals once after reading the snapshot; IPv4/v6 matching only (no hostname resolution).
public enum IPCIDRMatcher {
    public struct PreparedRange: Sendable {
        enum Kind {
            case v4(network: UInt32, prefixBits: UInt8)
            /// 16-byte network address masked to prefix length (canonical form).
            case v6(network: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8), prefixBits: UInt8)
        }

        let kind: Kind

        func containsLiteralIPv4(_ addr: UInt32) -> Bool {
            guard case let .v4(network, prefixBits) = kind else { return false }
            return IPCIDRMatcher.maskedEqualIPv4(network, addr, prefixBits)
        }

        func containsLiteralIPv6(_ addr: IPv6Octets) -> Bool {
            guard case let .v6(network, prefixBits) = kind else { return false }
            return IPCIDRMatcher.prefixesMatchIPv6(addr, network, prefixBits: Int(prefixBits))
        }
    }

    struct IPv6Octets: Sendable {
        let b: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    }

    public static func prepare(_ cidrs: [String]) -> [PreparedRange] {
        var out: [PreparedRange] = []
        out.reserveCapacity(cidrs.count)
        for raw in cidrs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let entry = parseCIDR(trimmed) {
                out.append(entry)
            }
        }
        return out
    }

    /// `host` trimmed; succeeds only when `NWHostEndpoint` would carry an IPv4/IPv6 literal.
    public static func literalMatches(_ host: String, ranges: [PreparedRange]) -> Bool {
        guard !ranges.isEmpty else { return false }
        let trimmed = stripZone(trimming(host))
        if trimmed.isEmpty { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 {
            let addr = UInt32(bigEndian: v4.s_addr)
            return ranges.contains { $0.containsLiteralIPv4(addr) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            guard let oc = ipv6Octets(from: &v6) else { return false }
            if let mappedV4 = ipv4FromMapped(oc) {
                return ranges.contains { $0.containsLiteralIPv4(mappedV4) }
            }
            return ranges.contains { $0.containsLiteralIPv6(oc) }
        }
        return false
    }

    // MARK: - Internal

    private static func trimming(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip `%…` IPv6 zone identifier — still v1 IPv6 literal semantics only.
    private static func stripZone(_ ip: String) -> String {
        guard let pct = ip.firstIndex(of: "%") else { return ip }
        return String(ip[..<pct])
    }

    /// IPv4-mapped IPv6 (`::ffff:a.b.c.d`, RFC 4291 §2.5.5.2). AF_INET6 sockets (Java, Go, …)
    /// reach IPv4 destinations through this form, so it must match IPv4 ranges — including the
    /// private/LAN bypass, or a mapped LAN destination gets tunneled and black-holes.
    private static func ipv4FromMapped(_ oc: IPv6Octets) -> UInt32? {
        let b = oc.b
        guard b.0 == 0, b.1 == 0, b.2 == 0, b.3 == 0, b.4 == 0, b.5 == 0,
              b.6 == 0, b.7 == 0, b.8 == 0, b.9 == 0, b.10 == 0xFF, b.11 == 0xFF else { return nil }
        return (UInt32(b.12) << 24) | (UInt32(b.13) << 16) | (UInt32(b.14) << 8) | UInt32(b.15)
    }

    private static func parseCIDR(_ raw: String) -> PreparedRange? {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard let addrChunk = parts.first else { return nil }
        let ipPart = stripZone(trimming(addrChunk))

        let prefixBits: UInt8?
        if parts.count > 1 {
            guard let pb = Int(parts[1]), pb >= 0, pb <= 128 else { return nil }
            prefixBits = UInt8(pb)
        } else {
            prefixBits = nil
        }

        var v4 = in_addr()
        if inet_pton(AF_INET, ipPart, &v4) == 1 {
            // The guard above only bounds the prefix to the IPv6 max (128); an IPv4 literal with
            // a prefix > 32 (e.g. "1.2.3.4/40") is invalid input and must be rejected, not
            // silently clamped to a /32 host route.
            if let pb = prefixBits, pb > 32 { return nil }
            let pb = prefixBits ?? 32
            let net = maskedIPv4(UInt32(bigEndian: v4.s_addr), pb)
            return PreparedRange(kind: .v4(network: net, prefixBits: pb))
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, ipPart, &v6) == 1 {
            let pbFull = UInt8(min(Int(prefixBits ?? 128), 128))
            guard let raw = ipv6Octets(from: &v6) else { return nil }
            let masked = ipv6MaskedNetwork(raw.b, prefixBits: Int(pbFull))
            return PreparedRange(kind: .v6(network: masked, prefixBits: pbFull))
        }

        return nil
    }

    private static func ipv6Octets(from v6: inout in6_addr) -> IPv6Octets? {
        var copy = v6
        return withUnsafeMutablePointer(to: &copy.__u6_addr.__u6_addr8) { tuplePtr -> IPv6Octets in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: 16) { buf in
                IPv6Octets(b: (
                    buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7],
                    buf[8], buf[9], buf[10], buf[11], buf[12], buf[13], buf[14], buf[15],
                ))
            }
        }
    }

    private static func ipv6MaskedNetwork(
        _ octets: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8),
        prefixBits: Int
    ) -> (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) {
        var arr = ipv6OctetArray(from: octets)
        let p = Swift.min(prefixBits, 128)
        if p <= 0 {
            return ipv6Zeros
        }

        let fullBytes = p >> 3
        let rem = p & 7

        if rem != 0, fullBytes < 16 {
            let clearLowBits = UInt8((1 << (8 - rem)) - 1)
            arr[fullBytes] &= ~clearLowBits
        }

        let zeroFrom: Int
        if rem == 0 {
            zeroFrom = fullBytes
        } else {
            zeroFrom = fullBytes.advanced(by: 1)
        }

        guard zeroFrom < 16 else {
            return ipv16Tuple(from: arr)
        }

        for idx in zeroFrom ..< 16 {
            arr[idx] = 0
        }

        return ipv16Tuple(from: arr)
    }

    private static func ipv16Tuple(from octets: [UInt8]) -> (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) {
        precondition(octets.count == 16)
        return (
            octets[0],
            octets[1],
            octets[2],
            octets[3],
            octets[4],
            octets[5],
            octets[6],
            octets[7],
            octets[8],
            octets[9],
            octets[10],
            octets[11],
            octets[12],
            octets[13],
            octets[14],
            octets[15],
        )
    }

    private static func ipv6OctetArray(from t: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )) -> [UInt8] {
        [t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15]
    }

    private static let ipv6Zeros = (
        UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
        UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
    )

    private static func prefixesMatchIPv6(
        _ a: IPv6Octets,
        _ network: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ),
        prefixBits: Int
    ) -> Bool {
        let p = Swift.min(prefixBits, 128)
        if p >= 128 { return ipv6Equality(a.b, network) }
        let fullBytes = p >> 3
        let rem = p & 7
        if fullBytes >= 16 { return ipv6Equality(a.b, network) }
        let la = ipv6OctetArray(from: a.b)
        let nw = ipv6OctetArray(from: network)

        var i = 0
        while i < fullBytes {
            guard la[i] == nw[i] else { return false }
            i += 1
        }
        if rem == 0 { return true }
        let masked = UInt16(la[fullBytes]) >> UInt16(8 - rem)
            == UInt16(nw[fullBytes]) >> UInt16(8 - rem)
        return masked
    }

    private static func ipv6Equality(
        _ a: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ),
        _ b: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )
    ) -> Bool {
        ipv6OctetArray(from: a) == ipv6OctetArray(from: b)
    }

    private static func maskedIPv4(_ addr: UInt32, _ prefixBits: UInt8) -> UInt32 {
        if prefixBits >= 32 { return addr }
        guard prefixBits > 0 else { return 0 }
        let hi = ~(UInt32(0xffffffff) >> UInt32(prefixBits))
        return addr & hi
    }

    private static func maskedEqualIPv4(_ lhs: UInt32, _ rhs: UInt32, _ prefixBits: UInt8) -> Bool {
        if prefixBits >= 32 { return lhs == rhs }
        if prefixBits == 0 { return true }
        let hi = ~(UInt32(0xffffffff) >> UInt32(prefixBits))
        return (lhs & hi) == (rhs & hi)
    }

}

public extension IPCIDRMatcher {
    /// Private / loopback / link-local ranges (RFC-1918, RFC-4193 ULA, etc.) that the WireGuard peer
    /// has no route back to. A flow to one of these must exit DIRECTLY, never through the tunnel —
    /// otherwise it black-holes. The system DNS resolver is frequently such an address (e.g. a local
    /// resolver installed by another VPN like Cloudflare WARP), which is why tunneling it kills every
    /// lookup and, with it, nearly all browsing.
    ///
    /// NOTE: if DNS is ever redirected to the tunnel resolver (e.g. 10.2.0.1, itself inside 10/8),
    /// that rewrite must happen BEFORE this check so the redirected target isn't bounced to direct.
    static let localBypassRanges: [PreparedRange] = prepare([
        "0.0.0.0/8",        // "this host/network" — 0.0.0.0 is a loopback-equivalent dest on macOS
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10",    // RFC-6598 CGNAT / Tailscale — not routable through the WG peer
        "169.254.0.0/16",   // IPv4 link-local
        "127.0.0.0/8",      // loopback
        "224.0.0.0/4",      // IPv4 multicast (mDNS/SSDP) — never a tunnelable unicast dest
        "255.255.255.255/32", // limited broadcast
        "::1/128",          // IPv6 loopback
        "fc00::/7",         // IPv6 unique-local
        "fe80::/10",        // IPv6 link-local
        "ff00::/8",         // IPv6 multicast
    ])

    /// True when `host` is an IPv4/IPv6 literal that falls in a private/local range (see
    /// `localBypassRanges`). Non-literals (hostnames) return false, so the caller tunnels by default.
    static func isLocalLiteral(_ host: String) -> Bool {
        literalMatches(host, ranges: localBypassRanges)
    }

    /// Subset of `localBypassRanges` a user may legitimately override by listing a destination
    /// CIDR: routable private space that a remote LAN behind the WG peer can actually host
    /// (RFC-1918, CGNAT, IPv6 ULA). Loopback, link-local, multicast, broadcast, and 0/8 stay
    /// unconditionally bypassed — no peer can ever route those back, so even an explicit rule
    /// (e.g. a catch-all 0.0.0.0/0 destination CIDR) must not tunnel them.
    static let overridablePrivateRanges: [PreparedRange] = prepare([
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10",
        "fc00::/7",
    ])

    /// Shared bypass predicate for the transparent proxy's TCP flow-open and UDP per-datagram
    /// routing decisions (the single source of truth — do not hand-roll this composition at call
    /// sites). A private/local destination exits directly UNLESS the user explicitly configured
    /// it for tunneling (`tunnelRanges`) AND it lives in overridable (routable-private) space —
    /// with WireGuard-to-a-remote-LAN the peer *is* the gateway to those ranges.
    ///
    /// `tunnelRanges` is an autoclosure so callers whose snapshot is expensive (e.g. a
    /// lock-guarded live read per UDP datagram) only pay for it when `host` is actually local.
    static func shouldBypassLocal(
        _ host: String,
        tunnelRanges: @autoclosure () -> [PreparedRange]
    ) -> Bool {
        guard isLocalLiteral(host) else { return false }
        return !(literalMatches(host, ranges: overridablePrivateRanges)
            && literalMatches(host, ranges: tunnelRanges()))
    }
}

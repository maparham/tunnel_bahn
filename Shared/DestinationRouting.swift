import Darwin
import Foundation

/// Payload written under the shared App Group (`SharedPaths.destinationRangesFileURL`).
/// Interpreted only by `TransparentProxyProvider` alongside signing-ID snapshots.
public struct DestinationRoutingFilePayload: Codable, Equatable {
    /// Current on-disk encoding version; incremented when incompatible changes happen.
    public var schemaVersion: Int
    public var enforceDestinationFiltering: Bool
    public var ranges: [String]

    public init(schemaVersion: Int = 1, enforceDestinationFiltering: Bool, ranges: [String]) {
        self.schemaVersion = schemaVersion
        self.enforceDestinationFiltering = enforceDestinationFiltering
        self.ranges = ranges
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enforceDestinationFiltering
        case ranges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enforceDestinationFiltering = try c.decodeIfPresent(Bool.self, forKey: .enforceDestinationFiltering) ?? false
        ranges = try c.decodeIfPresent([String].self, forKey: .ranges) ?? []
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
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
            let pbNumeric = Swift.min(prefixBits.map(Int.init) ?? 32, 32)
            let pb = UInt8(pbNumeric)
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

import Foundation

/// Kernel route-shape computation for the full-tunnel destination-filter shape
/// (`isFullTunnelDestFilterShape` in VPNManager). Pure and NetworkExtension-free so the
/// unit-test target can exercise it; VPNManager consumes it at connect time and persists
/// the result into `TunnelRuntimeState`.
public enum TunnelRouteShape {
    /// The utun route override for a full-tunnel destination filter. Exactly one of the
    /// two route lists is non-nil, keyed by filter mode.
    public struct RouteOverride: Equatable {
        /// Include mode: filter CIDRs + DNS host routes, installed as narrowed
        /// `includedRoutes`. nil in exclude mode.
        public let includedRoutes: [String]?
        /// Exclude mode: sanitized filter CIDRs, installed as `excludedRoutes` while the
        /// default route stays. nil in include mode.
        public let excludedRoutes: [String]?
        /// Exclude CIDRs dropped by sanitization because they contain a tunnel interface
        /// address or DNS server IP. Installing those as kernel excludedRoutes would
        /// black-hole the WireGuard virtual network or DNS for utun-scoped traffic. The
        /// caller logs these; the transparent proxy still honors the user's direct
        /// verdict for such destinations at flow level.
        public let droppedExcludedRoutes: [String]
    }

    /// - include: utun `includedRoutes` narrow to the filter CIDRs plus /32 (v4) and
    ///   /128 (v6) host routes for the tunnel DNS servers, which live inside the
    ///   WireGuard virtual network and are unreachable if not routed through utun.
    /// - exclude: utun keeps its default route; `excludedRoutes` carry the filter CIDRs
    ///   minus any CIDR containing a protected IP (interface address or DNS server).
    public static func fullTunnelOverride(
        filterMode: DestinationFilterMode,
        destinationCidrs: [String],
        interfaceAddresses: [String],
        dnsServers: [String]
    ) -> RouteOverride {
        switch filterMode {
        case .include:
            let dnsHostRoutes = dnsServers.map { $0.contains(":") ? "\($0)/128" : "\($0)/32" }
            return RouteOverride(
                includedRoutes: destinationCidrs + dnsHostRoutes,
                excludedRoutes: nil,
                droppedExcludedRoutes: []
            )
        case .exclude:
            let protectedIPs = dnsServers + interfaceAddresses.map { addr in
                addr.split(separator: "/").first.map(String.init) ?? addr
            }
            var kept: [String] = []
            var dropped: [String] = []
            for cidr in destinationCidrs {
                let prepared = IPCIDRMatcher.prepare([cidr])
                let conflicts = protectedIPs.contains { IPCIDRMatcher.literalMatches($0, ranges: prepared) }
                if conflicts {
                    dropped.append(cidr)
                } else {
                    kept.append(cidr)
                }
            }
            return RouteOverride(
                includedRoutes: nil,
                excludedRoutes: kept,
                droppedExcludedRoutes: dropped
            )
        }
    }
}

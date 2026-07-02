import Darwin
import Foundation
import OSLog

/// Log tag for grep: `APPSPLIT_PROBE`
enum TunnelProbePhase: String {
    /// Destination-based routing; app traffic should use the tunnel.
    case fullTunnel = "full_tunnel"
    /// App-tunnel VPN with host app bundle in `NEAppRule` — app-initiated probes should match Chrome-like behavior.
    case appTunnelHostIncluded = "app_tunnel_host_included"
    /// App-tunnel VPN without host app rule — probes from TunnelBahn likely bypass the tunnel (compare to Chrome).
    case appTunnelHostExcluded = "app_tunnel_host_excluded"
}

enum TunnelConnectivityProbe {
    private static let log = AppLog(subsystem: "com.tunnelbahn.mac", category: "TunnelProbe")
    /// Initial probe after connect: slow handshakes / routing convergence often need >2s.
    private static let warmupProbeTimeout: TimeInterval = 8
    private static let warmupAttempts = 8
    /// Periodic recheck: shorter so a dead tunnel surfaces within a reasonable window.
    private static let recheckProbeTimeout: TimeInterval = 5

    /// Up to `warmupAttempts` google204 checks with `warmupProbeTimeout` each. Returns `.ok` on the first
    /// success (fast path for tunnels that need a moment for the WireGuard handshake). Returns `.failed`
    /// only if all attempts time out or error. Fires ipify + DNS diagnostics once after the final outcome.
    static func warmup(phase: TunnelProbePhase, comparePublicIP: String?) async -> ConnectivityProbeResult {
        Self.log.notice(
            "[APPSPLIT_PROBE] warmup begin phase=\(phase.rawValue)"
        )
        for attempt in 1...warmupAttempts {
            let reachable = await probeGoogle204(phase: phase, timeoutInterval: warmupProbeTimeout)
            if reachable {
                Self.log.notice("[APPSPLIT_PROBE] warmup ok attempt=\(attempt)")
                Task.detached(priority: .utility) { await logDNSResolution(phase: phase, host: "www.google.com") }
                Task.detached(priority: .utility) { await probeIpify(phase: phase, comparePublicIP: comparePublicIP) }
                return .ok
            }
        }
        Self.log.notice("[APPSPLIT_PROBE] warmup failed all attempts phase=\(phase.rawValue)")
        Task.detached(priority: .utility) { await logDNSResolution(phase: phase, host: "www.google.com") }
        Task.detached(priority: .utility) { await probeIpify(phase: phase, comparePublicIP: comparePublicIP) }
        return .failed("No internet response via tunnel (endpoint may be unreachable)")
    }

    /// Single google204 check used by the periodic re-probe loop. No ipify/DNS side-probes.
    static func recheck(phase: TunnelProbePhase) async -> ConnectivityProbeResult {
        let reachable = await probeGoogle204(phase: phase, timeoutInterval: recheckProbeTimeout)
        return reachable ? .ok : .failed("No internet response via tunnel (endpoint may be unreachable)")
    }

    private static func probeGoogle204(phase: TunnelProbePhase, timeoutInterval: TimeInterval) async -> Bool {
        guard let url = URL(string: "https://www.google.com/generate_204") else { return false }
        let t0 = Date()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeoutInterval
            request.httpMethod = "GET"
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsedMs = max(0, Int(Date().timeIntervalSince(t0) * 1000))
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let line =
                "[APPSPLIT_PROBE] step=google204 phase=\(phase.rawValue) outcome=ok http=\(code) ms=\(elapsedMs)"
            Self.log.notice("\(line)")
            return true
        } catch {
            let line =
                "[APPSPLIT_PROBE] step=google204 phase=\(phase.rawValue) outcome=fail error=\(error.localizedDescription)"
            Self.log.error("\(line)")
            return false
        }
    }

    private static func probeIpify(phase: TunnelProbePhase, comparePublicIP: String?) async {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        let t0 = Date()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            let elapsedMs = max(0, Int(Date().timeIntervalSince(t0) * 1000))
            let ip = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let match: String
            if let pub = comparePublicIP, !pub.isEmpty, !ip.isEmpty {
                match = pub == ip ? "match" : "mismatch"
            } else {
                match = "n/a"
            }
            let line =
                "[APPSPLIT_PROBE] step=ipify phase=\(phase.rawValue) outcome=ok ip=\(ip) vs_publicIP=\(comparePublicIP ?? "nil") compare=\(match) ms=\(elapsedMs)"
            Self.log.notice("\(line)")
        } catch {
            let line =
                "[APPSPLIT_PROBE] step=ipify phase=\(phase.rawValue) outcome=fail error=\(error.localizedDescription)"
            Self.log.error("\(line)")
        }
    }

    private static func logDNSResolution(phase: TunnelProbePhase, host: String) async {
        await Task.detached(priority: .utility) {
            var hints = addrinfo(
                ai_flags: AI_DEFAULT,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, "443", &hints, &result)
            defer { if let result { freeaddrinfo(result) } }
            if status != 0 {
                let err = String(cString: gai_strerror(status))
                let line =
                    "[APPSPLIT_PROBE] step=dns_lookup phase=\(phase.rawValue) host=\(host) outcome=fail error=\(err)"
                Self.log.error("\(line)")
                return
            }
            var ips: [String] = []
            var ptr = result
            while let current = ptr {
                let addr = current.pointee.ai_addr
                if current.pointee.ai_family == AF_INET, let s = formatSockaddr(addr) {
                    ips.append(s)
                } else if current.pointee.ai_family == AF_INET6, let s = formatSockaddr(addr) {
                    ips.append(s)
                }
                ptr = current.pointee.ai_next
            }
            let joined = ips.prefix(4).joined(separator: ",")
            let line =
                "[APPSPLIT_PROBE] step=dns_lookup phase=\(phase.rawValue) host=\(host) outcome=ok sample=\(joined)"
            Self.log.notice("\(line)")
        }.value
    }

    private static func formatSockaddr(_ addr: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let addr else { return nil }
        switch Int32(addr.pointee.sa_family) {
        case AF_INET:
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var copy = sin.pointee.sin_addr
                guard inet_ntop(AF_INET, &copy, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buf)
            }
        case AF_INET6:
            return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var copy = sin6.pointee.sin6_addr
                guard inet_ntop(AF_INET6, &copy, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buf)
            }
        default:
            return nil
        }
    }
}

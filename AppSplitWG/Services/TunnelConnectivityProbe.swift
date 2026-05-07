import Darwin
import Foundation
import OSLog

/// Log tag for grep: `APPSPLIT_PROBE`
enum TunnelProbePhase: String {
    /// Destination-based routing; app traffic should use the tunnel.
    case fullTunnel = "full_tunnel"
    /// Per-app VPN with host app bundle in `NEAppRule` — app-initiated probes should match Chrome-like behavior.
    case perAppHostIncluded = "per_app_host_included"
    /// Per-app VPN without host app rule — probes from AppSplitWG likely bypass the tunnel (compare to Chrome).
    case perAppHostExcluded = "per_app_host_excluded"
}

enum TunnelConnectivityProbe {
    private static let log = Logger(subsystem: "com.appsplit.wg", category: "TunnelProbe")

    /// Lightweight HTTPS checks after the tunnel is up. Logs one line per step prefixed with `[APPSPLIT_PROBE]`.
    static func run(phase: TunnelProbePhase, comparePublicIP: String?) async {
        Self.log.notice(
            "[APPSPLIT_PROBE] begin phase=\(phase.rawValue, privacy: .public) comparePublicIP=\(comparePublicIP ?? "nil", privacy: .public)"
        )

        await probeGoogle204(phase: phase)
        await probeIpify(phase: phase, comparePublicIP: comparePublicIP)
        await logDNSResolution(phase: phase, host: "www.google.com")
    }

    private static func probeGoogle204(phase: TunnelProbePhase) async {
        guard let url = URL(string: "https://www.google.com/generate_204") else { return }
        let t0 = Date()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.httpMethod = "GET"
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsedMs = max(0, Int(Date().timeIntervalSince(t0) * 1000))
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let line =
                "[APPSPLIT_PROBE] step=google204 phase=\(phase.rawValue) outcome=ok http=\(code) ms=\(elapsedMs)"
            Self.log.notice("\(line, privacy: .public)")
        } catch {
            let line =
                "[APPSPLIT_PROBE] step=google204 phase=\(phase.rawValue) outcome=fail error=\(error.localizedDescription)"
            Self.log.error("\(line, privacy: .public)")
        }
    }

    private static func probeIpify(phase: TunnelProbePhase, comparePublicIP: String?) async {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        let t0 = Date()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
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
            Self.log.notice("\(line, privacy: .public)")
        } catch {
            let line =
                "[APPSPLIT_PROBE] step=ipify phase=\(phase.rawValue) outcome=fail error=\(error.localizedDescription)"
            Self.log.error("\(line, privacy: .public)")
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
                Self.log.error("\(line, privacy: .public)")
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
            Self.log.notice("\(line, privacy: .public)")
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

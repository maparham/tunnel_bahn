import Darwin
import Foundation

/// PTR-style reverse lookups for display; uses the system resolver (`getnameinfo` + `NI_NAMEREQD`).
@MainActor
final class ReverseDNSResolver: ObservableObject {
    /// User-visible label: `"hostname · ip"` when a PTR exists, otherwise the literal unchanged.
    @Published private(set) var displayLabelByLiteral: [String: String] = [:]

    private var negativeCacheUntil: [String: Date] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    private let negativeCacheTTL: TimeInterval = 120

    func displayLabel(for literal: String) -> String {
        displayLabelByLiteral[literal] ?? literal
    }

    func accessibilityLabel(for literal: String) -> String {
        let label = displayLabel(for: literal)
        if let range = label.range(of: Self.separator) {
            let host = String(label[..<range.lowerBound])
            let ip = String(label[range.upperBound...])
            return "\(host), IP address \(ip)"
        }
        return label
    }

    /// Resolves `literal` when it parses as IPv4/IPv6; non-IP strings are left to default display.
    func resolve(_ literal: String) async {
        guard Self.isNumericIP(literal) else { return }

        if let until = negativeCacheUntil[literal], until > Date() { return }
        if let label = displayLabelByLiteral[literal], label.contains(Self.separator) { return }

        if let task = inFlight[literal] {
            await task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            defer { self?.inFlight[literal] = nil }
            let host = await Task.detached {
                Self.reverseLookupHost(literal)
            }.value

            if let host, !host.isEmpty, host.caseInsensitiveCompare(literal) != .orderedSame {
                self?.displayLabelByLiteral[literal] = "\(host)\(Self.separator)\(literal)"
            } else if let self {
                self.negativeCacheUntil[literal] = Date().addingTimeInterval(self.negativeCacheTTL)
            }
        }
        inFlight[literal] = task
        await task.value
    }

    private static let separator = " · "

    private static func isNumericIP(_ literal: String) -> Bool {
        let forParse = literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal
        var addr4 = in_addr()
        if inet_pton(AF_INET, forParse, &addr4) == 1 { return true }
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, forParse, &addr6) == 1 { return true }
        return false
    }

    /// Runs off the main thread; synchronous DNS inside.
    nonisolated private static func reverseLookupHost(_ literal: String) -> String? {
        let forParse = literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal

        var addr4 = sockaddr_in()
        if inet_pton(AF_INET, forParse, &addr4.sin_addr) == 1 {
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            return getNameInfo(from: &addr4, addressLength: socklen_t(MemoryLayout<sockaddr_in>.size))
        }

        var addr6 = sockaddr_in6()
        if inet_pton(AF_INET6, forParse, &addr6.sin6_addr) == 1 {
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            return getNameInfo(from: &addr6, addressLength: socklen_t(MemoryLayout<sockaddr_in6>.size))
        }

        return nil
    }

    nonisolated private static func getNameInfo<T>(from address: inout T, addressLength: socklen_t) -> String? {
        withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let err = getnameinfo(
                    sap,
                    addressLength,
                    &hostBuf,
                    socklen_t(hostBuf.count),
                    nil,
                    0,
                    NI_NAMEREQD
                )
                guard err == 0 else { return nil }
                return String(cString: hostBuf)
            }
        }
    }
}

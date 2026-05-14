import dnssd
import Foundation

struct DomainResolutionResult {
    /// IPv4 host prefixes as "/32" CIDRs and IPv6 as "/128" CIDRs.
    var cidrs: [String]
    /// TTL in seconds, clamped to [minTTL, maxTTL].
    var ttl: TimeInterval
}

enum DomainResolverError: Error, LocalizedError {
    case setupFailed(code: Int32)
    case noAddressesFound
    case timeout

    var errorDescription: String? {
        switch self {
        case .setupFailed(let code): return "DNS setup failed (code \(code))"
        case .noAddressesFound: return "No addresses found"
        case .timeout: return "DNS query timed out"
        }
    }
}

enum DomainResolver {
    static let minTTL: TimeInterval = 60
    static let maxTTL: TimeInterval = 300
    private static let queryTimeout: TimeInterval = 10

    /// Resolves A + AAAA records for `domain`. Safe to call from any async context.
    static func resolve(domain: String) async throws -> DomainResolutionResult {
        try await withCheckedThrowingContinuation { continuation in
            let ctx = DNSQueryContext(continuation: continuation)
            let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

            let protocolFlags = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)

            let err = DNSServiceGetAddrInfo(
                &ctx.sdRef,
                0,
                0,
                protocolFlags,
                domain,
                addrInfoCallback,
                ctxPtr
            )

            guard err == kDNSServiceErr_NoError else {
                Unmanaged<DNSQueryContext>.fromOpaque(ctxPtr).release()
                continuation.resume(throwing: DomainResolverError.setupFailed(code: err))
                return
            }

            // Deliver callbacks on a private serial queue via the recommended dispatch-queue API.
            let queue = DispatchQueue(label: "dns.resolve.\(domain)", qos: .userInitiated)
            DNSServiceSetDispatchQueue(ctx.sdRef, queue)

            // Hard timeout — cancelled once finalize() is called.
            ctx.timeoutWork = DispatchWorkItem { [weak ctx] in
                ctx?.finalize(with: .failure(DomainResolverError.timeout))
            }
            queue.asyncAfter(deadline: .now() + queryTimeout, execute: ctx.timeoutWork!)
        }
    }
}

// MARK: - C callback (must be a free function / closure with no captures)

private let addrInfoCallback: DNSServiceGetAddrInfoReply = { _, flags, _, errCode, _, addressPtr, ttl, rawCtx in
    guard let rawCtx else { return }
    let ctx = Unmanaged<DNSQueryContext>.fromOpaque(rawCtx).takeUnretainedValue()
    guard !ctx.done else { return }

    if errCode != kDNSServiceErr_NoError {
        ctx.finalize(with: .failure(DomainResolverError.setupFailed(code: errCode)))
        return
    }

    if let addressPtr {
        let family = Int32(addressPtr.pointee.sa_family)
        if family == AF_INET {
            addressPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var addr = sin.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    ctx.cidrs.append("\(String(cString: buf))/32")
                }
            }
            if ttl > 0 { ctx.minTTL = min(ctx.minTTL, ttl) }
        } else if family == AF_INET6 {
            addressPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                // Skip link-local (scope_id != 0 means scoped address).
                guard sin6.pointee.sin6_scope_id == 0 else { return }
                var addr = sin6.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    ctx.cidrs.append("\(String(cString: buf))/128")
                }
            }
            if ttl > 0 { ctx.minTTL = min(ctx.minTTL, ttl) }
        }
    }

    let moreComingMask = DNSServiceFlags(kDNSServiceFlagsMoreComing)
    let moreComing = (flags & moreComingMask) != 0
    if !moreComing {
        let result: Result<DomainResolutionResult, Error>
        if ctx.cidrs.isEmpty {
            result = .failure(DomainResolverError.noAddressesFound)
        } else {
            let rawTTL = ctx.minTTL == UInt32.max ? UInt32(DomainResolver.minTTL) : ctx.minTTL
            let clamped = min(max(TimeInterval(rawTTL), DomainResolver.minTTL), DomainResolver.maxTTL)
            result = .success(DomainResolutionResult(cidrs: ctx.cidrs, ttl: clamped))
        }
        ctx.finalize(with: result)
    }
}

// MARK: - Context object

private final class DNSQueryContext {
    var sdRef: DNSServiceRef? = nil
    var cidrs: [String] = []
    var minTTL: UInt32 = UInt32.max
    var timeoutWork: DispatchWorkItem?
    private(set) var done = false

    private let continuation: CheckedContinuation<DomainResolutionResult, Error>
    private let lock = NSLock()

    init(continuation: CheckedContinuation<DomainResolutionResult, Error>) {
        self.continuation = continuation
    }

    func finalize(with result: Result<DomainResolutionResult, Error>) {
        lock.lock()
        let alreadyDone = done
        done = true
        lock.unlock()

        guard !alreadyDone else { return }

        timeoutWork?.cancel()
        timeoutWork = nil

        if let sdRef {
            DNSServiceRefDeallocate(sdRef)
            self.sdRef = nil
        }
        // Release the +1 retain from passRetained in resolve().
        Unmanaged.passUnretained(self).release()

        switch result {
        case .success(let r): continuation.resume(returning: r)
        case .failure(let e): continuation.resume(throwing: e)
        }
    }
}

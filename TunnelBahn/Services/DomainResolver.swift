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

            // Hard timeout — cancelled once finalize() is called. Runs on the same serial queue
            // as the callbacks, so reading ctx state here is race-free. A partial answer (one
            // family collected, the other silently never terminal) succeeds with what we have
            // rather than discarding usable records as a timeout failure.
            ctx.timeoutWork = DispatchWorkItem { [weak ctx] in
                guard let ctx else { return }
                if ctx.cidrs.isEmpty {
                    ctx.finalize(with: .failure(DomainResolverError.timeout))
                } else {
                    ctx.finalize(with: .success(DomainResolutionResult(cidrs: ctx.cidrs, ttl: ctx.clampedTTL)))
                }
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
        // A dual-protocol query answers each family separately; NoSuchRecord for one family
        // (e.g. no AAAA on an IPv4-only domain) is a valid negative answer, not a failure.
        // Failing here would discard records already collected for the other family.
        guard errCode == kDNSServiceErr_NoSuchRecord else {
            ctx.finalize(with: .failure(DomainResolverError.setupFailed(code: errCode)))
            return
        }
        if let addressPtr {
            ctx.negativeFamilies.insert(Int32(addressPtr.pointee.sa_family))
        }
    } else if let addressPtr {
        let family = Int32(addressPtr.pointee.sa_family)
        ctx.answeredFamilies.insert(family)
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
        // moreComing==0 only means "nothing else queued right now", NOT "query complete" — the
        // two families answer as separate record streams, and finalizing on the first family's
        // positive answer silently drops the other family's records (e.g. a cached A landing
        // before the AAAA network answer → the domain's IPv6 destinations never get routed).
        // Finalize only once BOTH families have reached a terminal state (a positive record or
        // NoSuchRecord); otherwise leave the query open for the other family or the timeout.
        let terminalFamilies = ctx.answeredFamilies.union(ctx.negativeFamilies)
        if terminalFamilies.contains(AF_INET) && terminalFamilies.contains(AF_INET6) {
            if !ctx.cidrs.isEmpty {
                ctx.finalize(with: .success(DomainResolutionResult(cidrs: ctx.cidrs, ttl: ctx.clampedTTL)))
            } else {
                ctx.finalize(with: .failure(DomainResolverError.noAddressesFound))
            }
        }
    }
}

// MARK: - Context object

private final class DNSQueryContext {
    var sdRef: DNSServiceRef? = nil
    var cidrs: [String] = []
    /// Address families (AF_INET/AF_INET6) that answered NoSuchRecord.
    var negativeFamilies: Set<Int32> = []
    /// Address families that delivered at least one positive record.
    var answeredFamilies: Set<Int32> = []
    var minTTL: UInt32 = UInt32.max
    var timeoutWork: DispatchWorkItem?
    private(set) var done = false

    /// Collected minimum TTL clamped to the resolver's [minTTL, maxTTL] policy window.
    var clampedTTL: TimeInterval {
        let rawTTL = minTTL == UInt32.max ? UInt32(DomainResolver.minTTL) : minTTL
        return min(max(TimeInterval(rawTTL), DomainResolver.minTTL), DomainResolver.maxTTL)
    }

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

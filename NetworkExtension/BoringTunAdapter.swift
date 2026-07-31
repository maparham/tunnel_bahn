import Darwin
import Foundation
import NetworkExtension
import os.log

private enum BoringTunAdapterError: LocalizedError {
    case missingProvider
    case noPeer
    case invalidEndpoint(String)
    case tunnelInitFailed
    case presharedKeyUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return "Packet tunnel provider is unavailable."
        case .noPeer:
            return "No WireGuard peer is configured."
        case let .invalidEndpoint(endpoint):
            return "Invalid peer endpoint: \(endpoint)"
        case .tunnelInitFailed:
            return "Failed to create BoringTun tunnel (check keys and endpoint)."
        case let .presharedKeyUnreadable(message):
            return "Could not load preshared key: \(message)"
        }
    }
}

/// WireGuard data plane using Cloudflare BoringTun over `NEPacketTunnelFlow` and `NWUDPSession`
/// (suitable for app-tunnel VPN where raw utun file-descriptor access is not reliable).
final class BoringTunAdapter: @unchecked Sendable {
    private static let log = AppLog(subsystem: "com.tunnelbahn.mac.networkextension", category: "BoringTunAdapter")

    private weak var provider: NEPacketTunnelProvider?
    private let ioQueue = DispatchQueue(label: "com.tunnelbahn.mac.boringtun")

    private var tunnel: UnsafeMutableRawPointer?
    private var udpSession: NWUDPSession?
    private var udpStateObservation: NSKeyValueObservation?
    private var tickTimer: DispatchSourceTimer?
    private var isRunning = false
    /// Ensures UDP read handler / packet flow / tick are only started once per session.
    private var tunnelIOStarted = false

    // MARK: - Transport recovery state (ioQueue only)

    /// Remote WireGuard endpoint, retained so the transport can be rebuilt on path change / stall.
    private var remoteEndpoint: NWHostEndpoint?
    /// Configured persistent keepalive (seconds); 0 = disabled. Drives the liveness thresholds.
    private var persistentKeepaliveSeconds: UInt16 = 0
    /// Bumped on every `establishUDPSession`; stale KVO callbacks compare against it and bail.
    private var udpSessionGeneration: UInt64 = 0
    private var udpBetterPathObservation: NSKeyValueObservation?
    private var udpViableObservation: NSKeyValueObservation?
    /// Periodically checks for a silently-dead transport (we transmit, nothing returns).
    private var watchdogTimer: DispatchSourceTimer?
    /// Wall-clock time the current NWUDPSession was created.
    private var sessionEstablishedAt: Date?
    /// Wall-clock time of the most recent datagram we wrote to the transport.
    private var lastOutboundAt: Date?

    /// Self-rescheduling timer that keeps rebuilding the transport until a session reaches
    /// `.ready`. Closes the gap between a rebuild that fails (or hangs) immediately and the
    /// slow liveness-watchdog backstop. Cancelled the moment a session goes `.ready`.
    private var reconnectRetryTimer: DispatchSourceTimer?
    /// Current backoff for `reconnectRetryTimer`; reset to the floor once `.ready`.
    private var reconnectRetryDelay: TimeInterval = 3

    /// Rebuilds the BoringTun crypto object with the same keys. Every real recovery recreates it
    /// alongside the socket — the in-process equivalent of a manual reconnect — because a session
    /// that expired during an outage cannot be revived in place (decap then fails with error 13
    /// indefinitely, and force_handshake does not clear it). Set in `start()`.
    private var tunnelFactory: (() -> UnsafeMutableRawPointer?)?

    /// Minimum spacing between transport rebuilds, to avoid thrash when a path flaps.
    private static let minReestablishInterval: TimeInterval = 3
    // 2s (was 5s) so the liveness check evaluates a stall ~2.5× sooner — recovery latency is
    // dominated by how often this fires. Safe: every recovery branch is still gated by
    // `recentlySentRealData`, so an idle/keepalive-only tunnel is never judged.
    private static let watchdogInterval: DispatchTimeInterval = .seconds(2)
    /// Reconnect-retry backoff bounds: start fast (floor) so a brief network blip recovers in
    /// seconds, cap (ceil) so a genuinely-down network doesn't spin.
    private static let reconnectRetryFloor: TimeInterval = 3
    private static let reconnectRetryCeil: TimeInterval = 8

    /// BoringTun `WireGuardError::NoCurrentSession` discriminant as surfaced through the FFI
    /// (`TunnResult::Err(e) → size = e as usize`). On `decapsulate` it means the peer is sending
    /// us data on a session our `Tunn` no longer holds — a wedged session that only a full
    /// transport+crypto rebuild can clear (`force_handshake` alone does not).
    private static let wgErrNoCurrentSession = 13
    /// BoringTun `WireGuardError::WrongIndex` (index 4): an inbound data packet references a
    /// session index our `Tunn` no longer holds — the same wedged/rotated-session symptom as
    /// `NoCurrentSession`, just a different discriminant. Treated identically for recovery.
    private static let wgErrWrongIndex = 4
    /// How long a run of wedged-session decap failures (with datagrams still arriving) must
    /// persist before we rebuild. Long enough to ignore the 1–2 packet blip during a normal
    /// rekey rotation, short enough that a genuinely wedged session recovers in seconds rather
    /// than waiting out the liveness watchdog (which misses this case once outbound goes quiet).
    private static let decapWedgeThreshold: TimeInterval = 5
    /// Active-probe tuning. When we've sent real data but decoded nothing back for
    /// `probeStallThreshold`, force a handshake and wait `probeTimeout` for the server to send
    /// *anything*; rebuild if it doesn't. `probeMinInterval` throttles repeat probes.
    ///
    /// Tightened (was 18/4/10) so a wedged session recovers in ~8–11s instead of the ~33s seen in
    /// the field. ProtonVPN RTT is sub-second, so 8s of one-way silence *while actively sending
    /// real data* (the `recentlySentRealData` gate) reliably means a wedge, not a slow path.
    private static let probeStallThreshold: TimeInterval = 8
    private static let probeTimeout: TimeInterval = 3
    private static let probeMinInterval: TimeInterval = 6

    /// Approximate transfer totals observed on the UDP transport (encrypted WireGuard packets).
    /// Updated on `ioQueue` only.
    private var udpRxBytesTotal: UInt64 = 0
    private var udpTxBytesTotal: UInt64 = 0
    /// Wall-clock time of the most recent successfully decrypted inbound packet.
    /// Updated on `ioQueue` only.
    private var lastInboundAt: Date?
    /// Start of the current unbroken run of `NoCurrentSession`/`WrongIndex` decap failures, or
    /// `nil` when the last decap succeeded. A sustained run while we're actively sending data
    /// means the peer is still reaching us (path alive) but our session is wedged. `ioQueue` only.
    private var decapWedgeStreakStart: Date?

    /// Wall-clock time we last encapsulated **real** app/relay data to the network — NOT a
    /// keepalive, handshake, or tick output. Both recovery paths gate on this so a tunnel that is
    /// only emitting keepalives (idle, or a destination-filtered tunnel with no active flows)
    /// legitimately receives nothing back and is never torn down for it. Without this gate the
    /// liveness watchdog rebuilds an idle filtered tunnel every stall-threshold forever. `ioQueue`.
    private var lastDataOutboundAt: Date?

    /// An in-flight active liveness probe: we forced a handshake and are waiting to see whether the
    /// server sends *anything* back. `baselineRxBytes` is `udpRxBytesTotal` at probe time; if it
    /// rises the path is alive. `ioQueue` only.
    private struct LivenessProbe { let sentAt: Date; let baselineRxBytes: UInt64 }
    private var activeProbe: LivenessProbe?
    /// Throttles probes so a wedged session can't trigger a forced-handshake storm. `ioQueue` only.
    private var lastProbeAt: Date?

    /// Scratch buffer reused on `ioQueue` only (BoringTun needs ~64 KiB for reads).
    private var scratch = [UInt8](repeating: 0, count: 65536)

    /// AllowedIPs parsed into prefix ranges for outbound packet filtering (set on ioQueue via start).
    /// Nil means pass all (full-tunnel: 0.0.0.0/0 is in AllowedIPs so no filtering needed).
    private var allowedV4Ranges: [(UInt32, UInt32)]? = nil   // (network, mask) in host byte order
    private var allowedV6Ranges: [([UInt8], [UInt8])]? = nil // (network, mask) as 16-byte arrays
    private var destinationSplitFilterActive = false
    private var droppedOutboundCount: UInt64 = 0
    private var acceptedOutboundCount: UInt64 = 0

    private var diagRelayPollLogCount: UInt64 = 0
    private var diagTunWriteLogCount: UInt64 = 0
    private var diagInboundDatagramLogCount: UInt64 = 0

    private var relayBridge: SmoltcpRelayBridge?

    /// Queue used for BoringTun and smoltcp relay I/O (XPC server must dispatch here).
    var relayPacketQueue: DispatchQueue { ioQueue }

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func attachRelayBridge(_ bridge: SmoltcpRelayBridge) {
        ioQueue.sync {
            self.relayBridge = bridge
        }
    }

    deinit {
        if let tunnel {
            tunnelbahn_wg_tunnel_free(tunnel)
        }
    }

    func start(
        with profile: WireGuardProfile,
        secrets: TunnelSecrets? = nil,
        appTunnelIncludedRoutes: [String]? = nil,
        appTunnelExcludedRoutes: [String]? = nil,
        effectiveEndpointOverride: String? = nil
    ) async throws {
        guard let provider else { throw BoringTunAdapterError.missingProvider }
        guard let peer = profile.peers.first else { throw BoringTunAdapterError.noPeer }

        logInputProfile(profile)

        let privateKeyString: String
        if let secrets {
            privateKeyString = secrets.privateKey
        } else {
            privateKeyString = try KeychainService.shared.read(account: profile.interface.privateKeyRef)
        }
        let presharedKeyString: String?
        if let ref = peer.presharedKeyRef {
            do {
                if let secrets, let inline = secrets.presharedKeys[peer.id.uuidString] {
                    presharedKeyString = inline
                } else {
                    presharedKeyString = try KeychainService.shared.read(account: ref)
                }
            } catch {
                throw BoringTunAdapterError.presharedKeyUnreadable(error.localizedDescription)
            }
        } else {
            presharedKeyString = nil
        }

        let keepalive: UInt16 = UInt16(clamping: peer.persistentKeepalive ?? 0)

        // Captured so the crypto object can be rebuilt in-process during deep recovery (the
        // strings are already resident in this process for the tunnel object's own lifetime).
        let publicKey = peer.publicKey
        let makeTunnel: () -> UnsafeMutableRawPointer? = {
            privateKeyString.withCString { priv in
                publicKey.withCString { pub in
                    if let psk = presharedKeyString {
                        return psk.withCString { pskC in
                            tunnelbahn_wg_tunnel_new(priv, pub, pskC, keepalive, 0)
                        }
                    }
                    return tunnelbahn_wg_tunnel_new(priv, pub, nil, keepalive, 0)
                }
            }
        }

        guard let tunnelPtr = makeTunnel() else { throw BoringTunAdapterError.tunnelInitFailed }
        self.tunnel = tunnelPtr
        self.tunnelFactory = makeTunnel

        if let effectiveEndpointOverride {
            Self.log.notice("[APPSPLIT_WGTCP] endpoint override active local-relay=\(effectiveEndpointOverride) (peer.endpoint=\(peer.endpoint) is carried by the wrapper)")
        }
        let endpointString = Self.endpointToken(from: effectiveEndpointOverride ?? peer.endpoint)
        let (wgHost, wgPort) = try Self.splitWireGuardHostPort(endpointString)
        let remoteEndpoint = NWHostEndpoint(hostname: wgHost, port: String(wgPort))

        let networkSettings = Self.buildNetworkSettings(
            profile: profile,
            tunnelRemoteHost: endpointString,
            appTunnelIncludedRoutes: appTunnelIncludedRoutes,
            appTunnelExcludedRoutes: appTunnelExcludedRoutes
        )
        try await provider.setTunnelNetworkSettings(networkSettings)

        self.remoteEndpoint = remoteEndpoint
        self.persistentKeepaliveSeconds = keepalive

        isRunning = true
        tunnelIOStarted = false
        udpRxBytesTotal = 0
        udpTxBytesTotal = 0
        lastInboundAt = nil
        lastOutboundAt = nil
        if let routes = appTunnelIncludedRoutes, !routes.isEmpty {
            allowedV4Ranges = Self.parseV4Ranges(routes)
            allowedV6Ranges = Self.parseV6Ranges(routes)
            destinationSplitFilterActive = true
            droppedOutboundCount = 0
            acceptedOutboundCount = 0
            Self.log.notice(
                "destination app-tunnel outbound filter v4=\(self.allowedV4Ranges?.count ?? 0) v6=\(self.allowedV6Ranges?.count ?? 0) routes=\(routes.count)"
            )
        } else {
            destinationSplitFilterActive = false
            let allAllowedIPs = profile.peers.flatMap { $0.allowedIPs }
            let hasV4Default = allAllowedIPs.contains("0.0.0.0/0")
            let hasV6Default = allAllowedIPs.contains("::/0")
            allowedV4Ranges = hasV4Default ? nil : Self.parseV4Ranges(allAllowedIPs)
            allowedV6Ranges = hasV6Default ? nil : Self.parseV6Ranges(allAllowedIPs)
        }

        ioQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.establishUDPSession(reason: "initial")
            self.startWatchdog()
        }

        Self.log.notice("BoringTun backend started (packetFlow + NWUDPSession)")
    }

    func stop() async {
        // Tear the transport down on `ioQueue` so the BoringTun pointer is freed *behind* any
        // tick / packetFlow-read / UDP-read block already in flight there. The old code freed it
        // on the caller thread (the NE stop context): a queued IO block could pass its
        // `isRunning`/`tunnel` guard, capture the raw pointer into a local, then call the FFI on
        // memory this method had just freed — a use-after-free. Publishing `isRunning = false`
        // first makes any block that hasn't started yet bail; `ioQueue.sync` then drains the block
        // that *is* running before we free, and serializes the free itself onto the same queue.
        isRunning = false
        ioQueue.sync {
            tunnelIOStarted = false
            watchdogTimer?.cancel()
            watchdogTimer = nil
            reconnectRetryTimer?.cancel()
            reconnectRetryTimer = nil
            udpStateObservation?.invalidate()
            udpStateObservation = nil
            udpBetterPathObservation?.invalidate()
            udpBetterPathObservation = nil
            udpViableObservation?.invalidate()
            udpViableObservation = nil
            tickTimer?.cancel()
            tickTimer = nil
            udpSession?.cancel()
            udpSession = nil

            if let tunnel {
                tunnelbahn_wg_tunnel_free(tunnel)
                self.tunnel = nil
            }
        }

        Self.log.notice("BoringTun tunnel stopped")
    }

    func runtimeConfiguration() async -> String? {
        let snapshot = await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: (running: false, tunnel: false, state: NWUDPSessionState.cancelled, rx: UInt64(0), tx: UInt64(0), lastHandshake: Optional<Date>.none))
                    return
                }
                continuation.resume(
                    returning: (
                        running: self.isRunning,
                        tunnel: self.tunnel != nil,
                        state: self.udpSession?.state ?? .cancelled,
                        rx: self.udpRxBytesTotal,
                        tx: self.udpTxBytesTotal,
                        lastHandshake: self.lastInboundAt
                    )
                )
            }
        }

        let lastInboundUnix = snapshot.lastHandshake.map { UInt64($0.timeIntervalSince1970 * 1000) } ?? 0
        return """
        backend=BoringTun (tunnelbahn_wg FFI)
        running=\(snapshot.running)
        tunnel=\(snapshot.tunnel)
        udp=\(snapshot.state)
        rx_bytes=\(snapshot.rx)
        tx_bytes=\(snapshot.tx)
        last_inbound_unix=\(lastInboundUnix)
        """
    }

    // MARK: - Transport lifecycle & recovery (ioQueue only)

    /// (Re)create the encrypted-transport `NWUDPSession` and re-arm its observers.
    ///
    /// Must be called on `ioQueue`. Safe to call repeatedly: the previous session and its
    /// observers are torn down first. macOS does not always surface a dead transport via
    /// `state`/`isViable` (an idle NAT mapping can die while the session still reports `.ready`),
    /// so both the path observers below and the liveness watchdog funnel through here. Rebuilding
    /// the transport plus a forced handshake revives even an expired BoringTun session — see
    /// `tunnelbahn_wg_force_handshake` (`force_resend=true` clears the expired state).
    private func establishUDPSession(reason: String) {
        guard isRunning, let provider, let remoteEndpoint else { return }

        // Throttle non-initial rebuilds so a flapping path can't trigger a tight rebuild loop.
        // Critically, *defer* the request instead of dropping it: a session that fails ~30 ms
        // after creation (network still down after a blip) lands inside this window, and a bare
        // `return` would lose the only retry — leaving recovery to the 65 s liveness watchdog.
        if reason != "initial",
           let last = sessionEstablishedAt,
           Date().timeIntervalSince(last) < Self.minReestablishInterval {
            armReconnectRetry()
            return
        }

        // Recreate the crypto object on every real recovery (anything but the first start or a
        // clean path migration, where the session is genuinely still valid). This pairs a fresh
        // encryptor with the fresh socket so the handshake completes the instant the socket is
        // `.ready` — no waiting on a stall timer to discover the old session was wedged.
        if reason != "initial", reason != "better-path", let makeTunnel = tunnelFactory {
            if let old = tunnel { tunnelbahn_wg_tunnel_free(old) }
            tunnel = makeTunnel()
            if tunnel == nil { Self.log.error("[APPSPLIT_DIAG] crypto recreate failed reason=\(reason)") }
        }

        udpStateObservation?.invalidate()
        udpBetterPathObservation?.invalidate()
        udpViableObservation?.invalidate()
        udpSession?.cancel()

        udpSessionGeneration &+= 1
        let generation = udpSessionGeneration
        sessionEstablishedAt = Date()
        lastInboundAt = nil
        decapWedgeStreakStart = nil
        lastDataOutboundAt = nil
        activeProbe = nil

        let session = provider.createUDPSession(to: remoteEndpoint, from: nil)
        udpSession = session
        Self.log.notice("[APPSPLIT_DIAG] udp_session establish gen=\(generation) reason=\(reason)")

        udpStateObservation = session.observe(\.state, options: [.initial, .new]) { [weak self] observed, _ in
            guard let self else { return }
            self.ioQueue.async {
                guard self.isRunning, generation == self.udpSessionGeneration else { return }
                Self.log.notice("[APPSPLIT_DIAG] udp_session_state=\(observed.state.rawValue) gen=\(generation)")
                switch observed.state {
                case .ready:
                    self.onUDPSessionReady()
                case .failed:
                    Self.log.error("UDP session entered failed state (gen=\(generation)) — rebuilding")
                    self.establishUDPSession(reason: "state-failed")
                default:
                    break
                }
            }
        }

        // Apple's intended signal for "the network moved" (Wi-Fi↔cellular, wake-from-sleep).
        udpBetterPathObservation = session.observe(\.hasBetterPath, options: [.new]) { [weak self] observed, _ in
            guard let self, observed.hasBetterPath else { return }
            self.ioQueue.async {
                guard self.isRunning, generation == self.udpSessionGeneration else { return }
                Self.log.notice("[APPSPLIT_DIAG] udp hasBetterPath gen=\(generation) — migrating")
                self.establishUDPSession(reason: "better-path")
            }
        }

        udpViableObservation = session.observe(\.isViable, options: [.new]) { [weak self] observed, _ in
            guard let self, !observed.isViable else { return }
            self.ioQueue.async {
                guard self.isRunning, generation == self.udpSessionGeneration else { return }
                Self.log.notice("[APPSPLIT_DIAG] udp not viable gen=\(generation) — rebuilding")
                self.establishUDPSession(reason: "not-viable")
            }
        }

        // Keep retrying until *this* session reaches `.ready`. Covers both an immediate
        // `.failed` (network still down) and a session that hangs in `.waiting`/`.preparing`
        // without ever signalling failure. Cancelled in `onUDPSessionReady()`.
        armReconnectRetry()
    }

    /// Arm (or re-arm) the single-shot reconnect retry on `ioQueue`. If the transport still
    /// isn't `.ready` when it fires, rebuild and lengthen the backoff. This is what turns a
    /// throttle-swallowed or silently-stuck rebuild into a *deferred* one, so a short network
    /// blip recovers in seconds instead of waiting out the liveness-watchdog stall threshold.
    private func armReconnectRetry() {
        reconnectRetryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + reconnectRetryDelay)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            // Already healthy — onUDPSessionReady() normally cancels us first; guard anyway.
            if self.udpSession?.state == .ready { return }
            self.reconnectRetryDelay = min(self.reconnectRetryDelay * 1.6, Self.reconnectRetryCeil)
            self.establishUDPSession(reason: "reconnect-retry")
        }
        timer.resume()
        reconnectRetryTimer = timer
    }

    /// Stop the reconnect-retry loop and reset the backoff. Called once a session is `.ready`.
    private func cancelReconnectRetry() {
        reconnectRetryTimer?.cancel()
        reconnectRetryTimer = nil
        reconnectRetryDelay = Self.reconnectRetryFloor
    }

    /// Called each time the current transport reaches `.ready`.
    private func onUDPSessionReady() {
        // Transport is live again — stop the reconnect-retry loop and reset its backoff.
        cancelReconnectRetry()
        // Re-arm the first-N diagnostic bursts so every (re)connection logs its own
        // udp_rx/wg_write/relay_poll — otherwise recovery is invisible once the initial
        // connect exhausts these counters, and we can't see traffic actually resume.
        diagInboundDatagramLogCount = 0
        diagTunWriteLogCount = 0
        diagRelayPollLogCount = 0
        // Tunnel-lifetime IO (packet-flow reads + crypto tick) starts exactly once.
        if !tunnelIOStarted {
            tunnelIOStarted = true
            startPacketFlowReads()
            startTickTimer()
        }
        // Per-session: re-arm the datagram read handler on the new session and kick a fresh
        // handshake so a rebuilt transport (or a revived expired tunnel) reconnects immediately.
        installDatagramReadHandler()
        startHandshakeIfNeeded()
        Self.log.notice("[APPSPLIT_DIAG] udp_ready — handshake + read handler armed (gen=\(self.udpSessionGeneration))")
    }

    // Liveness thresholds derived from the configured keepalive. With keepalive we always
    // transmit, so a healthy link always returns something well within the stall window.
    private var watchdogGrace: TimeInterval { 15 }
    private var watchdogTxWindow: TimeInterval { max(Double(persistentKeepaliveSeconds) * 2, 20) }
    /// Long-stall backstop when the active probe path doesn't conclude. Lowered (was
    /// `max(keepalive*2+15, 35)`) so a wedge that slips past the probe still rebuilds at ~20s
    /// instead of ~35s. The probe path (≈11s) is the primary trigger; this is the safety net.
    private var watchdogStallThreshold: TimeInterval { max(Double(persistentKeepaliveSeconds) * 2 + 5, 20) }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in
            self?.checkDataPlaneLiveness()
        }
        timer.resume()
        watchdogTimer = timer
    }

    /// Detects a silently-dead transport: we send real data but nothing comes back. macOS never
    /// reports this (no `.failed`, `isViable` stays true). Crucially this judges only **real data**
    /// outbound, not keepalives — a tunnel that's merely idle (or a destination-filtered tunnel
    /// with no active flows) keeps emitting keepalives yet legitimately receives nothing, and must
    /// never be rebuilt for it (that caused an endless every-~70s rebuild loop). When suspicious it
    /// first *actively probes* (forces a handshake) and rebuilds only if the server answers with
    /// nothing — faster and more certain than waiting out the full stall window.
    private func checkDataPlaneLiveness() {
        guard isRunning, tunnelIOStarted, let establishedAt = sessionEstablishedAt else { return }
        let now = Date()
        // Let the initial/rebuilt handshake complete before judging.
        guard now.timeIntervalSince(establishedAt) > watchdogGrace else { return }

        // Only judge while we're actively sending real data. Keepalives don't count — see
        // `lastDataOutboundAt`. If we're not, abandon any in-flight probe and leave the tunnel be.
        guard recentlySentRealData(now: now) else {
            activeProbe = nil
            return
        }

        let lastRx = lastInboundAt ?? establishedAt
        let stall = now.timeIntervalSince(lastRx)

        // Evaluate an in-flight probe first.
        if let probe = activeProbe {
            if udpRxBytesTotal > probe.baselineRxBytes {
                // Server sent us *something* back after our forced handshake → the path is alive.
                // The handshake response re-establishes the session; a still-wedged session is
                // caught by the decap-wedge detector, and the long-stall backstop below remains.
                activeProbe = nil
            } else if now.timeIntervalSince(probe.sentAt) >= Self.probeTimeout {
                Self.log.error("[APPSPLIT_DIAG] liveness probe unanswered \(Int(Self.probeTimeout))s — rebuilding transport + crypto")
                activeProbe = nil
                establishUDPSession(reason: "probe-timeout")
                return
            } else {
                return  // probe still pending
            }
        }

        // Long-stall backstop: rebuild regardless if inbound has been dead this long.
        if stall > watchdogStallThreshold {
            Self.log.error("[APPSPLIT_DIAG] data-plane stall \(Int(stall))s with no inbound — rebuilding transport + crypto")
            establishUDPSession(reason: "watchdog-stall")
            return
        }

        // Suspicious but not yet certain: actively probe before judging, throttled so a wedged
        // session can't trigger a forced-handshake storm.
        if stall > Self.probeStallThreshold,
           now.timeIntervalSince(lastProbeAt ?? .distantPast) > Self.probeMinInterval {
            Self.log.notice("[APPSPLIT_DIAG] no inbound \(Int(stall))s while active — probing tunnel (forced handshake)")
            lastProbeAt = now
            activeProbe = LivenessProbe(sentAt: now, baselineRxBytes: udpRxBytesTotal)
            startHandshakeIfNeeded()
        }
    }

    /// True when we encapsulated real app/relay data (not keepalives/handshakes) recently enough to
    /// expect a response. Gates both recovery paths so an idle / filtered-idle tunnel is left alone.
    private func recentlySentRealData(now: Date) -> Bool {
        guard let lastDataTx = lastDataOutboundAt else { return false }
        return now.timeIntervalSince(lastDataTx) < watchdogTxWindow
    }

    // MARK: - Crypto / IO (always on ioQueue)

    private func startHandshakeIfNeeded() {
        guard let tunnel else { return }
        let res = tunnelbahn_wg_force_handshake(tunnel, &scratch, UInt32(scratch.count))
        sendNetworkIfNeeded(res)
    }

    private func startTickTimer() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let tunnel = self.tunnel, self.isRunning else { return }
            let res = tunnelbahn_wg_tick(tunnel, &self.scratch, UInt32(self.scratch.count))
            self.sendNetworkIfNeeded(res)
            self.flushRelayOutbound()
        }
        timer.resume()
        tickTimer = timer
    }

    private func sendNetworkIfNeeded(_ res: TunnelbahnWgResult) {
        guard res.op == UInt32(TUNNELBAHN_WG_WRITE_TO_NETWORK) else { return }
        let len = Int(res.size)
        guard len > 0, len <= scratch.count else { return }
        writeUDP(Data(scratch.prefix(len)))
    }

    /// BoringTun: after `tunnelbahn_wg_read` returns `WRITE_TO_NETWORK`, send UDP and call `tunnelbahn_wg_read` with an empty datagram until not `WRITE_TO_NETWORK`.
    private func drainDecapsulateNetworkReplies(tunnel: UnsafeMutableRawPointer, first: inout TunnelbahnWgResult) {
        var res = first
        while res.op == UInt32(TUNNELBAHN_WG_WRITE_TO_NETWORK) {
            sendNetworkIfNeeded(res)
            // Rust's slice::from_raw_parts requires a non-null pointer even at len 0, and
            // Data().withUnsafeBytes yields a nil baseAddress — pass a dummy byte instead.
            var dummy: UInt8 = 0
            res = withUnsafePointer(to: &dummy) { base in
                tunnelbahn_wg_read(tunnel, base, 0, &scratch, UInt32(scratch.count))
            }
        }
        first = res
    }

    private func handleTunPacket(_ packet: Data, fromRelay: Bool = false) {
        guard let tunnel, isRunning else { return }
        guard !packet.isEmpty else { return }
        // Drop packets whose destination is outside AllowedIPs. With per-app VPN sourceApplication
        // routing, the kernel forces all matched-app traffic to utun regardless of the routing table,
        // so we must enforce AllowedIPs here rather than relying on kernel routes.
        // Relay-origin packets are exempt: the transparent proxy already made the authoritative
        // tunnel/direct decision for that flow (which legitimately includes SNI/domain-matched
        // destinations OUTSIDE the resolved CIDR ranges — the CDN/anycast case), so re-adjudicating
        // by destination here would black-hole those flows. The filter's scope is kernel
        // packetFlow reads only.
        if !fromRelay, !isAllowedOutbound(packet) {
            if destinationSplitFilterActive {
                droppedOutboundCount &+= 1
                if droppedOutboundCount == 1 || droppedOutboundCount % 100 == 0 {
                    Self.log.notice(
                        "destination split: dropped outbound packet (count=\(self.droppedOutboundCount))"
                    )
                }
            }
            return
        }
        if destinationSplitFilterActive {
            acceptedOutboundCount &+= 1
            if acceptedOutboundCount == 1 || acceptedOutboundCount % 50 == 0 {
                Self.log.notice(
                    "destination split: accepted outbound packet (count=\(self.acceptedOutboundCount))"
                )
            }
        }
        let res = packet.withUnsafeBytes { buf -> TunnelbahnWgResult in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else {
                return TunnelbahnWgResult(op: UInt32(TUNNELBAHN_WG_DONE), size: 0)
            }
            return tunnelbahn_wg_write(tunnel, base, UInt32(packet.count), &scratch, UInt32(scratch.count))
        }
        if diagTunWriteLogCount < 20 {
            diagTunWriteLogCount &+= 1
            let dst = Self.dstIPv4String(packet) ?? "?"
            Self.log.notice("[APPSPLIT_DIAG] wg_write n=\(self.diagTunWriteLogCount) dst=\(dst) op=\(res.op) size=\(res.size)")
        }
        // Real app/relay data left for the network (encrypted payload, or a handshake init kicked
        // because the app wants to talk and there's no session yet). Either way we're *actively
        // using* the tunnel and should expect a response — this is what the liveness watchdog and
        // decap-wedge detector gate on, distinguishing real use from idle keepalive traffic.
        if res.op == UInt32(TUNNELBAHN_WG_WRITE_TO_NETWORK) {
            lastDataOutboundAt = Date()
        }
        sendNetworkIfNeeded(res)
    }

    private static func dstIPv4String(_ packet: Data) -> String? {
        guard packet.count >= 20, (packet[0] >> 4) & 0xF == 4 else { return nil }
        return "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
    }

    /// smoltcp → encrypt → WireGuard (bypasses packetFlow.readPackets).
    private func flushRelayOutbound() {
        guard let relay = relayBridge else { return }
        let packets = relay.pollOutboundPackets()
        if !packets.isEmpty, diagRelayPollLogCount < 20 {
            diagRelayPollLogCount &+= 1
            Self.log.notice("[APPSPLIT_DIAG] relay_poll n=\(self.diagRelayPollLogCount) packets=\(packets.count)")
        }
        for packet in packets {
            handleTunPacket(packet, fromRelay: true)
        }
    }

    /// Returns true if the packet's destination IP is covered by AllowedIPs (or AllowedIPs is full-tunnel).
    private func isAllowedOutbound(_ packet: Data) -> Bool {
        guard packet.count >= 1 else { return false }
        let version = (packet[0] >> 4) & 0xF
        if version == 4 {
            guard let ranges = allowedV4Ranges else { return true } // nil = full-tunnel
            guard packet.count >= 20 else { return false }
            let dst = packet.withUnsafeBytes { buf -> UInt32 in
                let b = buf.bindMemory(to: UInt8.self)
                return (UInt32(b[16]) << 24) | (UInt32(b[17]) << 16) | (UInt32(b[18]) << 8) | UInt32(b[19])
            }
            return ranges.contains { (net, mask) in (dst & mask) == net }
        } else if version == 6 {
            guard let ranges = allowedV6Ranges else { return true }
            guard packet.count >= 40 else { return false }
            let dst = packet.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)[24..<40]) }
            return ranges.contains { (net, mask) in
                for i in 0..<16 { if (dst[i] & mask[i]) != net[i] { return false } }
                return true
            }
        }
        return false
    }

    private static func parseV4Ranges(_ allowedIPs: [String]) -> [(UInt32, UInt32)] {
        allowedIPs.compactMap { cidr -> (UInt32, UInt32)? in
            guard cidr.contains(".") else { return nil }
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { return nil }
            var addr = in_addr()
            guard inet_pton(AF_INET, String(parts[0]), &addr) == 1 else { return nil }
            let net = UInt32(bigEndian: addr.s_addr)
            let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0)) << (32 - prefix)
            return (net & mask, mask)
        }
    }

    private static func parseV6Ranges(_ allowedIPs: [String]) -> [([UInt8], [UInt8])] {
        allowedIPs.compactMap { cidr -> ([UInt8], [UInt8])? in
            guard cidr.contains(":") else { return nil }
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix <= 128 else { return nil }
            var addr = in6_addr()
            guard inet_pton(AF_INET6, String(parts[0]), &addr) == 1 else { return nil }
            let netBytes: [UInt8] = withUnsafeBytes(of: addr) { Array($0) }
            var mask = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 {
                let bits = min(max(prefix - i * 8, 0), 8)
                // `~(0xFF >> bits)` is a signed Int and is negative for every bits in 1...8
                // (e.g. bits==8 → ~0 == -1); the non-truncating UInt8.init would TRAP on it.
                // truncatingIfNeeded takes the low 8 bits, yielding the intended mask byte
                // (bits=1 → 0x80, … bits=8 → 0xFF).
                mask[i] = bits == 0 ? 0 : UInt8(truncatingIfNeeded: ~(0xFF >> bits))
            }
            let net = zip(netBytes, mask).map { $0 & $1 }
            return (net, mask)
        }
    }

    private func handleIncomingDatagram(_ datagram: Data) {
        guard let tunnel, isRunning else { return }
        guard !datagram.isEmpty else { return }
        var res = datagram.withUnsafeBytes { buf -> TunnelbahnWgResult in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else {
                return TunnelbahnWgResult(op: UInt32(TUNNELBAHN_WG_DONE), size: 0)
            }
            return tunnelbahn_wg_read(tunnel, base, UInt32(datagram.count), &scratch, UInt32(scratch.count))
        }
        drainDecapsulateNetworkReplies(tunnel: tunnel, first: &res)

        switch res.op {
        case UInt32(TUNNELBAHN_WG_WRITE_TO_TUNNEL_IPV4):
            lastInboundAt = Date()
            decapWedgeStreakStart = nil
            let ipPacket = Data(scratch.prefix(Int(res.size)))
            if let relay = relayBridge, relay.shouldInterceptInbound(packet: ipPacket) {
                _ = relay.feedInbound(packet: ipPacket)
            } else {
                deliverToPacketFlow(ipPacket: ipPacket, protocolFamily: AF_INET)
            }
            flushRelayOutbound()
        case UInt32(TUNNELBAHN_WG_WRITE_TO_TUNNEL_IPV6):
            lastInboundAt = Date()
            decapWedgeStreakStart = nil
            deliverToPacketFlow(ipPacket: Data(scratch.prefix(Int(res.size))), protocolFamily: AF_INET6)
            flushRelayOutbound()
        case UInt32(TUNNELBAHN_WG_DONE):
            // A clean decap that yielded nothing to forward (e.g. a decrypted keepalive, or a
            // handshake we just processed) still proves the session is live — clear the streak.
            decapWedgeStreakStart = nil
        case UInt32(TUNNELBAHN_WG_ERROR):
            handleDecapError(code: Int(res.size))
        default:
            break
        }
    }

    /// Detects and recovers a wedged WireGuard session. `NoCurrentSession`/`WrongIndex` on
    /// `decapsulate` means the peer is still delivering data on a session we no longer hold/match;
    /// once BoringTun is in this state it returns the error indefinitely, and a download-heavy flow
    /// can leave our outbound silent — so the tx/rx liveness watchdog never fires. We instead treat
    /// a *sustained run* of these errors (packets are arriving, so the path is alive) as the trigger
    /// to rebuild the transport and recreate the crypto object. Gated on `recentlySentRealData` so
    /// stray stale-session packets arriving at an idle filtered tunnel can't trigger a rebuild.
    /// Must be called on `ioQueue`.
    private func handleDecapError(code: Int) {
        Self.log.error("tunnelbahn_wg_read error code=\(code)")
        guard code == Self.wgErrNoCurrentSession || code == Self.wgErrWrongIndex else { return }

        let now = Date()
        let streakStart = decapWedgeStreakStart ?? now
        decapWedgeStreakStart = streakStart

        // Idle / filtered-idle tunnels can receive stray stale-session packets; ignore them unless
        // we're actively using the tunnel and these errors are what we're getting back.
        guard recentlySentRealData(now: now) else { return }

        // Require the streak to persist (ignores a brief rekey-rotation blip) and give any
        // freshly (re)built session time to complete its handshake before judging. A rebuild
        // resets `sessionEstablishedAt`, so the grace check also rate-limits re-triggers and
        // prevents a rebuild loop while the new handshake is still settling.
        guard now.timeIntervalSince(streakStart) >= Self.decapWedgeThreshold else { return }
        guard let establishedAt = sessionEstablishedAt,
              now.timeIntervalSince(establishedAt) >= watchdogGrace else { return }

        Self.log.error(
            "[APPSPLIT_DIAG] decap wedged \(Int(now.timeIntervalSince(streakStart)))s (code=\(code)) — rebuilding transport + crypto"
        )
        decapWedgeStreakStart = nil
        establishUDPSession(reason: "decap-wedged")
    }

    private func deliverToPacketFlow(ipPacket: Data, protocolFamily: Int32) {
        guard let provider, isRunning else { return }
        provider.packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: protocolFamily)])
    }

    private func writeUDP(_ data: Data) {
        guard let session = udpSession else { return }
        udpTxBytesTotal &+= UInt64(data.count)
        lastOutboundAt = Date()
        session.writeDatagram(data) { error in
            if let error {
                Self.log.error("UDP write failed: \(error.localizedDescription)")
            }
        }
    }

    /// `NWUDPSession` schedules reads after a single `setReadHandler` call (macOS / NetworkExtension API).
    private func installDatagramReadHandler() {
        guard let session = udpSession, isRunning else { return }
        session.setReadHandler({ [weak self] datagrams, error in
            guard let self else { return }
            self.ioQueue.async {
                guard self.isRunning else { return }
                if let error {
                    Self.log.error("UDP read error: \(error.localizedDescription)")
                    return
                }
                guard let datagrams else { return }
                if self.diagInboundDatagramLogCount < 20 {
                    self.diagInboundDatagramLogCount &+= 1
                    let totalBytes = datagrams.reduce(0) { $0 + ($1 as Data).count }
                    Self.log.notice("[APPSPLIT_DIAG] udp_rx n=\(self.diagInboundDatagramLogCount) datagrams=\(datagrams.count) bytes=\(totalBytes)")
                }
                for datagram in datagrams {
                    self.udpRxBytesTotal &+= UInt64((datagram as Data).count)
                    self.handleIncomingDatagram(datagram as Data)
                }
            }
        }, maxDatagrams: 32)
    }

    private func startPacketFlowReads() {
        schedulePacketFlowRead()
    }

    private func schedulePacketFlowRead() {
        guard isRunning, let provider else { return }
        provider.packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.ioQueue.async {
                guard self.isRunning else { return }
                for packet in packets {
                    self.handleTunPacket(packet)
                }
                self.flushRelayOutbound()
                self.schedulePacketFlowRead()
            }
        }
    }

    // MARK: - Network settings

    private static func buildNetworkSettings(
        profile: WireGuardProfile,
        tunnelRemoteHost: String,
        appTunnelIncludedRoutes: [String]? = nil,
        appTunnelExcludedRoutes: [String]? = nil
    ) -> NEPacketTunnelNetworkSettings {
        let remote = tunnelRemoteHost.split(separator: ":").first.map(String.init) ?? "0.0.0.0"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote)

        let allAllowedIPs = profile.peers.flatMap { $0.allowedIPs }
        let usingDestinationAppTunnel = appTunnelIncludedRoutes?.isEmpty == false
        // Full-tunnel exclude shape: default route stays; the listed CIDRs bypass utun.
        // The host guarantees the two overrides are mutually exclusive; if both ever
        // arrive, include wins (fail toward over-tunneling, never toward a leak).
        var usingDestinationExclude = appTunnelExcludedRoutes?.isEmpty == false
        if usingDestinationAppTunnel && usingDestinationExclude {
            log.error("both included and excluded route overrides present; ignoring excluded")
            usingDestinationExclude = false
        }
        let excludeCIDRs = usingDestinationExclude ? (appTunnelExcludedRoutes ?? []) : []
        let routeCIDRs = usingDestinationAppTunnel ? appTunnelIncludedRoutes! : allAllowedIPs
        let hasDefaultRoute = !usingDestinationAppTunnel
            && (allAllowedIPs.contains("0.0.0.0/0") || allAllowedIPs.contains("::/0"))

        // Gateway addresses are the tunnel's own interface addresses (needed for route installation).
        let v4Gateway = profile.interface.addresses.first(where: { $0.contains(".") && $0.contains("/") })
            .flatMap { $0.split(separator: "/").first }.map(String.init)
        let v6Gateway = profile.interface.addresses.first(where: { $0.contains(":") && $0.contains("/") })
            .flatMap { $0.split(separator: "/").first }.map(String.init)

        let v4AllowedRoutes: [NEIPv4Route] = routeCIDRs.compactMap { cidr in
            guard cidr.contains(".") else { return nil }
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
            let route = NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: ipv4SubnetMask(prefix: prefix))
            route.gatewayAddress = v4Gateway
            return route
        }
        let v6AllowedRoutes: [NEIPv6Route] = routeCIDRs.compactMap { cidr in
            guard cidr.contains(":") else { return nil }
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
            let route = NEIPv6Route(destinationAddress: String(parts[0]), networkPrefixLength: NSNumber(value: min(max(prefix, 0), 128)))
            route.gatewayAddress = v6Gateway
            return route
        }

        // No gatewayAddress on excluded routes: excluded destinations exit via the
        // physical interface, not the tunnel.
        let v4ExcludedRoutes: [NEIPv4Route] = excludeCIDRs.compactMap { cidr in
            guard cidr.contains(".") else { return nil }
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
            return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: ipv4SubnetMask(prefix: prefix))
        }
        let v6ExcludedRoutes: [NEIPv6Route] = excludeCIDRs.compactMap { cidr in
            guard cidr.contains(":") else { return nil }
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
            return NEIPv6Route(destinationAddress: String(parts[0]), networkPrefixLength: NSNumber(value: min(max(prefix, 0), 128)))
        }

        let v4CIDRs = profile.interface.addresses.filter { $0.contains(".") && $0.contains("/") }
        if !v4CIDRs.isEmpty {
            let addrs = v4CIDRs.map { String($0.split(separator: "/").first!) }
            let masks = v4CIDRs.map { cidr -> String in
                let parts = cidr.split(separator: "/")
                guard parts.count == 2, let p = Int(parts[1]) else { return "255.255.255.255" }
                return ipv4SubnetMask(prefix: p)
            }
            let ipv4 = NEIPv4Settings(addresses: addrs, subnetMasks: masks)
            ipv4.includedRoutes = usingDestinationAppTunnel
                ? v4AllowedRoutes
                : (v4AllowedRoutes.isEmpty ? (hasDefaultRoute ? [NEIPv4Route.default()] : []) : v4AllowedRoutes)
            if usingDestinationAppTunnel {
                ipv4.excludedRoutes = [NEIPv4Route.default()]
            } else if !v4ExcludedRoutes.isEmpty {
                ipv4.excludedRoutes = v4ExcludedRoutes
            }
            settings.ipv4Settings = ipv4
        }

        let v6CIDRs = profile.interface.addresses.filter { $0.contains(":") && $0.contains("/") }
        if !v6CIDRs.isEmpty {
            let addrs = v6CIDRs.map { String($0.split(separator: "/").first!) }
            let prefixes = v6CIDRs.map { cidr -> NSNumber in
                let parts = cidr.split(separator: "/")
                guard parts.count == 2, let p = Int(parts[1]) else { return 64 }
                return NSNumber(value: min(max(p, 0), 128))
            }
            let ipv6 = NEIPv6Settings(addresses: addrs, networkPrefixLengths: prefixes)
            ipv6.includedRoutes = usingDestinationAppTunnel ? v6AllowedRoutes : (v6AllowedRoutes.isEmpty ? [] : v6AllowedRoutes)
            if usingDestinationAppTunnel {
                ipv6.excludedRoutes = [NEIPv6Route.default()]
            } else if !v6ExcludedRoutes.isEmpty {
                ipv6.excludedRoutes = v6ExcludedRoutes
            }
            settings.ipv6Settings = ipv6
        }

        if !profile.interface.dnsServers.isEmpty && hasDefaultRoute
            && !usingDestinationAppTunnel && !usingDestinationExclude {
            // Only apply tunnel DNS when a default route is present. With split-tunnel
            // AllowedIPs, setting dnsSettings with servers outside the AllowedIPs CIDRs
            // causes macOS to install a default route on utun to make those servers reachable,
            // overriding AllowedIPs and routing all traffic through the tunnel.
            // The exclude filter shape also skips dnsSettings: DNS rides the proxy's port-53 redirect, same as the include shape.
            let dns = NEDNSSettings(servers: profile.interface.dnsServers)
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }

        if let mtu = profile.interface.mtu {
            settings.mtu = NSNumber(value: mtu)
        } else {
            settings.tunnelOverheadBytes = 80
        }

        return settings
    }

    private static func ipv4SubnetMask(prefix: Int) -> String {
        let clamped = min(max(prefix, 0), 32)
        if clamped == 0 { return "0.0.0.0" }
        let mask = (~UInt32(0)) << UInt32(32 - clamped)
        return "\((mask >> 24) & 255).\((mask >> 16) & 255).\((mask >> 8) & 255).\(mask & 255)"
    }

    // MARK: - Endpoint parsing

    private static func endpointToken(from endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0 == "#" })
            .first
            .map(String.init) ?? endpoint
    }

    /// Parses WireGuard `host:port`, `[ipv6]:port`, or host-only (default UDP **51820**) for `NWHostEndpoint`.
    private static func splitWireGuardHostPort(_ string: String) throws -> (host: String, port: UInt16) {
        if string.hasPrefix("[") {
            guard let closing = string.firstIndex(of: "]") else {
                throw BoringTunAdapterError.invalidEndpoint(string)
            }
            let host = String(string[string.index(after: string.startIndex) ..< closing])
            let after = string.index(after: closing)
            guard after < string.endIndex, string[after] == ":" else {
                throw BoringTunAdapterError.invalidEndpoint(string)
            }
            let portStr = string[string.index(after: after)...]
            guard let port = UInt16(portStr), !host.isEmpty else { throw BoringTunAdapterError.invalidEndpoint(string) }
            return (host, port)
        }
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, let port = UInt16(parts.last!) {
            let host = parts.dropLast().joined(separator: ":")
            guard !host.isEmpty else { throw BoringTunAdapterError.invalidEndpoint(string) }
            return (host, port)
        }
        guard !string.isEmpty else { throw BoringTunAdapterError.invalidEndpoint(string) }
        return (string, 51820)
    }

    private func logInputProfile(_ profile: WireGuardProfile) {
        let addresses = profile.interface.addresses.joined(separator: ", ")
        let dns = profile.interface.dnsServers.joined(separator: ", ")
        let mtu = profile.interface.mtu.map(String.init) ?? "nil"
        Self.log.notice(
            "Input profile name=\(profile.name) addresses=[\(addresses)] dns=[\(dns)] mtu=\(mtu) peers=\(profile.peers.count)"
        )
        for (index, peer) in profile.peers.enumerated() {
            let allowedJoined = peer.allowedIPs.joined(separator: ", ")
            let keepaliveStr = peer.persistentKeepalive.map(String.init) ?? "nil"
            Self.log.notice(
                "Input peer[\(index)] endpoint=\(peer.endpoint) allowedIPs=\(allowedJoined) keepalive=\(keepaliveStr)"
            )
        }
    }
}

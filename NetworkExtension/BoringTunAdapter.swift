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
    private static let log = Logger(subsystem: "com.tunnelbahn.mac.networkextension", category: "BoringTunAdapter")

    private weak var provider: NEPacketTunnelProvider?
    private let packetQueue = DispatchQueue(label: "com.tunnelbahn.mac.boringtun")

    private var tunnel: UnsafeMutableRawPointer?
    private var udpSession: NWUDPSession?
    private var udpStateObservation: NSKeyValueObservation?
    private var tickTimer: DispatchSourceTimer?
    private var isRunning = false
    /// Ensures UDP read handler / packet flow / tick are only started once per session.
    private var tunnelIOStarted = false

    /// Approximate transfer totals observed on the UDP transport (encrypted WireGuard packets).
    /// Updated on `packetQueue` only.
    private var udpRxBytesTotal: UInt64 = 0
    private var udpTxBytesTotal: UInt64 = 0

    /// Scratch buffer reused on `packetQueue` only (BoringTun needs ~64 KiB for reads).
    private var scratch = [UInt8](repeating: 0, count: 65536)

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    deinit {
        if let tunnel {
            tunnelbahn_wg_tunnel_free(tunnel)
        }
    }

    func start(with profile: WireGuardProfile) async throws {
        guard let provider else { throw BoringTunAdapterError.missingProvider }
        guard let peer = profile.peers.first else { throw BoringTunAdapterError.noPeer }

        logInputProfile(profile)

        let privateKeyString = try KeychainService.shared.read(account: profile.interface.privateKeyRef)
        let presharedKeyString: String?
        if let ref = peer.presharedKeyRef {
            do {
                presharedKeyString = try KeychainService.shared.read(account: ref)
            } catch {
                throw BoringTunAdapterError.presharedKeyUnreadable(error.localizedDescription)
            }
        } else {
            presharedKeyString = nil
        }

        let keepalive: UInt16 = UInt16(clamping: peer.persistentKeepalive ?? 0)

        let tunnelPtr: UnsafeMutableRawPointer? = privateKeyString.withCString { priv in
            peer.publicKey.withCString { pub in
                if let psk = presharedKeyString {
                    return psk.withCString { pskC in
                        tunnelbahn_wg_tunnel_new(priv, pub, pskC, keepalive, 0)
                    }
                }
                return tunnelbahn_wg_tunnel_new(priv, pub, nil, keepalive, 0)
            }
        }

        guard let tunnelPtr else { throw BoringTunAdapterError.tunnelInitFailed }
        self.tunnel = tunnelPtr

        let endpointString = Self.endpointToken(from: peer.endpoint)
        let (wgHost, wgPort) = try Self.splitWireGuardHostPort(endpointString)
        let remoteEndpoint = NWHostEndpoint(hostname: wgHost, port: String(wgPort))

        let networkSettings = Self.buildNetworkSettings(profile: profile, tunnelRemoteHost: endpointString)
        try await provider.setTunnelNetworkSettings(networkSettings)

        // Swift label is `to:from:` for both `NEProvider` and `NEPacketTunnelProvider`; the tunnel subclass binds through the tunnel.
        let session = provider.createUDPSession(to: remoteEndpoint, from: nil)
        self.udpSession = session

        isRunning = true
        tunnelIOStarted = false
        udpRxBytesTotal = 0
        udpTxBytesTotal = 0

        udpStateObservation = session.observe(\NWUDPSession.state, options: [.initial, .new]) { [weak self] observed, _ in
            guard let self, self.isRunning else { return }
            switch observed.state {
            case .ready:
                self.packetQueue.async {
                    guard !self.tunnelIOStarted else { return }
                    self.tunnelIOStarted = true
                    self.startHandshakeIfNeeded()
                    self.installDatagramReadHandler()
                    self.startPacketFlowReads()
                    self.startTickTimer()
                }
            case .failed:
                Self.log.error("UDP session entered failed state")
            default:
                break
            }
        }

        Self.log.notice("BoringTun backend started (packetFlow + NWUDPSession)")
    }

    func stop() async {
        isRunning = false
        tunnelIOStarted = false
        udpStateObservation?.invalidate()
        udpStateObservation = nil
        tickTimer?.cancel()
        tickTimer = nil
        udpSession?.cancel()
        udpSession = nil

        if let tunnel {
            tunnelbahn_wg_tunnel_free(tunnel)
            self.tunnel = nil
        }

        Self.log.notice("BoringTun tunnel stopped")
    }

    func runtimeConfiguration() async -> String? {
        let snapshot = await withCheckedContinuation { continuation in
            packetQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: (running: false, tunnel: false, state: NWUDPSessionState.cancelled, rx: UInt64(0), tx: UInt64(0)))
                    return
                }
                continuation.resume(
                    returning: (
                        running: self.isRunning,
                        tunnel: self.tunnel != nil,
                        state: self.udpSession?.state ?? .cancelled,
                        rx: self.udpRxBytesTotal,
                        tx: self.udpTxBytesTotal
                    )
                )
            }
        }

        return """
        backend=BoringTun (tunnelbahn_wg FFI)
        running=\(snapshot.running)
        tunnel=\(snapshot.tunnel)
        udp=\(snapshot.state)
        rx_bytes=\(snapshot.rx)
        tx_bytes=\(snapshot.tx)
        """
    }

    // MARK: - Crypto / IO (always on packetQueue)

    private func startHandshakeIfNeeded() {
        guard let tunnel else { return }
        let res = tunnelbahn_wg_force_handshake(tunnel, &scratch, UInt32(scratch.count))
        sendNetworkIfNeeded(res)
    }

    private func startTickTimer() {
        let timer = DispatchSource.makeTimerSource(queue: packetQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let tunnel = self.tunnel, self.isRunning else { return }
            let res = tunnelbahn_wg_tick(tunnel, &self.scratch, UInt32(self.scratch.count))
            self.sendNetworkIfNeeded(res)
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
            res = Data().withUnsafeBytes { (empty: UnsafeRawBufferPointer) -> TunnelbahnWgResult in
                let base = empty.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return tunnelbahn_wg_read(tunnel, base, 0, &scratch, UInt32(scratch.count))
            }
        }
        first = res
    }

    private func handleTunPacket(_ packet: Data) {
        guard let tunnel, isRunning else { return }
        guard !packet.isEmpty else { return }
        let res = packet.withUnsafeBytes { buf -> TunnelbahnWgResult in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else {
                return TunnelbahnWgResult(op: UInt32(TUNNELBAHN_WG_DONE), size: 0)
            }
            return tunnelbahn_wg_write(tunnel, base, UInt32(packet.count), &scratch, UInt32(scratch.count))
        }
        sendNetworkIfNeeded(res)
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
            deliverToPacketFlow(ipPacket: Data(scratch.prefix(Int(res.size))), protocolFamily: AF_INET)
        case UInt32(TUNNELBAHN_WG_WRITE_TO_TUNNEL_IPV6):
            deliverToPacketFlow(ipPacket: Data(scratch.prefix(Int(res.size))), protocolFamily: AF_INET6)
        case UInt32(TUNNELBAHN_WG_DONE):
            break
        case UInt32(TUNNELBAHN_WG_ERROR):
            Self.log.error("tunnelbahn_wg_read error code=\(res.size, privacy: .public)")
        default:
            break
        }
    }

    private func deliverToPacketFlow(ipPacket: Data, protocolFamily: Int32) {
        guard let provider, isRunning else { return }
        provider.packetFlow.writePackets([ipPacket], withProtocols: [NSNumber(value: protocolFamily)])
    }

    private func writeUDP(_ data: Data) {
        guard let session = udpSession else { return }
        udpTxBytesTotal &+= UInt64(data.count)
        session.writeDatagram(data) { error in
            if let error {
                Self.log.error("UDP write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `NWUDPSession` schedules reads after a single `setReadHandler` call (macOS / NetworkExtension API).
    private func installDatagramReadHandler() {
        guard let session = udpSession, isRunning else { return }
        session.setReadHandler({ [weak self] datagrams, error in
            guard let self else { return }
            self.packetQueue.async {
                guard self.isRunning else { return }
                if let error {
                    Self.log.error("UDP read error: \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let datagrams else { return }
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
            self.packetQueue.async {
                guard self.isRunning else { return }
                for packet in packets {
                    self.handleTunPacket(packet)
                }
                self.schedulePacketFlowRead()
            }
        }
    }

    // MARK: - Network settings

    private static func buildNetworkSettings(profile: WireGuardProfile, tunnelRemoteHost: String) -> NEPacketTunnelNetworkSettings {
        let remote = tunnelRemoteHost.split(separator: ":").first.map(String.init) ?? "0.0.0.0"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote)

        let v4CIDRs = profile.interface.addresses.filter { $0.contains(".") && $0.contains("/") }
        if !v4CIDRs.isEmpty {
            let addrs = v4CIDRs.map { String($0.split(separator: "/").first!) }
            let masks = v4CIDRs.map { cidr -> String in
                let parts = cidr.split(separator: "/")
                guard parts.count == 2, let p = Int(parts[1]) else { return "255.255.255.255" }
                return ipv4SubnetMask(prefix: p)
            }
            let ipv4 = NEIPv4Settings(addresses: addrs, subnetMasks: masks)
            ipv4.includedRoutes = [NEIPv4Route.default()]
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
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        if !profile.interface.dnsServers.isEmpty {
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
            "Input profile name=\(profile.name, privacy: .public) addresses=[\(addresses, privacy: .public)] dns=[\(dns, privacy: .public)] mtu=\(mtu, privacy: .public) peers=\(profile.peers.count)"
        )
        for (index, peer) in profile.peers.enumerated() {
            let allowedJoined = peer.allowedIPs.joined(separator: ", ")
            let keepaliveStr = peer.persistentKeepalive.map(String.init) ?? "nil"
            Self.log.notice(
                "Input peer[\(index)] endpoint=\(peer.endpoint, privacy: .public) allowedIPs=\(allowedJoined, privacy: .public) keepalive=\(keepaliveStr, privacy: .public)"
            )
        }
    }
}

import Foundation
import os.log

/// Swift wrapper around the smoltcp relay FFI (runs only on `BoringTunAdapter`'s packet queue).
final class SmoltcpRelayBridge: @unchecked Sendable {
    private static let log = AppLog(subsystem: "com.tunnelbahn.mac.networkextension", category: "RelayBridge")

    private var handle: OpaquePointer?
    private let rxItemCap = 32
    private let rxBlobCap = 256 * 1024
    private var rxItems: [TunnelbahnRelayRxItem]
    private var rxBlob: [UInt8]
    /// Reused scratch for outbound IP packets pulled from smoltcp. Allocated ONCE and overwritten
    /// per packet — deliberately NOT zero-filled (smoltcp writes the bytes; we copy out only `len`).
    /// Previously `pollOutboundPackets()` did `[UInt8](repeating: 0, count: 65536)` on every call,
    /// which `sample` showed as ~60% of the packet-tunnel's saturated core (a 64 KiB alloc+zero per
    /// inbound datagram). All access is on the single serial relay/crypto queue, so no sync needed.
    private var txScratch = [UInt8](repeating: 0, count: 65536)

    var onPayloadFromFlow: ((UInt64, Data) -> Void)?
    /// Fired when the remote peer closed a flow (FIN/RST) and every received byte has already
    /// been delivered via `onPayloadFromFlow`. Error is nil for a clean remote close.
    var onFlowClosed: ((UInt64, String?) -> Void)?
    private var closedScratch = [UInt64](repeating: 0, count: 32)

    init?(tunnelIPv4: String, mtu: UInt16 = 1380) {
        rxItems = Array(
            repeating: TunnelbahnRelayRxItem(flow_id: 0, offset: 0, len: 0),
            count: rxItemCap
        )
        rxBlob = [UInt8](repeating: 0, count: rxBlobCap)
        guard let ptr = tunnelIPv4.withCString({ tunnelbahn_relay_new($0, mtu) }) else {
            return nil
        }
        handle = ptr
        // Content-level proof of which relay build is live (the value comes from the compiled Rust
        // constant, not Swift). 1024 KiB + scaling ON = the new build; 64 KiB + OFF = stale extension.
        let win = tunnelbahn_relay_tcp_window_bytes()
        Self.log.notice(
            "relay TCP window = \(win) bytes (\(win / 1024) KiB) — window scaling \(win > 65536 ? "ON" : "OFF")"
        )
    }

    deinit {
        if let handle {
            tunnelbahn_relay_free(handle)
        }
    }

    func shouldInterceptInbound(packet: Data) -> Bool {
        guard let handle else { return false }
        return packet.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return tunnelbahn_relay_should_intercept_rx(handle, base, UInt32(packet.count)) == 1
        }
    }

    @discardableResult
    func feedInbound(packet: Data) -> Bool {
        guard let handle else { return false }
        let consumed = packet.withUnsafeBytes { buf -> Int32 in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return tunnelbahn_relay_feed_rx_ip(handle, base, UInt32(packet.count))
        }
        if consumed == 1 {
            drainReceivedPayloads()
        }
        return consumed == 1
    }

    /// Returns outbound IP packets smoltcp wants to send through WireGuard.
    func pollOutboundPackets() -> [Data] {
        guard let handle else { return [] }
        var out: [Data] = []
        while true {
            var len: UInt32 = 0
            let rc = txScratch.withUnsafeMutableBytes { buf -> Int32 in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return tunnelbahn_relay_poll_tx_ip(handle, base, UInt32(buf.count), &len)
            }
            if rc == 0 || len == 0 { break }
            if rc == 1 {
                // Copy out only the bytes smoltcp wrote; the reused buffer is overwritten next loop.
                out.append(Data(txScratch.prefix(Int(len))))
            } else if rc == -2 {
                // Packet larger than the scratch (unreachable at 1380-byte MTU, but the Rust side
                // peeks without popping and reports the required size in len): grow and retry
                // instead of losing the packet.
                txScratch = [UInt8](repeating: 0, count: Int(len))
            } else {
                break
            }
        }
        // The poll above runs smoltcp's stack, which can queue inbound payloads; drain them here
        // too, or a quiescent tunnel (no feedInbound / sendTCP traffic) leaves a tail undelivered.
        drainReceivedPayloads()
        return out
    }

    func openTCP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool {
        guard let handle else { return false }
        return remoteHost.withCString { host in
            tunnelbahn_relay_open_tcp(handle, flowID, host, remotePort) == 1
        }
    }

    func close(flowID: UInt64) {
        guard let handle else { return }
        tunnelbahn_relay_close(handle, flowID)
    }

    enum SendResult {
        case ok          // bytes accepted into smoltcp's tx buffer
        case transient   // bytes accepted, but tx queue crossed the high-water mark — pause feeding
        case permanent   // flow missing or socket in terminal state; do not retry
    }

    func sendTCP(flowID: UInt64, data: Data) -> SendResult {
        guard let handle, !data.isEmpty else { return .permanent }
        let raw = data.withUnsafeBytes { buf -> Int32 in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return tunnelbahn_relay_send_tcp(handle, flowID, base, UInt32(data.count))
        }
        switch raw {
        case 1:
            drainReceivedPayloads()
            return .ok
        case 0:
            return .transient
        default:
            return .permanent
        }
    }

    func drainReceivedPayloads() {
        guard let handle else { return }
        if let onPayloadFromFlow {
            let count = rxItems.withUnsafeMutableBufferPointer { itemsBuf -> UInt32 in
                guard let itemsBase = itemsBuf.baseAddress else { return 0 }
                return rxBlob.withUnsafeMutableBufferPointer { blobBuf -> UInt32 in
                    guard let blobBase = blobBuf.baseAddress else { return 0 }
                    return tunnelbahn_relay_drain_rx(
                        handle,
                        itemsBase,
                        UInt32(rxItemCap),
                        blobBase,
                        UInt32(rxBlobCap)
                    )
                }
            }
            for i in 0..<Int(count) {
                let item = rxItems[i]
                let start = Int(item.offset)
                let end = start + Int(item.len)
                guard end <= rxBlob.count else { continue }
                let payload = Data(rxBlob[start..<end])
                onPayloadFromFlow(item.flow_id, payload)
            }
        }
        // After payloads, so a close event can never overtake a flow's final rx bytes (the Rust
        // side additionally defers the close until the flow's pending_rx is empty).
        drainClosedFlows()
    }

    /// Surfaces flows whose remote peer closed (FIN/RST) once all their rx has been delivered.
    private func drainClosedFlows() {
        guard let handle, let onFlowClosed else { return }
        while true {
            let count = closedScratch.withUnsafeMutableBufferPointer { buf -> UInt32 in
                guard let base = buf.baseAddress else { return 0 }
                return tunnelbahn_relay_drain_closed(handle, base, UInt32(buf.count))
            }
            guard count > 0 else { return }
            for i in 0..<Int(count) {
                onFlowClosed(closedScratch[i], nil)
            }
            if Int(count) < closedScratch.count { return }
        }
    }
}

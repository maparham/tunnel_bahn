import Foundation
import NIOCore
import NIOSSH

/// Per-flow pipeline handler installed on each `direct-tcpip` SSH child channel.
///
/// It bridges one child channel to the `RelayFlowTransport` callbacks owned by `SSHFlowTransport`:
///   - inbound `SSHChannelData` (regular `.channel` byte-buffer data) → `onData(flowID, Data)`
///   - `channelInactive` (a clean close, or a remote EOF that — because we do NOT enable
///     `allowRemoteHalfClosure` — is promoted to a full close by swift-nio-ssh) → `onClose(flowID, nil)`
///   - `errorCaught` → `onClose(flowID, "<error>")` and closes the channel.
///
/// All callbacks fire on the parent connection's single event-loop thread. `SSHFlowTransport`
/// serializes its `[UInt64: Flow]` map with a lock, so these callbacks are safe to invoke directly.
final class SSHChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let flowID: UInt64
    private let onData: (UInt64, Data) -> Void
    private let onClose: (UInt64, String?) -> Void
    private var closedReported = false

    init(flowID: UInt64,
         onData: @escaping (UInt64, Data) -> Void,
         onClose: @escaping (UInt64, String?) -> Void) {
        self.flowID = flowID
        self.onData = onData
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        // Forward only regular channel data (stdout-equivalent). Extended data (stderr) is not
        // meaningful for a forwarded TCP stream and is dropped.
        guard channelData.type == .channel, case .byteBuffer(let buffer) = channelData.data else {
            return
        }
        guard buffer.readableBytes > 0 else { return }
        onData(flowID, Data(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        reportClose(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        reportClose("\(error)")
        context.close(promise: nil)
    }

    /// Fires `onClose` at most once for this channel; a subsequent `channelInactive` after an
    /// `errorCaught` (or vice versa) is swallowed. `SSHFlowTransport` additionally de-dupes by
    /// removing the flow from its map, but guarding here keeps the handler self-consistent.
    private func reportClose(_ reason: String?) {
        guard !closedReported else { return }
        closedReported = true
        onClose(flowID, reason)
    }
}

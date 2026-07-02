import Foundation

/// Binary framing protocol used between the transparent-proxy extension and the
/// packet-tunnel extension over a UNIX domain stream socket.
///
/// Wire layout (big-endian / network byte order):
///   [uint32 length] [uint8 type] [type-specific body of (length - 1) bytes]
///
/// `length` covers `type + body` (i.e. everything after itself). A reader pulls 4 bytes,
/// validates `length`, pulls `length` more bytes, dispatches on `type`.
///
/// Why a custom protocol instead of NSXPC: the only IPC mechanisms macOS exposes to a
/// sandboxed system extension for sibling-extension communication are Mach services (which
/// the sandbox refuses to register names for, see [[project-per-app-vpn-architecture]]) and
/// raw file/socket I/O inside the App Group container. A UNIX domain socket bound under the
/// shared container sidesteps both the Mach name issue and the Mach-port-can't-ride-Data
/// problem that killed the anonymous-NSXPCListener approach.
public enum RelayWireFrame {
    public enum FrameType: UInt8 {
        // proxy -> tunnel
        case reqOpenFlow      = 0x01
        case reqSendPayload   = 0x02
        case reqCloseFlow     = 0x03
        // tunnel -> proxy
        case repOpenFlow      = 0x81
        case pushDeliver      = 0x82
        case pushFlowClosed   = 0x83
    }

    /// Hard cap on a single frame's payload to keep the reader's allocation bounded.
    /// 1 MiB is well above any plausible single read from `NEAppProxyFlow.readData`.
    public static let maxFrameBodyLength: UInt32 = 1 << 20

    // MARK: - Encoders

    public static func encodeOpenFlowRequest(reqID: UInt32, flowID: UInt64, remoteHost: String, remotePort: UInt16, isTCP: Bool) -> Data {
        var body = Data()
        body.appendUInt8(FrameType.reqOpenFlow.rawValue)
        body.appendUInt32BE(reqID)
        body.appendUInt64BE(flowID)
        body.appendUInt16BE(remotePort)
        body.appendUInt8(isTCP ? 1 : 0)
        let hostBytes = Data(remoteHost.utf8)
        body.appendUInt16BE(UInt16(min(hostBytes.count, 0xFFFF)))
        body.append(hostBytes.prefix(0xFFFF))
        return prependLength(body)
    }

    /// Largest payload slice that fits one frame: `maxFrameBodyLength` minus type(1) + flowID(8).
    public static let maxPayloadChunkLength = Int(maxFrameBodyLength) - 9

    /// Payload frames carry TCP stream bytes, so an oversized payload is split across multiple
    /// frames rather than emitting one the reader would reject as malformed.
    public static func encodeSendPayloadRequest(flowID: UInt64, payload: Data) -> [Data] {
        encodeChunkedPayload(type: .reqSendPayload, flowID: flowID, payload: payload)
    }

    public static func encodeCloseFlowRequest(flowID: UInt64) -> Data {
        var body = Data()
        body.appendUInt8(FrameType.reqCloseFlow.rawValue)
        body.appendUInt64BE(flowID)
        return prependLength(body)
    }

    public static func encodeOpenFlowReply(reqID: UInt32, ok: Bool, error: String?) -> Data {
        var body = Data()
        body.appendUInt8(FrameType.repOpenFlow.rawValue)
        body.appendUInt32BE(reqID)
        body.appendUInt8(ok ? 1 : 0)
        let errBytes = Data((error ?? "").utf8)
        body.appendUInt16BE(UInt16(min(errBytes.count, 0xFFFF)))
        body.append(errBytes.prefix(0xFFFF))
        return prependLength(body)
    }

    /// See `encodeSendPayloadRequest` — same chunking rule.
    public static func encodeDeliverPayloadPush(flowID: UInt64, payload: Data) -> [Data] {
        encodeChunkedPayload(type: .pushDeliver, flowID: flowID, payload: payload)
    }

    private static func encodeChunkedPayload(type: FrameType, flowID: UInt64, payload: Data) -> [Data] {
        var frames: [Data] = []
        var offset = payload.startIndex
        repeat {
            let end = payload.index(offset, offsetBy: maxPayloadChunkLength, limitedBy: payload.endIndex) ?? payload.endIndex
            var body = Data()
            body.appendUInt8(type.rawValue)
            body.appendUInt64BE(flowID)
            body.append(payload[offset..<end])
            frames.append(prependLength(body))
            offset = end
        } while offset < payload.endIndex
        return frames
    }

    public static func encodeFlowClosedPush(flowID: UInt64, error: String?) -> Data {
        var body = Data()
        body.appendUInt8(FrameType.pushFlowClosed.rawValue)
        body.appendUInt64BE(flowID)
        let errBytes = Data((error ?? "").utf8)
        body.appendUInt16BE(UInt16(min(errBytes.count, 0xFFFF)))
        body.append(errBytes.prefix(0xFFFF))
        return prependLength(body)
    }

    // MARK: - Decoded frame ADT

    public enum Frame {
        case openFlowRequest(reqID: UInt32, flowID: UInt64, remoteHost: String, remotePort: UInt16, isTCP: Bool)
        case sendPayloadRequest(flowID: UInt64, payload: Data)
        case closeFlowRequest(flowID: UInt64)
        case openFlowReply(reqID: UInt32, ok: Bool, error: String?)
        case deliverPayloadPush(flowID: UInt64, payload: Data)
        case flowClosedPush(flowID: UInt64, error: String?)
    }

    public enum ParseResult {
        case frame(Frame, consumed: Int)
        /// Buffer holds a valid prefix of a frame; feed more bytes and retry.
        case needMoreData
        /// The stream is poisoned — framing offers no way to resync past a bad frame, so the
        /// caller MUST tear down the link. Treating this like `needMoreData` wedges the relay
        /// forever (the reader waits while the buffer grows unbounded).
        case malformed(String)
    }

    /// Callers feed bytes in and slice `consumed` off the front on `.frame`.
    public static func parse(_ buffer: Data) -> ParseResult {
        guard buffer.count >= 4 else { return .needMoreData }
        let length = buffer.readUInt32BE(at: buffer.startIndex)
        guard length >= 1 else { return .malformed("zero-length frame") }
        guard length <= maxFrameBodyLength else { return .malformed("frame length \(length) exceeds cap \(maxFrameBodyLength)") }
        let totalNeeded = 4 + Int(length)
        guard buffer.count >= totalNeeded else { return .needMoreData }
        let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + totalNeeded))
        guard let typeRaw = body.first, let type = FrameType(rawValue: typeRaw) else {
            return .malformed("unknown frame type 0x\(String(body.first ?? 0, radix: 16))")
        }
        let payload = body.dropFirst()
        guard let frame = decodeBody(type: type, payload: payload) else {
            return .malformed("undecodable body for frame type 0x\(String(typeRaw, radix: 16))")
        }
        return .frame(frame, consumed: totalNeeded)
    }

    private static func decodeBody(type: FrameType, payload: Data) -> Frame? {
        switch type {
        case .reqOpenFlow:
            // reqID(4) + flowID(8) + port(2) + isTCP(1) + hostLen(2) + host
            guard payload.count >= 4 + 8 + 2 + 1 + 2 else { return nil }
            var off = payload.startIndex
            let reqID = payload.readUInt32BE(at: off); off += 4
            let flowID = payload.readUInt64BE(at: off); off += 8
            let port = payload.readUInt16BE(at: off); off += 2
            let isTCP = payload[off] != 0; off += 1
            let hostLen = Int(payload.readUInt16BE(at: off)); off += 2
            guard payload.count >= (off - payload.startIndex) + hostLen else { return nil }
            let host = String(data: payload.subdata(in: off..<(off + hostLen)), encoding: .utf8) ?? ""
            return .openFlowRequest(reqID: reqID, flowID: flowID, remoteHost: host, remotePort: port, isTCP: isTCP)
        case .reqSendPayload:
            // flowID(8) + bytes
            guard payload.count >= 8 else { return nil }
            let flowID = payload.readUInt64BE(at: payload.startIndex)
            let data = payload.suffix(from: payload.startIndex + 8)
            return .sendPayloadRequest(flowID: flowID, payload: Data(data))
        case .reqCloseFlow:
            guard payload.count >= 8 else { return nil }
            let flowID = payload.readUInt64BE(at: payload.startIndex)
            return .closeFlowRequest(flowID: flowID)
        case .repOpenFlow:
            // reqID(4) + ok(1) + errLen(2) + err
            guard payload.count >= 4 + 1 + 2 else { return nil }
            var off = payload.startIndex
            let reqID = payload.readUInt32BE(at: off); off += 4
            let ok = payload[off] != 0; off += 1
            let errLen = Int(payload.readUInt16BE(at: off)); off += 2
            guard payload.count >= (off - payload.startIndex) + errLen else { return nil }
            let err = errLen > 0 ? String(data: payload.subdata(in: off..<(off + errLen)), encoding: .utf8) : nil
            return .openFlowReply(reqID: reqID, ok: ok, error: (err?.isEmpty == true) ? nil : err)
        case .pushDeliver:
            guard payload.count >= 8 else { return nil }
            let flowID = payload.readUInt64BE(at: payload.startIndex)
            let data = payload.suffix(from: payload.startIndex + 8)
            return .deliverPayloadPush(flowID: flowID, payload: Data(data))
        case .pushFlowClosed:
            // flowID(8) + errLen(2) + err
            guard payload.count >= 8 + 2 else { return nil }
            var off = payload.startIndex
            let flowID = payload.readUInt64BE(at: off); off += 8
            let errLen = Int(payload.readUInt16BE(at: off)); off += 2
            guard payload.count >= (off - payload.startIndex) + errLen else { return nil }
            let err = errLen > 0 ? String(data: payload.subdata(in: off..<(off + errLen)), encoding: .utf8) : nil
            return .flowClosedPush(flowID: flowID, error: (err?.isEmpty == true) ? nil : err)
        }
    }

    private static func prependLength(_ body: Data) -> Data {
        var out = Data(capacity: 4 + body.count)
        out.appendUInt32BE(UInt32(body.count))
        out.append(body)
        return out
    }
}

// MARK: - Big-endian read/write helpers

extension Data {
    fileprivate mutating func appendUInt8(_ v: UInt8) {
        append(v)
    }

    fileprivate mutating func appendUInt16BE(_ v: UInt16) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { rawBuf in
            self.append(contentsOf: rawBuf)
        }
    }

    fileprivate mutating func appendUInt32BE(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { rawBuf in
            self.append(contentsOf: rawBuf)
        }
    }

    fileprivate mutating func appendUInt64BE(_ v: UInt64) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { rawBuf in
            self.append(contentsOf: rawBuf)
        }
    }

    fileprivate func readUInt16BE(at index: Index) -> UInt16 {
        var v: UInt16 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            self.copyBytes(to: dst, from: index..<(index + 2))
        }
        return UInt16(bigEndian: v)
    }

    fileprivate func readUInt32BE(at index: Index) -> UInt32 {
        var v: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            self.copyBytes(to: dst, from: index..<(index + 4))
        }
        return UInt32(bigEndian: v)
    }

    fileprivate func readUInt64BE(at index: Index) -> UInt64 {
        var v: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            self.copyBytes(to: dst, from: index..<(index + 8))
        }
        return UInt64(bigEndian: v)
    }
}

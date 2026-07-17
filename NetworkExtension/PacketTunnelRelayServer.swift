import Foundation
import Darwin
import os.log

/// UNIX-domain-socket relay server. Listens on `SharedPaths.relaySocketURL()` inside the
/// App Group container; accepts a single client (the transparent-proxy ext) at a time.
/// Decodes [[RelayWireFrame]] frames and dispatches to `SmoltcpRelayBridge` for the in-tunnel
/// data path. Inbound smoltcp deliveries are pushed back to the proxy via the same socket.
///
/// Why UNIX sockets and not NSXPC: see the file-level note in [[RelayWireFrame]] — the
/// sandboxed system extension can register neither a Mach name nor a transferable XPC
/// listener endpoint, so we rendezvous via a well-known file path that both extensions can
/// see through their shared App Group entitlement.
final class PacketTunnelRelayServer {
    private static let log = AppLog(subsystem: "com.tunnelbahn.mac.networkextension", category: "RelaySocket")

    /// Cap on un-drained outbound bytes before we drop the client and let it reconnect — bounds
    /// memory if the proxy side stops reading while inbound smoltcp deliveries keep arriving.
    private static let maxWriteBuffer = 8 * 1024 * 1024
    /// While smoltcp's tx is backed up (`send_tcp` → `.transient`), we suspend UDS reads to
    /// backpressure the proxy, then resume after this pace to re-evaluate as smoltcp drains. Short so
    /// the pause is fine-grained; the cycle self-corrects (still-full → re-pause, drained → flow on).
    private static let backpressureResumeMs = 5

    private let socketPath: String
    private let packetQueue: DispatchQueue
    private let relayBridge: SmoltcpRelayBridge

    private let ioQueue = DispatchQueue(label: "com.tunnelbahn.mac.networkextension.relay.io", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    /// True while `readSource` is suspended for tx backpressure (touched only on `ioQueue`). Tracked so
    /// we balance suspend/resume exactly and always resume before cancel — releasing a suspended source traps.
    private var readsSuspended = false

    // Outbound side, mirror of the proxy-side client. The socket is non-blocking (see `acceptOne`)
    // so a full kernel send buffer returns EAGAIN instead of sleeping in write() and starving the
    // read source — the P1 deadlock fix. Overflow is buffered and drained from a write
    // `DispatchSource`. All three are touched only on `ioQueue` (every caller funnels through it),
    // so no lock is needed — this replaces the old `writeLock`.
    private var writeBuffer = Data()
    /// Consumed prefix of `writeBuffer` already accepted by the kernel. Writing from an advancing
    /// offset and compacting lazily avoids an O(remaining) memmove per partial write. On `ioQueue`.
    private var writeOffset = 0
    /// Armed (created + resumed) only while a write is blocked on EAGAIN; cancelled and cleared the
    /// moment the buffer drains. Kept strictly on-demand — never held suspended-at-rest — because
    /// releasing a *suspended* dispatch source traps (`_dispatch_queue_xref_dispose.cold.1`, seen in
    /// `PacketTunnelRelayServer.deinit`). A resumed-or-cancelled source is always safe to release.
    private var writeSource: DispatchSourceWrite?

    init?(relayBridge: SmoltcpRelayBridge, packetQueue: DispatchQueue) {
        guard let url = SharedPaths.relaySocketURL() else {
            Self.log.error("relaySocketURL is nil — cannot start relay server")
            return nil
        }
        self.socketPath = url.path
        self.relayBridge = relayBridge
        self.packetQueue = packetQueue
        relayBridge.onPayloadFromFlow = { [weak self] flowID, data in
            self?.pushDeliver(flowID: flowID, payload: data)
        }
        relayBridge.onFlowClosed = { [weak self] flowID, error in
            self?.pushFlowClosed(flowID: flowID, error: error)
        }
    }

    func start() {
        ioQueue.async { [weak self] in self?.bindAndListen() }
    }

    func stop() {
        // Capture self strongly: the caller drops its last reference right after stop(), and a
        // weak capture would deallocate the server before teardown runs — leaking the bound
        // listening fd in the reused extension process.
        ioQueue.async { self.teardown() }
    }

    // MARK: - Socket lifecycle

    private func bindAndListen() {
        // Remove any stale socket file from a prior run; failure to unlink an existing
        // file means bind() will hit EADDRINUSE.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.log.error("socket() failed errno=\(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a fixed-size 104-byte C array; copy in the bytes.
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Self.log.error("socket path too long: \(self.socketPath)")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dstChar in
                for (i, b) in pathBytes.enumerated() {
                    dstChar[i] = CChar(bitPattern: b)
                }
                dstChar[pathBytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                bind(fd, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Self.log.error("bind(\(self.socketPath)) failed errno=\(errno)")
            close(fd)
            return
        }
        // Group container files default to mode 0600; loosen to 0660 in case both extensions
        // run under different effective ids (they shouldn't, but cheap insurance).
        chmod(socketPath, 0o660)

        guard listen(fd, 1) == 0 else {
            Self.log.error("listen() failed errno=\(errno)")
            close(fd)
            return
        }
        listenFD = fd
        Self.log.notice("relay socket listening at \(self.socketPath)")
        installAcceptSource()
    }

    private func installAcceptSource() {
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        acceptSource = src
    }

    private func acceptOne() {
        let newFD = accept(listenFD, nil, nil)
        guard newFD >= 0 else {
            if errno != EAGAIN && errno != EWOULDBLOCK {
                Self.log.error("accept() failed errno=\(errno)")
            }
            return
        }
        if clientFD >= 0 {
            // We model the proxy<->tunnel link as a single persistent connection. If a new
            // connection arrives while one is live, the old one was probably an orphan — drop
            // it and accept the new client.
            Self.log.notice("relay server: replacing existing client fd=\(self.clientFD) with new fd=\(newFD)")
            closeClient()
        }
        clientFD = newFD
        readBuffer.removeAll(keepingCapacity: true)
        var on: Int32 = 1
        setsockopt(newFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking: EAGAIN on a full send buffer is handled by the buffered write source
        // instead of blocking ioQueue and starving reads — the P1 fix.
        let flags = fcntl(newFD, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(newFD, F_SETFL, flags | O_NONBLOCK) }
        installReadSource(for: newFD)
        Self.log.notice("relay server: accepted client fd=\(newFD)")
    }

    private func installReadSource(for fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.drainSocket() }
        src.setCancelHandler { close(fd) }
        src.resume()
        readSource = src

        writeSource?.cancel()  // defensive: drop any source still armed from a prior client
        writeSource = nil
        writeBuffer.removeAll(keepingCapacity: true)
        writeOffset = 0
    }

    private func drainSocket() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBufferPointer { buf in
            read(clientFD, buf.baseAddress, buf.count)
        }
        if n == 0 {
            Self.log.notice("relay server: client EOF")
            closeClient()
            return
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            Self.log.error("relay server: read errno=\(errno)")
            closeClient()
            return
        }
        readBuffer.append(chunk, count: n)
        consumeFrames()
    }

    private func consumeFrames() {
        // Parse with an O(1) slice cursor (parse is startIndex-aware) and compact once — the
        // previous per-frame `removeFirst(used)` memmoved the remaining buffer down once per
        // frame, quadratic over a 64 KiB read full of small frames. Decoded frames own copies
        // of their payloads, so dispatching after the compaction is safe.
        var consumed = 0
        var frames: [RelayWireFrame.Frame] = []
        var malformedReason: String?
        loop: while true {
            switch RelayWireFrame.parse(readBuffer[(readBuffer.startIndex + consumed)...]) {
            case let .frame(frame, used):
                frames.append(frame)
                consumed += used
            case .needMoreData:
                break loop
            case let .malformed(reason):
                malformedReason = reason
                break loop
            }
        }
        if consumed > 0 {
            readBuffer.removeFirst(consumed)
        }
        for frame in frames {
            handle(frame: frame)
        }
        if let malformedReason {
            // No resync is possible past a bad frame; drop the client and let it reconnect
            // with a fresh stream rather than wedging with an ever-growing buffer.
            Self.log.error("relay server: malformed frame (\(malformedReason)) — dropping client")
            closeClient()
        }
    }

    // MARK: - Read backpressure (smoltcp tx full → pause UDS reads → proxy + source app throttle)

    /// Invoked on `packetQueue` when `send_tcp` returned `.transient`. Suspends the UDS read source so
    /// the kernel recv buffer and the proxy's write buffer fill (backpressuring the source app), then
    /// resumes after a short pace to re-evaluate. Idempotent: extra `.transient`s while already
    /// suspended are no-ops, so only one resume is ever scheduled per pause.
    private func applyReadBackpressure() {
        ioQueue.async { [weak self] in
            guard let self, let rs = self.readSource, !self.readsSuspended else { return }
            rs.suspend()
            self.readsSuspended = true
            self.ioQueue.asyncAfter(deadline: .now() + .milliseconds(Self.backpressureResumeMs)) { [weak self] in
                self?.resumeReads()
            }
        }
    }

    /// Resumes UDS reads after a backpressure pause (on `ioQueue`). If smoltcp is still full when reads
    /// resume, the next `send_tcp` returns `.transient` again and re-pauses — a self-correcting cycle.
    private func resumeReads() {
        guard let rs = readSource, readsSuspended else { return }
        readsSuspended = false
        rs.resume()
    }

    private func handle(frame: RelayWireFrame.Frame) {
        switch frame {
        case let .openFlowRequest(reqID, flowID, host, port, isTCP):
            packetQueue.async { [weak self] in
                guard let self else { return }
                if !isTCP {
                    self.sendFrame(RelayWireFrame.encodeOpenFlowReply(reqID: reqID, ok: false, error: "UDP not implemented"))
                    return
                }
                let ok = self.relayBridge.openTCP(flowID: flowID, remoteHost: host, remotePort: port)
                if ok {
                    Self.log.notice("[APPSPLIT_RELAY] openFlow ok flowID=\(flowID) remote=\(host):\(port)")
                } else {
                    Self.log.error("[APPSPLIT_RELAY] openFlow failed flowID=\(flowID) remote=\(host):\(port)")
                }
                self.sendFrame(RelayWireFrame.encodeOpenFlowReply(reqID: reqID, ok: ok, error: ok ? nil : "smoltcp open failed"))
            }
        case let .sendPayloadRequest(flowID, payload):
            // The bridge buffers in order and never drops, so a single call is authoritative:
            // `.ok` means the bytes are queued/sent; `.permanent` means the flow is unknown or
            // its socket can never send again (or the per-flow buffer cap was hit), so we push
            // `flowClosedPush` to tear down the source-app flow instead of streaming into a
            // dead pipe. We deliberately do NOT retry out of band — a deferred retry could let
            // a later payload reach the bridge first and reorder the TCP stream.
            packetQueue.async { [weak self] in
                guard let self else { return }
                switch self.relayBridge.sendTCP(flowID: flowID, data: payload) {
                case .ok:
                    return
                case .transient:
                    // Backpressure: the bytes WERE accepted, but smoltcp's tx queue crossed the
                    // high-water mark. Pause UDS reads so the kernel recv buffer + the proxy's write
                    // buffer fill and the source app throttles itself — instead of overrunning to the
                    // fail-closed cap, which is what made sustained uploads fail.
                    self.applyReadBackpressure()
                    return
                case .permanent:
                    Self.log.error("[APPSPLIT_RELAY] sendPayload permanent failure flowID=\(flowID) — pushing flowClosed")
                    self.relayBridge.close(flowID: flowID)
                    self.pushFlowClosed(flowID: flowID, error: "tunnel relay socket terminal or flow unknown")
                }
            }
        case let .closeFlowRequest(flowID):
            packetQueue.async { [weak self] in
                self?.relayBridge.close(flowID: flowID)
            }
        case .openFlowReply, .deliverPayloadPush, .flowClosedPush:
            // These are tunnel -> proxy frames; should never arrive here.
            Self.log.error("relay server received unexpected client->server frame type")
        }
    }

    private func pushDeliver(flowID: UInt64, payload: Data) {
        // Chunked: `sendFrame` enqueues onto the serial ioQueue, so per-chunk calls stay ordered.
        for frame in RelayWireFrame.encodeDeliverPayloadPush(flowID: flowID, payload: payload) {
            sendFrame(frame)
        }
    }

    func pushFlowClosed(flowID: UInt64, error: String?) {
        sendFrame(RelayWireFrame.encodeFlowClosedPush(flowID: flowID, error: error))
    }

    private func sendFrame(_ data: Data) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.clientFD >= 0 else { return }
            self.writeBuffer.append(data)
            self.drainWriteBuffer()
        }
    }

    /// Writes as much of `writeBuffer` as the kernel accepts. On EAGAIN it arms the write source and
    /// returns; once fully drained it disarms it. Always on `ioQueue`.
    private func drainWriteBuffer() {
        guard clientFD >= 0 else { return }
        let fd = clientFD
        while writeOffset < writeBuffer.count {
            let n = writeBuffer.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return write(fd, base + writeOffset, writeBuffer.count - writeOffset)
            }
            if n > 0 {
                writeOffset += n
                // Compact lazily: free everything once drained, or shed a large consumed prefix;
                // never memmove per partial write (that made a full-buffer drain quadratic).
                if writeOffset == writeBuffer.count {
                    writeBuffer.removeAll(keepingCapacity: true)
                    writeOffset = 0
                } else if writeOffset >= 512 * 1024 {
                    writeBuffer.removeFirst(writeOffset)
                    writeOffset = 0
                }
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                let pending = writeBuffer.count - writeOffset
                if pending > Self.maxWriteBuffer {
                    Self.log.error("relay server: write buffer overflow \(pending)B — dropping client")
                    closeClient()
                    return
                }
                armWriteSource(fd: fd)
                return
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                Self.log.error("relay server: write failed errno=\(errno) buffered=\(self.writeBuffer.count - self.writeOffset)")
                closeClient()
                return
            }
        }
        disarmWriteSource()
    }

    /// Arms an on-demand write source (resumed immediately) for a writable callback. Cancelled in
    /// `disarmWriteSource` once drained, so it is never held suspended (release of a suspended source
    /// traps). Always on `ioQueue`.
    private func armWriteSource(fd: Int32) {
        guard writeSource == nil else { return }  // already armed
        let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
        ws.setEventHandler { [weak self] in self?.drainWriteBuffer() }
        writeSource = ws
        ws.resume()
    }

    private func disarmWriteSource() {
        guard let ws = writeSource else { return }
        ws.cancel()  // resumed → safe to release
        writeSource = nil
    }

    private func closeClient() {
        if let src = readSource {
            // A suspended source traps on release — resume to balance the count before cancelling.
            if readsSuspended {
                src.resume()
                readsSuspended = false
            }
            src.cancel()
            readSource = nil
        }
        if let wsrc = writeSource {
            wsrc.cancel()  // armed sources are always resumed → safe to release
            writeSource = nil
        }
        if clientFD >= 0 {
            // cancel handler closes the fd; just drop our reference.
            clientFD = -1
        }
        readBuffer.removeAll(keepingCapacity: true)
        writeBuffer.removeAll(keepingCapacity: true)
        writeOffset = 0
    }

    private func teardown() {
        closeClient()
        if let src = acceptSource {
            src.cancel()
            acceptSource = nil
        }
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }
}

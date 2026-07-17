import Foundation
import Darwin
import os.log

/// UNIX-domain-socket relay client. Connects to the packet-tunnel ext's listener at
/// `SharedPaths.relaySocketURL()` and ships [[RelayWireFrame]] frames.
///
/// Replaces the previous NSXPC-based [[TransparentProxyXPCBridge]]. The public API surface
/// (singleton, `openFlow`/`sendPayload`/`closeFlow`) is intentionally identical so the
/// `TCPFlowRelay` call sites don't need behavioral changes — only the type name swap.
///
/// Connection model:
/// - Lazy connect on first use, with retry/backoff up to `pendingWindow` seconds (covers the
///   startup race where the proxy ext is up before the tunnel ext finishes binding).
/// - One persistent connection, multiplexed across all flows.
/// - On read EOF / write failure, all in-flight flows fail; flows opened after the break
///   will trigger a fresh connect.
final class TransparentProxyRelayClient {
    static let shared = TransparentProxyRelayClient()

    private static let log = AppLog(
        subsystem: "com.tunnelbahn.mac.transparentproxy",
        category: "RelaySocket"
    )

    /// Max time spent retrying the connect to the tunnel ext's socket before failing a flow.
    /// Covers the case where `handleNewFlow` fires while the tunnel ext is still in startup.
    private static let pendingWindow: TimeInterval = 3.0
    private static let connectRetryInterval: TimeInterval = 0.1
    /// Once an `openFlow` request is on the wire, the server must reply within this window.
    /// `pendingWindow` only covers establishing the *connection*; nothing used to time out the
    /// *reply*, so a wedged link (e.g. the P1 send-buffer deadlock) left a flow hanging forever.
    /// On timeout we reset the link so the flow fails closed and the next `openFlow` reconnects.
    private static let openReplyTimeout: TimeInterval = 5.0
    /// Cap on un-drained outbound bytes. `sendPayload` fires its completion immediately (no socket
    /// backpressure), so a peer that stops reading (e.g. a wedged tunnel while the socket stays up)
    /// would otherwise grow `writeBuffer` without bound. Past this we tear the link down — fail
    /// closed and reconnect — instead of ballooning memory.
    private static let maxWriteBuffer = 8 * 1024 * 1024
    /// Backpressure hysteresis on the shared UDS write buffer. When buffered (un-drained) bytes cross
    /// `writeHighWater`, `sendPayload` HOLDS its completion instead of firing it — which pauses the
    /// caller's `flow.readData` loop (it only reads the next chunk inside that completion), so the
    /// source app's own TCP send window fills and it throttles itself. Held completions resume once the
    /// write source drains the buffer below `writeLowWater`. This re-couples upload speed to the real
    /// tunnel drain rate and keeps the buffer far below `maxWriteBuffer`, so the fail-closed teardown
    /// above no longer trips on a sustained upload (the speedtest-upload-fails bug, confirmed via the
    /// "write buffer overflow … peer not draining" teardown that killed the whole relay link).
    private static let writeHighWater = 2 * 1024 * 1024
    private static let writeLowWater = 512 * 1024

    private let ioQueue = DispatchQueue(label: "com.tunnelbahn.mac.transparentproxy.relay.io", qos: .userInitiated)
    private let stateLock = NSLock()

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()

    // Outbound side. Sockets are non-blocking (see `openSocketOnce`), so `write()` returns
    // `EAGAIN` instead of sleeping when the kernel send buffer fills. We buffer the overflow and
    // drain it from a write `DispatchSource` that fires when the fd is writable again. This is what
    // breaks the P1 deadlock: a full send buffer no longer blocks `ioQueue`, so the read source can
    // still run and drain the peer. All three are touched only under `stateLock`.
    private var writeBuffer = Data()
    /// Consumed prefix of `writeBuffer` already accepted by the kernel. Writing from an advancing
    /// offset and compacting lazily avoids an O(remaining) memmove per partial write
    /// (`removeFirst(n)` on every EAGAIN-paced iteration made draining a full buffer quadratic).
    /// Under `stateLock`.
    private var writeOffset = 0
    /// `sendPayload` completions held while `writeBuffer` is above the high-water mark (backpressure).
    /// Fired `true` once the buffer drains below the low-water mark, `false` on teardown. Under `stateLock`.
    private var pausedSendCompletions: [(Bool) -> Void] = []
    /// Armed (created + resumed) only while a write is blocked on EAGAIN; cancelled and cleared the
    /// moment the buffer drains. Kept strictly on-demand — never held suspended-at-rest — because
    /// releasing a *suspended* dispatch source traps (`_dispatch_queue_xref_dispose.cold.1`). A
    /// resumed-or-cancelled source is always safe to release, including from `deinit`. Under `stateLock`.
    private var writeSource: DispatchSourceWrite?

    private var nextReqID: UInt32 = 1
    private var openCompletions: [UInt32: (Bool) -> Void] = [:]
    private var flowDeliverHandlers: [UInt64: (Data) -> Void] = [:]
    private var flowCloseHandlers: [UInt64: (String?) -> Void] = [:]

    private init() {}

    // MARK: - Public API (mirrors the old XPC bridge so callsites stay identical)

    func openFlow(
        flowID: UInt64,
        remoteHost: String,
        remotePort: UInt16,
        isTCP: Bool,
        onReceive: @escaping (Data) -> Void,
        onClose: @escaping (String?) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        ensureConnected(deadline: Date().addingTimeInterval(Self.pendingWindow)) { [weak self] connected in
            guard let self else { completion(false); return }
            guard connected else {
                Self.log.error("[APPSPLIT_RELAY] openFlow: bridge not ready flowID=\(flowID)")
                completion(false)
                return
            }
            self.stateLock.lock()
            let reqID = self.nextReqID
            self.nextReqID &+= 1
            self.openCompletions[reqID] = completion
            self.flowDeliverHandlers[flowID] = onReceive
            self.flowCloseHandlers[flowID] = onClose
            self.stateLock.unlock()

            let frame = RelayWireFrame.encodeOpenFlowRequest(
                reqID: reqID, flowID: flowID, remoteHost: remoteHost, remotePort: remotePort, isTCP: isTCP
            )
            self.writeFrame(frame)
            self.scheduleOpenReplyWatchdog(reqID: reqID)
        }
    }

    /// If the server never sends an `openFlowReply` for `reqID` within `openReplyTimeout`, the link
    /// is wedged — reset it. `tearDown` fails the pending open (`comp(false)`) so the flow fails
    /// closed instead of hanging, and the next `openFlow` reconnects. Fires on `ioQueue`.
    private func scheduleOpenReplyWatchdog(reqID: UInt32) {
        ioQueue.asyncAfter(deadline: .now() + Self.openReplyTimeout) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillPending = self.openCompletions[reqID] != nil
            self.stateLock.unlock()
            guard stillPending else { return }  // reply (or reconnect-reset) already cleared it
            Self.log.error("[APPSPLIT_RELAY] openFlow reply timeout reqID=\(reqID) — resetting link")
            self.tearDown(reason: "openFlow reply timeout")
        }
    }

    func sendPayload(flowID: UInt64, data: Data, completion: @escaping (Bool) -> Void) {
        // Fire-and-forget: the OS socket buffer absorbs short bursts, and a write failure
        // tears the whole connection so the next openFlow will reconnect. Callers that need
        // strict per-payload acks would need a request-id round-trip here.
        //
        // Also gate on flow registration: if the close handler was already cleared (because
        // tearDown / reconnect-reset invalidated it), the flow is dead from our perspective.
        // Without this check, an in-flight `flow.readData` completion racing against tearDown
        // could ship bytes with a stale flowID to a freshly-reconnected tunnel server that has
        // no record of it — exactly the stale-flow cascade.
        stateLock.lock()
        let ready = socketFD >= 0 && flowCloseHandlers[flowID] != nil
        stateLock.unlock()
        guard ready else {
            completion(false)
            return
        }
        // A payload above the frame cap is split into multiple frames; appending them as one
        // contiguous blob keeps the single-completion backpressure semantics.
        let frames = RelayWireFrame.encodeSendPayloadRequest(flowID: flowID, payload: data)
        let blob: Data
        if frames.count == 1 {
            blob = frames[0]
        } else {
            var combined = Data(capacity: frames.reduce(0) { $0 + $1.count })
            for f in frames { combined.append(f) }
            blob = combined
        }
        // Hand the completion to the write path so it can apply backpressure: it fires immediately when
        // the buffer is healthy, or is held until the buffer drains when we're congested. The caller's
        // read loop reads the next chunk only inside this completion, so holding it pauses the source app.
        writeFrame(blob, flowID: flowID, completion: completion)
    }

    func closeFlow(flowID: UInt64) {
        stateLock.lock()
        flowDeliverHandlers.removeValue(forKey: flowID)
        flowCloseHandlers.removeValue(forKey: flowID)
        let ready = socketFD >= 0
        stateLock.unlock()
        guard ready else { return }
        writeFrame(RelayWireFrame.encodeCloseFlowRequest(flowID: flowID))
    }

    /// Force-drop the current socket so the next `openFlow` reconnects. Called by `startProxy`
    /// because the tunnel extension recreates its listener on every connect — the singleton's
    /// cached `socketFD` from a prior session points at a dead server-side fd, so writes succeed
    /// silently but the reply never comes back and flows hang forever.
    func reset(reason: String) {
        stateLock.lock()
        let needsTeardown = socketFD >= 0 || readSource != nil
        stateLock.unlock()
        guard needsTeardown else { return }
        tearDown(reason: reason)
    }

    // MARK: - Connection management

    private func ensureConnected(deadline: Date, completion: @escaping (Bool) -> Void) {
        stateLock.lock()
        if socketFD >= 0 {
            stateLock.unlock()
            completion(true)
            return
        }
        stateLock.unlock()
        attemptConnect(deadline: deadline, completion: completion)
    }

    private func attemptConnect(deadline: Date, completion: @escaping (Bool) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { completion(false); return }
            if self.openSocketOnce() {
                completion(true)
                return
            }
            if Date() >= deadline {
                Self.log.error("relay client: connect deadline exceeded path=\(SharedPaths.relaySocketURL()?.path ?? "nil")")
                completion(false)
                return
            }
            self.ioQueue.asyncAfter(deadline: .now() + Self.connectRetryInterval) {
                self.attemptConnect(deadline: deadline, completion: completion)
            }
        }
    }

    /// Returns true if a socket was successfully opened (and stored). False on transient
    /// failure; the retry loop in `attemptConnect` calls again.
    private func openSocketOnce() -> Bool {
        // Always on the serial ioQueue, so connects can't overlap — but several openFlow callers
        // can each queue an attempt while disconnected. Without this re-check the second attempt
        // opens a duplicate socket, orphans the first fd, and the reconnect-reset below kills the
        // flows the first attempt just registered.
        stateLock.lock()
        let alreadyConnected = socketFD >= 0
        stateLock.unlock()
        if alreadyConnected { return true }

        guard let url = SharedPaths.relaySocketURL() else {
            Self.log.error("relay client: socket URL nil")
            return false
        }
        let path = url.path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.log.error("relay client: socket() failed errno=\(errno)")
            return false
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Self.log.error("relay client: socket path too long")
            close(fd)
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dstChar in
                for (i, b) in pathBytes.enumerated() {
                    dstChar[i] = CChar(bitPattern: b)
                }
                dstChar[pathBytes.count] = 0
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                connect(fd, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            // ENOENT (server hasn't bound yet) is expected during the startup race; quieter log.
            if errno == ENOENT || errno == ECONNREFUSED {
                Self.log.debug("relay client: connect waiting (errno=\(errno))")
            } else {
                Self.log.error("relay client: connect failed errno=\(errno)")
            }
            close(fd)
            return false
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking: a full kernel send buffer must return EAGAIN (handled by the buffered
        // write source) instead of sleeping in write() and starving the read source — the P1 fix.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        // Defense-in-depth: any handlers still registered at this point are stragglers from a
        // prior tunnel-server process whose disconnect we never observed (writes-to-dead-server
        // succeed silently — see `reset(reason:)` doc). The new server has no record of those
        // flowIDs, so any future sendPayload would either hit our sendPayload registration
        // gate or, worse, race past it. Force-fail them now so the TCPFlowRelay instances
        // tear down their NEAppProxyTCPFlow before reading another byte from the source app.
        stateLock.lock()
        socketFD = fd
        readBuffer.removeAll(keepingCapacity: true)
        let staleCloseHandlers = flowCloseHandlers
        let stalePendingOpens = openCompletions
        flowCloseHandlers.removeAll()
        flowDeliverHandlers.removeAll()
        openCompletions.removeAll()
        stateLock.unlock()

        if !staleCloseHandlers.isEmpty || !stalePendingOpens.isEmpty {
            Self.log.notice(
                "relay client: reconnect-reset invalidated \(staleCloseHandlers.count) flow(s), \(stalePendingOpens.count) pending open(s)"
            )
        }
        for (_, comp) in stalePendingOpens { comp(false) }
        for (_, handler) in staleCloseHandlers { handler("tunnel relay server reconnected") }

        installReadSource(for: fd)
        Self.log.notice("relay client: connected fd=\(fd) path=\(path)")
        return true
    }

    private func installReadSource(for fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.drainSocket() }
        src.setCancelHandler { close(fd) }
        src.resume()

        stateLock.lock()
        readSource = src
        writeSource?.cancel()  // defensive: drop any source still armed from a prior connection
        writeSource = nil
        writeBuffer.removeAll(keepingCapacity: true)
        writeOffset = 0
        stateLock.unlock()
    }

    private func drainSocket() {
        stateLock.lock()
        let fd = socketFD
        stateLock.unlock()
        guard fd >= 0 else { return }

        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBufferPointer { buf in
            read(fd, buf.baseAddress, buf.count)
        }
        if n == 0 {
            Self.log.notice("relay client: server EOF")
            tearDown(reason: "server EOF")
            return
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            Self.log.error("relay client: read errno=\(errno)")
            tearDown(reason: "read errno \(errno)")
            return
        }
        stateLock.lock()
        readBuffer.append(chunk, count: n)
        stateLock.unlock()
        consumeFrames()
    }

    private func consumeFrames() {
        // Parse every complete frame in one pass under the lock, advancing an O(1) slice cursor
        // (parse is startIndex-aware), then compact the buffer once. The previous per-frame
        // `removeFirst(used)` memmoved the remaining bytes down once per frame — O(frames·bytes)
        // for a single 64 KiB read full of small frames. Decoded frames own copies of their
        // payloads, so dispatching after the compaction is safe.
        stateLock.lock()
        var consumed = 0
        var frames: [RelayWireFrame.Frame] = []
        var malformedReason: String?
        parseLoop: while true {
            let result = RelayWireFrame.parse(readBuffer[(readBuffer.startIndex + consumed)...])
            switch result {
            case let .frame(frame, used):
                frames.append(frame)
                consumed += used
            case .needMoreData:
                break parseLoop
            case let .malformed(reason):
                malformedReason = reason
                break parseLoop
            }
        }
        if consumed > 0 {
            readBuffer.removeFirst(consumed)
        }
        stateLock.unlock()
        for frame in frames {
            handle(frame: frame)
        }
        if let malformedReason {
            // No resync is possible past a bad frame — fail the link closed and reconnect
            // rather than waiting forever on an unparseable stream.
            Self.log.error("relay client: malformed frame (\(malformedReason)) — resetting link")
            tearDown(reason: "malformed frame: \(malformedReason)")
        }
    }

    private func handle(frame: RelayWireFrame.Frame) {
        switch frame {
        case let .openFlowReply(reqID, ok, err):
            stateLock.lock()
            let comp = openCompletions.removeValue(forKey: reqID)
            stateLock.unlock()
            if !ok, let err {
                Self.log.error("[APPSPLIT_RELAY] openFlow reply error reqID=\(reqID): \(err)")
            }
            comp?(ok)
        case let .deliverPayloadPush(flowID, payload):
            stateLock.lock()
            let handler = flowDeliverHandlers[flowID]
            stateLock.unlock()
            Self.log.debug("[APPSPLIT_RELAY] deliverPayload flowID=\(flowID) len=\(payload.count)")
            handler?(payload)
        case let .flowClosedPush(flowID, err):
            stateLock.lock()
            let handler = flowCloseHandlers.removeValue(forKey: flowID)
            flowDeliverHandlers.removeValue(forKey: flowID)
            stateLock.unlock()
            handler?(err)
        case .openFlowRequest, .sendPayloadRequest, .closeFlowRequest:
            Self.log.error("relay client received unexpected server->client request frame")
        }
    }

    /// `flowID` (payload sends only): re-checked against `flowCloseHandlers` under the lock at
    /// write time. The caller's registration check runs on its own thread, so a tearDown+reconnect
    /// landing between that check and this block could otherwise ship a stale flowID to the fresh
    /// server — a narrow re-opening of the stale-flow retry cascade.
    private func writeFrame(_ data: Data, flowID: UInt64? = nil, completion: ((Bool) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { completion?(false); return }
            self.stateLock.lock()
            guard self.socketFD >= 0 else {
                self.stateLock.unlock()
                completion?(false)
                return
            }
            if let flowID, self.flowCloseHandlers[flowID] == nil {
                self.stateLock.unlock()
                completion?(false)
                return
            }
            self.writeBuffer.append(data)
            let teardownReason = self.drainWriteBufferLocked()
            // Backpressure: this frame's bytes are already buffered; we gate only the NEXT read. Hold
            // the completion while congested so the caller's read loop pauses; otherwise fire it now.
            // Also release any previously-held completions if this drain dropped us below low-water.
            var fireNow: ((Bool) -> Void)?
            var resumable: [(Bool) -> Void] = []
            if teardownReason == nil {
                if let completion {
                    if self.pendingWriteBytesLocked >= Self.writeHighWater {
                        self.pausedSendCompletions.append(completion)
                    } else {
                        fireNow = completion
                    }
                }
                resumable = self.takeResumableCompletionsLocked()
            }
            self.stateLock.unlock()
            if let teardownReason {
                self.tearDown(reason: teardownReason)
                completion?(false)
                return
            }
            // Fire outside the lock — these completions re-enter the relay (read next chunk → sendPayload).
            fireNow?(true)
            for c in resumable { c(true) }
        }
    }

    /// Completions to release now that the buffer has drained below the low-water mark. Empty unless
    /// we're below `writeLowWater`, so the high/low hysteresis avoids thrashing read pause/resume.
    /// Precondition: `stateLock` held.
    private func takeResumableCompletionsLocked() -> [(Bool) -> Void] {
        guard pendingWriteBytesLocked < Self.writeLowWater, !pausedSendCompletions.isEmpty else { return [] }
        let c = pausedSendCompletions
        pausedSendCompletions.removeAll()
        return c
    }

    /// Fires when the socket becomes writable after a prior EAGAIN. Drains whatever's buffered.
    private func flushWrite() {
        stateLock.lock()
        let teardownReason = drainWriteBufferLocked()
        let resumable = teardownReason == nil ? takeResumableCompletionsLocked() : []
        stateLock.unlock()
        if let teardownReason { tearDown(reason: teardownReason) }
        // Buffer just drained on the socket becoming writable — release held send completions so the
        // paused flow read-loops resume reading the source app.
        for c in resumable { c(true) }
    }

    /// Writes as much of `writeBuffer` as the kernel accepts. On EAGAIN it arms the write source and
    /// returns; once fully drained it disarms it. Returns a teardown reason on a fatal write error
    /// (caller must `tearDown` *after* releasing `stateLock` — `tearDown` re-acquires it).
    /// Precondition: `stateLock` held.
    private func drainWriteBufferLocked() -> String? {
        guard socketFD >= 0 else { return nil }
        let fd = socketFD
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
                } else if writeOffset >= Self.writeLowWater {
                    writeBuffer.removeFirst(writeOffset)
                    writeOffset = 0
                }
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if pendingWriteBytesLocked > Self.maxWriteBuffer {
                    return "write buffer overflow \(pendingWriteBytesLocked)B — peer not draining"
                }
                armWriteSourceLocked(fd: fd)
                return nil
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return "write errno \(errno)"
            }
        }
        disarmWriteSourceLocked()
        return nil
    }

    /// Bytes buffered but not yet accepted by the kernel. Precondition: `stateLock` held.
    private var pendingWriteBytesLocked: Int { writeBuffer.count - writeOffset }

    /// Arms an on-demand write source (resumed immediately) so we get a callback when the socket is
    /// writable again. Cancelled in `disarmWriteSourceLocked` once drained — so it is never held
    /// suspended (which would trap on release). Precondition: `stateLock` held.
    private func armWriteSourceLocked(fd: Int32) {
        guard writeSource == nil else { return }  // already armed
        let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
        ws.setEventHandler { [weak self] in self?.flushWrite() }
        writeSource = ws
        ws.resume()
    }

    /// Precondition: `stateLock` held.
    private func disarmWriteSourceLocked() {
        guard let ws = writeSource else { return }
        ws.cancel()  // resumed → safe to release
        writeSource = nil
    }

    private func tearDown(reason: String) {
        stateLock.lock()
        guard socketFD >= 0 || readSource != nil || writeSource != nil else {
            stateLock.unlock()
            return  // already torn down — keep this idempotent (callers include the open watchdog)
        }
        Self.log.notice("relay client: tearing down — \(reason)")
        let src = readSource
        readSource = nil
        let wsrc = writeSource
        writeSource = nil
        socketFD = -1
        let pendingOpens = openCompletions
        openCompletions.removeAll()
        let closeHandlers = flowCloseHandlers
        flowCloseHandlers.removeAll()
        flowDeliverHandlers.removeAll()
        let heldSends = pausedSendCompletions
        pausedSendCompletions.removeAll()
        readBuffer.removeAll(keepingCapacity: true)
        writeBuffer.removeAll(keepingCapacity: true)
        writeOffset = 0
        stateLock.unlock()

        src?.cancel()
        wsrc?.cancel()  // armed sources are always resumed → safe to release
        for (_, comp) in pendingOpens {
            comp(false)
        }
        // Fail any backpressure-held send completions closed so their flows tear down rather than hang.
        for comp in heldSends {
            comp(false)
        }
        for (_, handler) in closeHandlers {
            handler(reason)
        }
    }
}

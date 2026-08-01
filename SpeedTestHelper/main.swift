import Foundation

// NDJSON writer. FileHandle.write is unbuffered, so each event line reaches the host pipe
// immediately (stdout through a pipe is otherwise fully buffered). The lock serializes
// writes from the engine's session queues.
private let emitLock = NSLock()
private func emit(_ line: SpeedTestHelperLine) {
    emitLock.lock()
    defer { emitLock.unlock() }
    guard let encoded = line.encodedLine() else { return }
    FileHandle.standardOutput.write(Data((encoded + "\n").utf8))
}

private func usageExit() -> Never {
    FileHandle.standardError.write(Data("usage: SpeedTestHelper run | probe --mode warmup|recheck --phase full_tunnel|app_tunnel\n".utf8))
    exit(64)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run":
    do {
        let payload = try await SpeedTestEngine().run { event in
            switch event {
            case .phase(let phase):
                emit(SpeedTestHelperLine(event: "phase", phase: phase))
            case .sample(let readout, let offsetSeconds, let bytes):
                emit(SpeedTestHelperLine(event: "sample", readout: readout, offsetSeconds: offsetSeconds, bytes: bytes))
            }
        }
        emit(SpeedTestHelperLine(event: "result", result: payload))
        exit(0)
    } catch {
        emit(SpeedTestHelperLine(event: "error", message: error.localizedDescription))
        exit(1)
    }
case "probe":
    var mode: String?
    var phaseRaw: String?
    var rest = arguments.dropFirst().makeIterator()
    while let flag = rest.next() {
        switch flag {
        case "--mode": mode = rest.next()
        case "--phase": phaseRaw = rest.next()
        default: usageExit()
        }
    }
    guard let mode, ["warmup", "recheck"].contains(mode),
          let phase = TunnelProbePhase(rawValue: phaseRaw ?? "")
    else { usageExit() }
    let result = mode == "warmup"
        ? await TunnelConnectivityProbe.warmup(phase: phase)
        : await TunnelConnectivityProbe.recheck(phase: phase)
    let outcome: SpeedTestHelperProbeOutcome = switch result {
    case .ok: SpeedTestHelperProbeOutcome(ok: true)
    case .failed(let message): SpeedTestHelperProbeOutcome(ok: false, message: message)
    case .unknown: SpeedTestHelperProbeOutcome(ok: false, message: "probe returned no result")
    }
    if let data = try? JSONEncoder().encode(outcome), let s = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    exit(0)
default:
    usageExit()
}

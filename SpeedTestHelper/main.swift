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
    FileHandle.standardError.write(Data("usage: SpeedTestHelper run\n".utf8))
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
default:
    usageExit()
}

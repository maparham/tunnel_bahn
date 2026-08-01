import XCTest
@testable import TunnelBahn

final class SpeedTestHelperClientTests: XCTestCase {
    private func line(_ l: SpeedTestHelperLine) -> String { l.encodedLine()! }

    func testPhaseLineEmitsEventAndNoPayload() throws {
        var events: [SpeedTestEngineEvent] = []
        let payload = try SpeedTestHelperClient.reduce(
            line: line(SpeedTestHelperLine(event: "phase", phase: .download))
        ) { events.append($0) }
        XCTAssertNil(payload)
        XCTAssertEqual(events, [.phase(.download)])
    }

    func testSampleLineEmitsEvent() throws {
        var events: [SpeedTestEngineEvent] = []
        _ = try SpeedTestHelperClient.reduce(
            line: line(SpeedTestHelperLine(event: "sample", readout: "312 Mbps", offsetSeconds: 1.0, bytes: 1000))
        ) { events.append($0) }
        XCTAssertEqual(events, [.sample(readout: "312 Mbps", offsetSeconds: 1.0, bytes: 1000)])
    }

    func testResultLineReturnsPayload() throws {
        let expected = SpeedTestRunPayload(
            downloadMbps: 500, uploadMbps: 90, medianLatencyMs: 20, jitterMs: 2,
            downloadSamples: [], uploadSamples: []
        )
        let payload = try SpeedTestHelperClient.reduce(
            line: line(SpeedTestHelperLine(event: "result", result: expected))
        ) { _ in }
        XCTAssertEqual(payload, expected)
    }

    func testErrorLineThrowsWithHelperMessage() {
        XCTAssertThrowsError(
            try SpeedTestHelperClient.reduce(
                line: line(SpeedTestHelperLine(event: "error", message: "server rejected the request (HTTP 403)"))
            ) { _ in }
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "server rejected the request (HTTP 403)"
            )
        }
    }

    func testMalformedLineThrows() {
        XCTAssertThrowsError(try SpeedTestHelperClient.reduce(line: "not json") { _ in })
    }

    func testUnknownEventThrows() {
        XCTAssertThrowsError(
            try SpeedTestHelperClient.reduce(line: #"{"event":"mystery"}"#) { _ in }
        )
    }

    func testResultLineWithoutPayloadThrows() {
        XCTAssertThrowsError(
            try SpeedTestHelperClient.reduce(line: #"{"event":"result"}"#) { _ in }
        )
    }
}

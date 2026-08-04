import XCTest
@testable import TunnelBahn

final class SpeedTestHelperProtocolTests: XCTestCase {
    func testPhaseLineRoundTrip() throws {
        let line = SpeedTestHelperLine(event: "phase", phase: .download)
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertFalse(encoded.contains("\n"))
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded), line)
    }

    func testSampleLineRoundTrip() throws {
        let line = SpeedTestHelperLine(event: "sample", readout: "312 Mbps", offsetSeconds: 1.25, bytes: 52_428_800)
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded), line)
    }

    func testResultLineRoundTrip() throws {
        let payload = SpeedTestRunPayload(
            downloadMbps: 512.5,
            uploadMbps: 96.25,
            medianLatencyMs: 24,
            jitterMs: 2.5,
            downloadSamples: [ThroughputSample(offsetSeconds: 0.25, mbps: 480)],
            uploadSamples: [ThroughputSample(offsetSeconds: 0.25, mbps: 90)],
            exitIP: "203.0.113.7",
            exitLocation: "Frankfurt, Hesse, Germany"
        )
        let line = SpeedTestHelperLine(event: "result", result: payload)
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded)?.result, payload)
    }

    func testExitIPLineRoundTrip() throws {
        let line = SpeedTestHelperLine(event: "exit_ip", exitIP: "203.0.113.7", exitLocation: "Frankfurt, Hesse, Germany")
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded), line)
    }

    func testErrorLineRoundTrip() throws {
        let line = SpeedTestHelperLine(event: "error", message: "server rejected the request (HTTP 403)")
        let encoded = try XCTUnwrap(line.encodedLine())
        XCTAssertEqual(SpeedTestHelperLine.decode(encoded), line)
    }

    func testDecodeMalformedLineReturnsNil() {
        XCTAssertNil(SpeedTestHelperLine.decode("not json"))
        XCTAssertNil(SpeedTestHelperLine.decode("{\"phase\":\"download\"}")) // missing required `event`
    }
}

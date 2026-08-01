import XCTest
@testable import TunnelBahn

final class SpeedTestEngineTests: XCTestCase {
    // Upload accounting credits only server-acknowledged completed bodies, so body sizes
    // must ramp: small enough that slow paths complete several per window, growing so fast
    // paths are not request-rate bound.
    func testUploadLadderStartsSmall() {
        XCTAssertEqual(SpeedTestEngine.initialUploadBodyBytes, 256 * 1024)
    }

    func testUploadLadderRampsThroughSizes() {
        XCTAssertEqual(SpeedTestEngine.nextUploadBodyBytes(after: 256 * 1024), 1024 * 1024)
        XCTAssertEqual(SpeedTestEngine.nextUploadBodyBytes(after: 1024 * 1024), 4 * 1024 * 1024)
        XCTAssertEqual(SpeedTestEngine.nextUploadBodyBytes(after: 4 * 1024 * 1024), 16 * 1024 * 1024)
    }

    func testUploadLadderCapsAtLargestSize() {
        XCTAssertEqual(SpeedTestEngine.nextUploadBodyBytes(after: 16 * 1024 * 1024), 16 * 1024 * 1024)
    }

    func testUploadLadderClimbsFromUnalignedSize() {
        XCTAssertEqual(SpeedTestEngine.nextUploadBodyBytes(after: 12345), 256 * 1024)
    }

    // High-RTT paths spend much of a fixed 8 s window in TCP slow start; the window
    // extends so ramp-up does not dominate the average.
    func testTransferWindowStaysShortOnLowLatency() {
        XCTAssertEqual(SpeedTestEngine.transferWindowSeconds(forMedianLatencyMs: 50), 8.0)
        XCTAssertEqual(SpeedTestEngine.transferWindowSeconds(forMedianLatencyMs: 399.9), 8.0)
    }

    func testTransferWindowExtendsOnHighLatency() {
        XCTAssertEqual(SpeedTestEngine.transferWindowSeconds(forMedianLatencyMs: 400), 16.0)
        XCTAssertEqual(SpeedTestEngine.transferWindowSeconds(forMedianLatencyMs: 1200), 16.0)
    }
}

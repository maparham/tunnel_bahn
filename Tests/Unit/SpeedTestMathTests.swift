import XCTest

final class SpeedTestMathTests: XCTestCase {
    // MARK: - median

    func testMedianOddCount() {
        XCTAssertEqual(SpeedTestMath.median([30, 10, 20]), 20)
    }

    func testMedianEvenCountAveragesMiddlePair() {
        XCTAssertEqual(SpeedTestMath.median([10, 20, 30, 40]), 25)
    }

    func testMedianEmptyReturnsNil() {
        XCTAssertNil(SpeedTestMath.median([]))
    }

    // MARK: - jitter (mean absolute deviation from the median)

    func testJitterMeanAbsoluteDeviationFromMedian() {
        // median = 20; deviations 10, 0, 10 -> mean 20/3
        XCTAssertEqual(SpeedTestMath.jitter([10, 20, 30])!, 20.0 / 3.0, accuracy: 1e-9)
    }

    func testJitterSingleSampleIsZero() {
        XCTAssertEqual(SpeedTestMath.jitter([42]), 0)
    }

    func testJitterEmptyReturnsNil() {
        XCTAssertNil(SpeedTestMath.jitter([]))
    }

    // MARK: - throughput

    func testThroughputMbps() {
        // 1_000_000 bytes in 2 s = 4 Mbps
        XCTAssertEqual(SpeedTestMath.throughputMbps(bytes: 1_000_000, seconds: 2), 4)
    }

    func testThroughputZeroSecondsIsZero() {
        XCTAssertEqual(SpeedTestMath.throughputMbps(bytes: 1_000_000, seconds: 0), 0)
    }

    // MARK: - throughput series

    func testThroughputSeriesDerivesPerIntervalRates() {
        let series = SpeedTestMath.throughputSeries(cumulative: [
            (offsetSeconds: 0.25, bytes: 250_000),
            (offsetSeconds: 0.50, bytes: 750_000),
        ])
        XCTAssertEqual(series.count, 2)
        // First interval: 250_000 B over 0.25 s = 8 Mbps
        XCTAssertEqual(series[0], ThroughputSample(offsetSeconds: 0.25, mbps: 8))
        // Second interval: 500_000 B over 0.25 s = 16 Mbps
        XCTAssertEqual(series[1], ThroughputSample(offsetSeconds: 0.50, mbps: 16))
    }

    func testThroughputSeriesSkipsNonPositiveIntervals() {
        let series = SpeedTestMath.throughputSeries(cumulative: [
            (offsetSeconds: 0.25, bytes: 250_000),
            (offsetSeconds: 0.25, bytes: 300_000),
        ])
        XCTAssertEqual(series.count, 1)
    }

    // MARK: - delta

    func testDeltaPercent() {
        // tunnel 60 vs direct 100 -> -40%
        XCTAssertEqual(SpeedTestMath.deltaPercent(tunnel: 60, direct: 100), -40)
    }

    func testDeltaPercentNilWhenDirectIsZero() {
        XCTAssertNil(SpeedTestMath.deltaPercent(tunnel: 60, direct: 0))
    }
}

import Foundation

/// Pure math for the speed test: no networking, no state. Unit-tested in SpeedTestMathTests.
enum SpeedTestMath {
    /// Standard median; even counts average the middle pair. Nil for empty input.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Jitter as mean absolute deviation from the median. Nil for empty input.
    static func jitter(_ values: [Double]) -> Double? {
        guard let median = median(values) else { return nil }
        let deviations = values.map { abs($0 - median) }
        return deviations.reduce(0, +) / Double(deviations.count)
    }

    /// Megabits per second from a byte count over a wall-clock window. Zero for a non-positive window.
    static func throughputMbps(bytes: Int, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// Converts cumulative (time, bytes) snapshots into per-interval instantaneous rates.
    /// The first interval is measured from (0, 0). Snapshots that do not advance time are skipped.
    static func throughputSeries(
        cumulative: [(offsetSeconds: Double, bytes: Int)]
    ) -> [ThroughputSample] {
        var samples: [ThroughputSample] = []
        var lastTime = 0.0
        var lastBytes = 0
        for point in cumulative {
            let dt = point.offsetSeconds - lastTime
            guard dt > 0 else { continue }
            let mbps = throughputMbps(bytes: point.bytes - lastBytes, seconds: dt)
            samples.append(ThroughputSample(offsetSeconds: point.offsetSeconds, mbps: mbps))
            lastTime = point.offsetSeconds
            lastBytes = point.bytes
        }
        return samples
    }

    /// Signed percentage change of the tunnel value relative to the direct baseline.
    /// Nil when the baseline is zero (undefined).
    static func deltaPercent(tunnel: Double, direct: Double) -> Double? {
        guard direct != 0 else { return nil }
        return (tunnel - direct) / direct * 100
    }
}

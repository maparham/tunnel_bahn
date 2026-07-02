import Foundation
import Darwin

/// Samples this process's CPU and resident memory accurately and exposes a smoothed value.
///
/// CPU is measured the same way Activity Monitor reports it: the *delta* of total consumed
/// CPU time (user + system, across both live and already-terminated threads) divided by the
/// actual wall-clock time elapsed since the previous sample. The instantaneous
/// `thread_info`/`cpu_usage` field is deliberately avoided because it is a short kernel load
/// average that systematically under-reports bursty workloads relative to Activity Monitor.
///
/// Each `sample()` then folds the raw reading through an exponential moving average so the UI
/// gets a stable number instead of inter-sample jitter. One instance lives per process (the
/// host app and each extension keep their own), because the time-delta math needs state
/// carried between consecutive calls.
///
/// Not thread-safe: call `sample()` from a single serial context (the owning timer/loop).
final class ProcessResourceSampler {
    struct Sample {
        /// Smoothed CPU percentage. May exceed 100% on multi-core machines (matches Activity Monitor).
        let cpuPercent: Double
        /// Smoothed resident memory in bytes.
        let memoryBytes: UInt64
    }

    /// EMA weight applied to each new raw reading. Lower = smoother but laggier.
    /// 0.35 settles a step change in ~6 samples while still tracking real movement quickly.
    private let smoothingFactor: Double

    private var previousCPUTime: TimeInterval?
    private var previousTimestamp: TimeInterval?

    private var smoothedCPU: Double?
    private var smoothedMemory: Double?

    init(smoothingFactor: Double = 0.35) {
        self.smoothingFactor = min(max(smoothingFactor, 0.01), 1.0)
    }

    /// Reads the process, updates the moving averages, and returns the smoothed result.
    @discardableResult
    func sample() -> Sample {
        let rawMemory = Self.readResidentMemoryBytes()
        let rawCPU = readCPUPercent()

        let cpu = blend(previous: smoothedCPU, raw: rawCPU)
        let memory = blend(previous: smoothedMemory, raw: Double(rawMemory))
        smoothedCPU = cpu
        smoothedMemory = memory

        return Sample(cpuPercent: cpu, memoryBytes: UInt64(max(0, memory.rounded())))
    }

    /// First sample seeds the average directly so we don't ramp up from zero.
    private func blend(previous: Double?, raw: Double) -> Double {
        guard let previous else { return raw }
        return previous + smoothingFactor * (raw - previous)
    }

    // MARK: - Raw readings

    /// Total CPU consumed since the previous call, as a percentage of one core, over the real
    /// elapsed interval. Returns 0 for the first call (no prior reference point) and whenever
    /// the kernel calls fail.
    private func readCPUPercent() -> Double {
        guard let totalCPUTime = Self.readTotalCPUTimeSeconds() else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime

        defer {
            previousCPUTime = totalCPUTime
            previousTimestamp = now
        }

        guard let lastCPU = previousCPUTime, let lastTime = previousTimestamp else {
            return 0 // No baseline yet; first reading establishes it.
        }

        let elapsed = now - lastTime
        guard elapsed > 0 else { return 0 }

        let cpuDelta = totalCPUTime - lastCPU
        guard cpuDelta > 0 else { return 0 }

        return (cpuDelta / elapsed) * 100.0
    }

    /// Sum of user + system CPU time for the whole task: time accumulated by threads that have
    /// already terminated (`task_basic_info`) plus time consumed by currently-live threads
    /// (`TASK_THREAD_TIMES_INFO`). This pair is what yields Activity-Monitor-equivalent totals.
    private static func readTotalCPUTimeSeconds() -> TimeInterval? {
        let task = mach_task_self_

        var basicInfo = task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let basicResult = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(task, task_flavor_t(TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { return nil }

        var threadTimes = task_thread_times_info()
        var threadCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.stride / MemoryLayout<natural_t>.stride)
        let threadResult = withUnsafeMutablePointer(to: &threadTimes) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) {
                task_info(task, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &threadCount)
            }
        }
        guard threadResult == KERN_SUCCESS else { return nil }

        return seconds(basicInfo.user_time)
            + seconds(basicInfo.system_time)
            + seconds(threadTimes.user_time)
            + seconds(threadTimes.system_time)
    }

    private static func seconds(_ t: time_value_t) -> TimeInterval {
        TimeInterval(t.seconds) + TimeInterval(t.microseconds) / 1_000_000.0
    }

    private static func readResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}

import Foundation
import Darwin

/// Samples this process's CPU and resident memory on a fixed interval for UI display.
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsage: UInt64 = 0

    private var refreshTask: Task<Void, Never>?
    private static let sampleInterval: Duration = .seconds(2)

    init() {
        sample()
        start()
    }

    deinit {
        refreshTask?.cancel()
    }

    func start() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.sample()
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    private func sample() {
        memoryUsage = Self.readResidentMemoryBytes()
        cpuUsage = Self.readCPUUsagePercent()
    }

    private static func readResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    /// Sum of non-idle thread `cpu_usage` values (may exceed 100% on multi-core systems).
    private static func readCPUUsagePercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let task = mach_task_self_
        guard task_threads(task, &threadList, &threadCount) == KERN_SUCCESS, let threads = threadList else {
            return 0
        }
        defer {
            let address = vm_address_t(UInt(bitPattern: threads))
            let byteCount = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(task, address, byteCount)
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            if threadInfo.flags & Int32(TH_FLAGS_IDLE) == 0 {
                total += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }
}

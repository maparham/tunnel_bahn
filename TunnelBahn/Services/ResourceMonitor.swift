import Foundation

/// Samples this process's CPU and resident memory on a fixed interval for UI display.
///
/// Measurement and smoothing live in `ProcessResourceSampler`: CPU is an Activity-Monitor-
/// equivalent time-delta reading, fed through a moving average so the displayed value is
/// stable rather than jumpy. The first sample needs a prior reference point, so the very
/// first interval reports 0 until the second tick lands.
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsage: UInt64 = 0

    private let sampler = ProcessResourceSampler()
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
        let result = sampler.sample()
        cpuUsage = result.cpuPercent
        memoryUsage = result.memoryBytes
    }
}

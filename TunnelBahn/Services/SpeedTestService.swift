import Combine
import Foundation

/// Full-suite speed test (latency, jitter, download, upload) against Cloudflare's speed-test
/// endpoints, measuring whatever path TunnelBahn's own traffic currently takes. Owned by
/// AppState so a run survives tab switches; SpeedTestView only observes it.
@MainActor
final class SpeedTestService: ObservableObject {
    enum Phase: Equatable {
        case idle, latency, download, upload
    }

    @Published private(set) var phase: Phase = .idle
    /// In-flight run data for the UI, filled in as events arrive; nil while idle.
    /// `LiveTransfer.mbps` is the whole-window average so far, so it converges to the
    /// final figure; `samples` are per-interval instantaneous rates for the live chart.
    struct LiveRunData {
        /// Ticking text during the latency phase ("24 ms"); superseded by `latencyMs`.
        var latencyReadout: String?
        var latencyMs: Double?
        var jitterMs: Double?
        var download: LiveTransfer?
        var upload: LiveTransfer?

        struct LiveTransfer {
            var mbps: Double
            var samples: [ThroughputSample]
        }
    }

    @Published private(set) var liveRun: LiveRunData?
    @Published private(set) var errorMessage: String?
    /// Non-error notices, e.g. auto-cancel on path change.
    @Published private(set) var statusNote: String?
    @Published private(set) var tunnelResult: SpeedTestResult?
    @Published private(set) var directResult: SpeedTestResult?
    /// Path captured when the active run started; nil while idle. Lets the UI attribute the
    /// running state (progress, Cancel) to the card whose test is running.
    @Published private(set) var runningPath: SpeedTestPath?

    private let vpnManager: VPNManager
    private let profileStore: ProfileStore
    private var runTask: Task<Void, Never>?
    /// Cumulative (offset, bytes) points of the transfer phase currently running; reset on
    /// each phase event. Kept host-side so live charts work identically for helper runs.
    private var transferCumulative: [(offsetSeconds: Double, bytes: Int)] = []
    private var cancellables: Set<AnyCancellable> = []

    private static let log = AppLog(subsystem: "com.tunnelbahn.mac", category: "SpeedTest")

    var isRunning: Bool { phase != .idle }

    /// Whether the given card's Run button should be enabled. Tunnel runs go through the
    /// bundled helper, so they only need a connected tunnel that routes internet traffic
    /// (default-route profile, no destination split). Direct runs go through the host app,
    /// so they need the host's own path to be direct.
    func canRun(_ path: SpeedTestPath) -> Bool {
        guard !isRunning else { return false }
        let stats = vpnManager.stats
        switch path {
        case .tunnel:
            return stats.state == .connected && stats.tunnelHasDefaultRoute
        case .direct:
            return stats.state != .connected || !stats.hostAppInternetPathIsTunnel
        }
    }

    /// Connected profile name, for labeling tunnel results.
    private var connectedProfileName: String? {
        guard let id = vpnManager.stats.connectedProfileID else { return nil }
        return profileStore.profiles.first(where: { $0.id == id })?.name
    }

    init(vpnManager: VPNManager, profileStore: ProfileStore) {
        self.vpnManager = vpnManager
        self.profileStore = profileStore

        // A mid-run path change (connect, disconnect, reassert) invalidates the measurement:
        // the slot the run started for is no longer the path being measured.
        // This sink is also load-bearing for app quit: the quit flow disconnects first, and the
        // resulting path change here is what cancels runTask and terminates a running helper process.
        struct PathSignature: Equatable {
            let state: VPNConnectionState
            let isTunnel: Bool
            let tunnelHasDefaultRoute: Bool
        }
        vpnManager.$stats
            .map { PathSignature(state: $0.state, isTunnel: $0.hostAppInternetPathIsTunnel, tunnelHasDefaultRoute: $0.tunnelHasDefaultRoute) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                Self.log.notice("[APPSPLIT_SPEEDTEST] cancelled: traffic path changed mid-run")
                self.statusNote = "Test cancelled: traffic path changed"
                self.runTask?.cancel()
            }
            .store(in: &cancellables)
    }

    func run(path: SpeedTestPath) {
        guard canRun(path) else { return }
        // Set the phase synchronously: `isRunning` derives from `phase`, and it is only observed
        // after the spawned Task starts, so two back-to-back `run` calls could both pass the
        // guard and start duplicate runs.
        phase = .latency
        errorMessage = nil
        statusNote = nil
        runningPath = path
        liveRun = LiveRunData()
        let profileName = path == .tunnel ? connectedProfileName : nil
        Self.log.notice("[APPSPLIT_SPEEDTEST] run begin path=\(path.rawValue) mechanism=\(path == .tunnel ? "helper" : "in-process")")
        runTask = Task { [weak self] in
            await self?.performRun(path: path, profileName: profileName)
        }
    }

    func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
    }

    // MARK: - Run pipeline

    private func performRun(path: SpeedTestPath, profileName: String?) async {
        defer {
            phase = .idle
            liveRun = nil
            transferCumulative = []
            runTask = nil
            runningPath = nil
        }
        do {
            let onEvent: @Sendable (SpeedTestEngineEvent) -> Void = { [weak self] event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            let payload: SpeedTestRunPayload
            switch path {
            case .tunnel:
                payload = try await SpeedTestHelperClient().run(onEvent: onEvent)
            case .direct:
                payload = try await SpeedTestEngine().run(onEvent: onEvent)
            }
            let result = SpeedTestResult(
                path: path,
                profileName: profileName,
                downloadMbps: payload.downloadMbps,
                uploadMbps: payload.uploadMbps,
                medianLatencyMs: payload.medianLatencyMs,
                jitterMs: payload.jitterMs,
                finishedAt: Date(),
                downloadSamples: payload.downloadSamples,
                uploadSamples: payload.uploadSamples
            )
            switch path {
            case .tunnel: tunnelResult = result
            case .direct: directResult = result
            }
            Self.log.notice(
                "[APPSPLIT_SPEEDTEST] run ok path=\(path.rawValue) down=\(Int(result.downloadMbps))Mbps up=\(Int(result.uploadMbps))Mbps latency=\(Int(result.medianLatencyMs))ms"
            )
        } catch is CancellationError {
            Self.log.notice("[APPSPLIT_SPEEDTEST] run cancelled path=\(path.rawValue)")
        } catch {
            Self.log.notice("[APPSPLIT_SPEEDTEST] run failed path=\(path.rawValue) error=\(error.localizedDescription)")
            errorMessage = "Speed test failed: \(error.localizedDescription)"
        }
    }

    /// Maps engine/helper progress events onto the published UI state. Ignores events
    /// arriving after the run ended (phase == .idle) so a late Task hop cannot resurrect UI.
    private func apply(_ event: SpeedTestEngineEvent) {
        guard phase != .idle || runningPath != nil else { return }
        switch event {
        case .phase(let name):
            transferCumulative = []
            switch name {
            case .latency: phase = .latency
            case .download: phase = .download
            case .upload: phase = .upload
            }
        case .latencySummary(let medianMs, let jitterMs):
            liveRun?.latencyMs = medianMs
            liveRun?.jitterMs = jitterMs
        case .sample(let readout, let offsetSeconds, let bytes):
            guard let offsetSeconds, let bytes else {
                liveRun?.latencyReadout = readout
                return
            }
            transferCumulative.append((offsetSeconds: offsetSeconds, bytes: bytes))
            let transfer = LiveRunData.LiveTransfer(
                mbps: SpeedTestMath.throughputMbps(bytes: bytes, seconds: offsetSeconds),
                samples: SpeedTestMath.throughputSeries(cumulative: transferCumulative)
            )
            switch phase {
            case .download: liveRun?.download = transfer
            case .upload: liveRun?.upload = transfer
            case .latency, .idle: break
            }
        }
    }
}

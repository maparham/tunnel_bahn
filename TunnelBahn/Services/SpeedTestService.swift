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
    /// Live number for the active phase, pre-formatted ("312 Mbps" / "24 ms").
    @Published private(set) var liveReadout: String?
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
    private var cancellables: Set<AnyCancellable> = []

    private static let log = AppLog(subsystem: "com.tunnelbahn.mac", category: "SpeedTest")

    var isRunning: Bool { phase != .idle }

    var currentPath: SpeedTestPath {
        let stats = vpnManager.stats
        return (stats.state == .connected && stats.hostAppInternetPathIsTunnel) ? .tunnel : .direct
    }

    /// Connected profile name when the current path is tunnel; nil otherwise.
    var currentPathProfileName: String? {
        guard currentPath == .tunnel, let id = vpnManager.stats.connectedProfileID else { return nil }
        return profileStore.profiles.first(where: { $0.id == id })?.name
    }

    init(vpnManager: VPNManager, profileStore: ProfileStore) {
        self.vpnManager = vpnManager
        self.profileStore = profileStore

        // A mid-run path change (connect, disconnect, reassert) invalidates the measurement:
        // the slot the run started for is no longer the path being measured.
        struct PathSignature: Equatable {
            let state: VPNConnectionState
            let isTunnel: Bool
        }
        vpnManager.$stats
            .map { PathSignature(state: $0.state, isTunnel: $0.hostAppInternetPathIsTunnel) }
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

    func run() {
        guard !isRunning else { return }
        // Set the phase synchronously: `isRunning` derives from `phase`, and it is only observed
        // after the spawned Task starts, so two back-to-back `run()` calls could both pass the
        // guard and start duplicate runs.
        phase = .latency
        errorMessage = nil
        statusNote = nil
        let path = currentPath
        runningPath = path
        let profileName = currentPathProfileName
        Self.log.notice("[APPSPLIT_SPEEDTEST] run begin path=\(path.rawValue)")
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
            liveReadout = nil
            runTask = nil
            runningPath = nil
        }
        do {
            let payload = try await SpeedTestEngine().run { [weak self] event in
                Task { @MainActor [weak self] in self?.apply(event) }
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
            switch name {
            case .latency: phase = .latency
            case .download: phase = .download
            case .upload: phase = .upload
            }
        case .sample(let readout, _, _):
            liveReadout = readout
        }
    }
}

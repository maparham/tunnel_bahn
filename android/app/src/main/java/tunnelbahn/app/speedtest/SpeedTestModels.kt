package tunnelbahn.app.speedtest

/** Which path a run measured. */
enum class SpeedTestPath { Tunnel, Direct }

/** Current phase of a run. */
enum class SpeedTestPhase { Idle, Latency, Download, Upload }

/** One point of the throughput-over-time curve (per-interval instantaneous rate). */
data class ThroughputSample(val offsetSeconds: Double, val mbps: Double)

/** A finished run. In-memory only; the latest per path is kept for the session. */
data class SpeedTestResult(
    val path: SpeedTestPath,
    val downloadMbps: Double,
    val uploadMbps: Double,
    val medianLatencyMs: Double,
    val jitterMs: Double,
    val finishedAtMs: Long,
    val downloadSamples: List<ThroughputSample>,
    val uploadSamples: List<ThroughputSample>,
)

/** Live transfer state during a run: whole-window average so far + the sparkline series. */
data class LiveTransfer(val mbps: Double, val samples: List<ThroughputSample>)

/** All speed-test UI state, published as a single immutable snapshot. */
data class SpeedTestUiState(
    val runningPath: SpeedTestPath?,
    val phase: SpeedTestPhase,
    val latencyReadout: String?,
    val latencyMs: Double?,
    val jitterMs: Double?,
    val download: LiveTransfer?,
    val upload: LiveTransfer?,
    val tunnelResult: SpeedTestResult?,
    val directResult: SpeedTestResult?,
    val errorMessage: String?,
) {
    val isRunning get() = phase != SpeedTestPhase.Idle

    companion object {
        val Idle = SpeedTestUiState(
            runningPath = null,
            phase = SpeedTestPhase.Idle,
            latencyReadout = null,
            latencyMs = null,
            jitterMs = null,
            download = null,
            upload = null,
            tunnelResult = null,
            directResult = null,
            errorMessage = null,
        )
    }
}

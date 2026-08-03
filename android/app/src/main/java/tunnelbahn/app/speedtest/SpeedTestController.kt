package tunnelbahn.app.speedtest

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import tunnelbahn.app.vpn.TunnelBahnVpnService
import tunnelbahn.mobile.DirectSpeedTest
import tunnelbahn.mobile.SpeedTestSink

/**
 * Drives speed-test runs and publishes UI state. Process-global (like the VPN state flow)
 * so a run survives navigation. The measurement runs in the Go core; this class implements
 * the gomobile [SpeedTestSink] and maps events onto [SpeedTestUiState].
 */
object SpeedTestController {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _state = MutableStateFlow(SpeedTestUiState.Idle)
    val state: StateFlow<SpeedTestUiState> = _state.asStateFlow()

    private var runJob: Job? = null
    private var watchJob: Job? = null
    // The gomobile handles captured at run start, so cancel() targets THIS run's objects even
    // after the service nulls its companion field on drop.
    private var tunnelSession: tunnelbahn.mobile.Session? = null
    private var directRun: DirectSpeedTest? = null
    // Monotonic run id; Sink callbacks for a stale run (after finish/cancel) are ignored.
    @Volatile private var generation = 0
    // Cumulative (offset, bytes) points for the transfer phase currently running.
    private val cumulative = ArrayList<Pair<Double, Long>>()

    fun canRun(path: SpeedTestPath): Boolean {
        if (_state.value.isRunning) return false
        return when (path) {
            SpeedTestPath.Tunnel ->
                TunnelBahnVpnService.state.value == TunnelBahnVpnService.STATE_RUNNING &&
                    TunnelBahnVpnService.activeSession != null
            SpeedTestPath.Direct -> true
        }
    }

    fun run(path: SpeedTestPath) {
        if (!canRun(path)) return
        // Capture the live session NOW; the companion field is nulled on a drop, but this run
        // still needs a handle to cancel through.
        val session = TunnelBahnVpnService.activeSession
        if (path == SpeedTestPath.Tunnel && session == null) return
        // Capture the run's cancel handle BEFORE the launch so cancel() (which may run on a
        // different thread) always sees a non-null handle for the path that is actually running.
        val direct = if (path == SpeedTestPath.Direct) DirectSpeedTest() else null
        tunnelSession = if (path == SpeedTestPath.Tunnel) session else null
        directRun = direct
        val gen = ++generation
        // Set running state synchronously so a second run() cannot pass canRun().
        cumulative.clear()
        _state.update {
            it.copy(
                runningPath = path,
                phase = SpeedTestPhase.Latency,
                latencyReadout = null,
                latencyMs = null,
                jitterMs = null,
                download = null,
                upload = null,
                errorMessage = null,
            )
        }
        val sink = Sink(path, gen)
        runJob = scope.launch(Dispatchers.IO) {
            try {
                when (path) {
                    SpeedTestPath.Tunnel -> session!!.runSpeedTest(sink)
                    SpeedTestPath.Direct -> direct!!.run(sink)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                // A cancel surfaces here too (Go returns context.Canceled, gomobile throws it);
                // treat that as silent, mirroring macOS's `catch is CancellationError`.
                val cancelled = e.message?.contains("context canceled", ignoreCase = true) == true
                if (!cancelled && gen == generation && _state.value.errorMessage == null) {
                    _state.update { it.copy(errorMessage = e.message) }
                }
            } finally {
                finish(gen)
            }
        }

        // Auto-cancel a tunnel run if the VPN leaves RUNNING mid-run. Scoped to this run and
        // cancelled in finish(), so it does not leak across runs.
        if (path == SpeedTestPath.Tunnel) {
            watchJob = scope.launch {
                TunnelBahnVpnService.state.collect { s ->
                    if (gen == generation && _state.value.runningPath == SpeedTestPath.Tunnel &&
                        s != TunnelBahnVpnService.STATE_RUNNING
                    ) {
                        _state.update { it.copy(errorMessage = "Test cancelled: tunnel dropped") }
                        cancel()
                    }
                }
            }
        }
    }

    fun cancel() {
        // Cancel the Go run first (it unblocks the parked JNI call), then the coroutines.
        tunnelSession?.cancelSpeedTest()
        directRun?.cancel()
        watchJob?.cancel()
        runJob?.cancel()
    }

    private fun finish(gen: Int) {
        if (gen != generation) return
        watchJob?.cancel()
        directRun = null
        tunnelSession = null
        _state.update {
            it.copy(runningPath = null, phase = SpeedTestPhase.Idle, download = null, upload = null, latencyReadout = null)
        }
    }

    /**
     * gomobile sink: callbacks arrive on a Go-owned thread; StateFlow.update is thread-safe.
     * Every callback is guarded by [gen] so a late event from a cancelled/finished run cannot
     * resurrect UI or write a stale result (mirrors macOS's `phase == .idle` guard in apply).
     */
    private class Sink(private val path: SpeedTestPath, private val gen: Int) : SpeedTestSink {
        override fun onPhase(name: String) {
            if (gen != generation) return
            cumulative.clear()
            val phase = when (name) {
                "latency" -> SpeedTestPhase.Latency
                "download" -> SpeedTestPhase.Download
                "upload" -> SpeedTestPhase.Upload
                else -> return
            }
            _state.update { it.copy(phase = phase) }
        }

        override fun onLatencySummary(medianMs: Double, jitterMs: Double) {
            if (gen != generation) return
            _state.update { it.copy(latencyMs = medianMs, jitterMs = jitterMs) }
        }

        override fun onSample(phase: String, offsetSeconds: Double, bytes: Long) {
            if (gen != generation) return
            if (phase == "latency") {
                // During latency, bytes carries the round-trip milliseconds (see engine).
                _state.update { it.copy(latencyReadout = "$bytes ms") }
                return
            }
            cumulative.add(offsetSeconds to bytes)
            val series = throughputSeries(cumulative.toList())
            val transfer = LiveTransfer(
                mbps = throughputMbps(bytes, offsetSeconds),
                samples = series,
            )
            _state.update {
                when (phase) {
                    "download" -> it.copy(download = transfer)
                    "upload" -> it.copy(upload = transfer)
                    else -> it
                }
            }
        }

        override fun onResult(downloadMbps: Double, uploadMbps: Double, medianLatencyMs: Double, jitterMs: Double) {
            if (gen != generation) return
            val result = SpeedTestResult(
                path = path,
                downloadMbps = downloadMbps,
                uploadMbps = uploadMbps,
                medianLatencyMs = medianLatencyMs,
                jitterMs = jitterMs,
                finishedAtMs = System.currentTimeMillis(),
                downloadSamples = _state.value.download?.samples ?: emptyList(),
                uploadSamples = _state.value.upload?.samples ?: emptyList(),
            )
            _state.update {
                when (path) {
                    SpeedTestPath.Tunnel -> it.copy(tunnelResult = result)
                    SpeedTestPath.Direct -> it.copy(directResult = result)
                }
            }
        }

        override fun onError(msg: String) {
            if (gen != generation) return
            // Do not overwrite an auto-cancel message already set by the watcher.
            _state.update { if (it.errorMessage != null) it else it.copy(errorMessage = "Speed test failed: $msg") }
        }
    }
}

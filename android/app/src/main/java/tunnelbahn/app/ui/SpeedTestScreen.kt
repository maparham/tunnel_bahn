package tunnelbahn.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import tunnelbahn.app.speedtest.DeltaSense
import tunnelbahn.app.speedtest.SpeedTestController
import tunnelbahn.app.speedtest.SpeedTestPath
import tunnelbahn.app.speedtest.SpeedTestPhase
import tunnelbahn.app.speedtest.SpeedTestResult
import tunnelbahn.app.speedtest.SpeedTestUiState
import tunnelbahn.app.speedtest.ThroughputSample
import tunnelbahn.app.speedtest.deltaPercent
import tunnelbahn.app.speedtest.deltaSense
import tunnelbahn.app.vpn.TunnelBahnVpnService
import java.util.Locale

private val DownloadColor = Color(0xFF2E7DF6)
private val UploadColor = Color(0xFF2FA84F)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SpeedTestScreen(onBack: () -> Unit) {
    val ui by SpeedTestController.state.collectAsStateWithLifecycle()
    // Observed so the Run button recomposes when the tunnel drops while idle on this screen.
    val vpnState by TunnelBahnVpnService.state.collectAsStateWithLifecycle()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Speed Test") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { pad ->
        Column(
            Modifier.padding(pad).padding(16.dp).fillMaxWidth().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            PathCard(ui, SpeedTestPath.Tunnel, vpnState)
            PathCard(ui, SpeedTestPath.Direct, vpnState)
            ComparisonStrip(ui.tunnelResult, ui.directResult)
            ui.errorMessage?.let {
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
            }
        }
    }
}

@Composable
private fun PathCard(ui: SpeedTestUiState, path: SpeedTestPath, vpnState: String) {
    val title = if (path == SpeedTestPath.Tunnel) "Tunnel" else "Direct"
    val result = if (path == SpeedTestPath.Tunnel) ui.tunnelResult else ui.directResult
    val isThisRunning = ui.runningPath == path
    // Read the observed vpnState into the enabled decision so a tunnel drop while idle here
    // recomposes the button. canRun stays the source of truth; this only observes its inputs.
    val runEnabled = vpnState.let { SpeedTestController.canRun(path) }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(title, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                if (isThisRunning) {
                    OutlinedButton(onClick = { SpeedTestController.cancel() }) { Text("Cancel") }
                } else {
                    Button(
                        onClick = { SpeedTestController.run(path) },
                        enabled = runEnabled,
                    ) { Text("Run") }
                }
            }

            val downloadMbps = when {
                isThisRunning -> ui.download?.mbps
                else -> result?.downloadMbps
            }
            val uploadMbps = when {
                isThisRunning -> ui.upload?.mbps
                else -> result?.uploadMbps
            }
            val downloadSamples = if (isThisRunning) ui.download?.samples else result?.downloadSamples
            val uploadSamples = if (isThisRunning) ui.upload?.samples else result?.uploadSamples

            MetricRow("Download", "↓", DownloadColor, downloadMbps, downloadSamples)
            MetricRow("Upload", "↑", UploadColor, uploadMbps, uploadSamples)

            val latency = if (isThisRunning) ui.latencyMs else result?.medianLatencyMs
            val jitter = if (isThisRunning) ui.jitterMs else result?.jitterMs
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                Text("Latency ${fmt0(latency)} ms", fontSize = 13.sp)
                Text("Jitter ${fmt1(jitter)} ms", fontSize = 13.sp)
            }

            if (isThisRunning) {
                PhaseIndicator(ui.phase, ui.latencyReadout)
            } else if (result != null) {
                Text(relativeAgo(result.finishedAtMs), fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Latency -> Download -> Upload row: spinner on the active phase, check on completed ones. */
@Composable
private fun PhaseIndicator(phase: SpeedTestPhase, latencyReadout: String?) {
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        PhaseEntry("Latency", SpeedTestPhase.Latency, phase, muted)
        if (phase == SpeedTestPhase.Latency && !latencyReadout.isNullOrBlank()) {
            Text(latencyReadout, fontSize = 12.sp, color = muted)
        }
        PhaseEntry("Download", SpeedTestPhase.Download, phase, muted)
        PhaseEntry("Upload", SpeedTestPhase.Upload, phase, muted)
    }
}

@Composable
private fun PhaseEntry(label: String, entry: SpeedTestPhase, current: SpeedTestPhase, muted: Color) {
    val done = current.ordinal > entry.ordinal
    val active = current == entry
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        when {
            active -> CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            done -> Icon(Icons.Default.Check, contentDescription = null,
                tint = UploadColor, modifier = Modifier.size(14.dp))
            else -> Text("·", fontSize = 12.sp, color = muted)
        }
        Text(label, fontSize = 12.sp,
            color = if (active || done) MaterialTheme.colorScheme.onSurface else muted)
    }
}

/** Compact relative-time stamp for a finished result, e.g. "Tested 12s ago". */
private fun relativeAgo(finishedAtMs: Long): String {
    val secs = ((System.currentTimeMillis() - finishedAtMs) / 1000L).coerceAtLeast(0)
    return when {
        secs < 60 -> "Tested ${secs}s ago"
        secs < 3600 -> "Tested ${secs / 60}m ago"
        else -> "Tested ${secs / 3600}h ago"
    }
}

@Composable
private fun MetricRow(
    label: String, arrow: String, color: Color, mbps: Double?, samples: List<ThroughputSample>?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(arrow, color = color, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            Text(
                if (mbps == null) "--" else String.format(Locale.US, "%.1f Mbps", mbps),
                fontSize = 22.sp, fontWeight = FontWeight.Bold, color = color,
            )
        }
        Sparkline(samples ?: emptyList(), color, Modifier.fillMaxWidth().height(40.dp))
    }
}

/** Area + line sparkline of a throughput series, drawn on a Canvas (no chart library). */
@Composable
private fun Sparkline(samples: List<ThroughputSample>, color: Color, modifier: Modifier) {
    Canvas(modifier) {
        if (samples.size < 2) return@Canvas
        val maxMbps = (samples.maxOf { it.mbps }).coerceAtLeast(1e-6)
        val n = samples.size
        val stepX = size.width / (n - 1)
        fun x(i: Int) = stepX * i
        fun y(v: Double) = size.height - (v / maxMbps).toFloat() * size.height

        val line = Path().apply {
            moveTo(x(0), y(samples[0].mbps))
            for (i in 1 until n) lineTo(x(i), y(samples[i].mbps))
        }
        val area = Path().apply {
            addPath(line)
            lineTo(x(n - 1), size.height)
            lineTo(x(0), size.height)
            close()
        }
        drawPath(area, color.copy(alpha = 0.15f))
        drawPath(line, color, style = Stroke(width = 2.5f))

        // Dashed rule at the series average, using the same maxMbps scaling as the line.
        val avg = samples.map { it.mbps }.average()
        val avgY = y(avg)
        drawLine(
            color = color.copy(alpha = 0.5f),
            start = androidx.compose.ui.geometry.Offset(0f, avgY),
            end = androidx.compose.ui.geometry.Offset(size.width, avgY),
            strokeWidth = 1.5f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 8f)),
        )
    }
}

@Composable
private fun ComparisonStrip(tunnel: SpeedTestResult?, direct: SpeedTestResult?) {
    if (tunnel == null || direct == null) return
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Tunnel vs Direct", fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            DeltaRow("Download", deltaPercent(tunnel.downloadMbps, direct.downloadMbps), true, false)
            DeltaRow("Upload", deltaPercent(tunnel.uploadMbps, direct.uploadMbps), true, false)
            DeltaRow("Latency", tunnel.medianLatencyMs - direct.medianLatencyMs, false, true)
            DeltaRow("Jitter", tunnel.jitterMs - direct.jitterMs, false, true)
        }
    }
}

@Composable
private fun DeltaRow(label: String, delta: Double?, isPercent: Boolean, lowerIsBetter: Boolean) {
    val band = if (isPercent) 3.0 else 2.0
    val sense = if (delta == null) DeltaSense.Neutral else deltaSense(delta, lowerIsBetter, band)
    val color = when (sense) {
        DeltaSense.Better -> UploadColor
        DeltaSense.Worse -> MaterialTheme.colorScheme.error
        DeltaSense.Neutral -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val text = when {
        delta == null -> "--"
        isPercent -> String.format(Locale.US, "%+.0f%%", delta)
        else -> String.format(Locale.US, "%+.1f ms", delta)
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, fontSize = 13.sp)
        Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = color)
    }
}

private fun fmt0(v: Double?) = if (v == null) "--" else String.format(Locale.US, "%.0f", v)
private fun fmt1(v: Double?) = if (v == null) "--" else String.format(Locale.US, "%.1f", v)

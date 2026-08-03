package tunnelbahn.app.ui

import android.Manifest
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts.RequestPermission
import androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult
import androidx.core.content.ContextCompat
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import tunnelbahn.app.profile.Profile
import tunnelbahn.app.profile.ProfileStore
import tunnelbahn.app.profile.appScopeSummary
import tunnelbahn.app.vpn.TunnelBahnVpnService

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(onProfiles: () -> Unit, onAddProfile: () -> Unit, onEditProfile: (String) -> Unit) {
    val ctx = LocalContext.current
    val store = remember { ProfileStore(ctx) }
    // Recreated on every entry into Home (AppRoot swaps composables), so this reads the
    // latest selection without an explicit refresh.
    val profile: Profile? = remember { store.selectedId()?.let { store.load(it) } }

    var importError by remember { mutableStateOf<String?>(null) }
    val launchImport = rememberQrImport(
        onImported = { p ->
            store.save(p)
            store.setSelectedId(p.id)
            onEditProfile(p.id) // open the editor so the user can review routing/apps
        },
        onError = { importError = it },
    )

    val state by TunnelBahnVpnService.state.collectAsStateWithLifecycle()
    val connectedSince by TunnelBahnVpnService.connectedSince.collectAsStateWithLifecycle()

    // Haptics fire from the service at the authoritative connect/fail transitions, so they
    // are not missed when this screen is not composed and do not race the conflated flow.

    var pending by remember { mutableStateOf(false) }
    val consent = rememberLauncherForActivityResult(StartActivityForResult()) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK && pending && profile != null) {
            startVpn(ctx, profile.id)
        }
        pending = false
    }

    var notifDenied by remember { mutableStateOf(false) }
    val notifPermission = rememberLauncherForActivityResult(RequestPermission()) { granted ->
        notifDenied = !granted
    }

    fun ensureNotifPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            ctx, Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            notifDenied = false
        } else {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    fun connect() {
        ensureNotifPermission()
        val id = profile?.id ?: return
        val prepare = VpnService.prepare(ctx)
        if (prepare != null) {
            pending = true
            consent.launch(prepare)
        } else {
            startVpn(ctx, id)
        }
    }

    // Called unconditionally (Compose rule); returns 0 when not connected.
    val elapsedMs = elapsedTicker(connectedSince)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("TunnelBahn") },
                actions = {
                    IconButton(onClick = onProfiles) {
                        Icon(Icons.AutoMirrored.Filled.List, contentDescription = "Profiles")
                    }
                },
            )
        },
    ) { pad ->
        Box(Modifier.fillMaxSize().padding(pad).padding(24.dp), contentAlignment = Alignment.Center) {
            if (profile == null) {
                EmptyHome(onAddProfile, onImport = launchImport)
            } else {
                ConnectionHero(
                    profile = profile,
                    state = state,
                    elapsedMs = elapsedMs,
                    notifDenied = notifDenied,
                    onConnect = { connect() },
                    onDisconnect = { stopVpn(ctx) },
                    onProfiles = onProfiles,
                )
            }
        }
    }

    importError?.let { msg ->
        AlertDialog(
            onDismissRequest = { importError = null },
            title = { Text("Import failed") },
            text = { Text(msg) },
            confirmButton = { TextButton(onClick = { importError = null }) { Text("OK") } },
        )
    }
}

@Composable
private fun ConnectionHero(
    profile: Profile,
    state: String,
    elapsedMs: Long,
    notifDenied: Boolean,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onProfiles: () -> Unit,
) {
    val running = state == TunnelBahnVpnService.STATE_RUNNING
    val connecting = state == TunnelBahnVpnService.STATE_CONNECTING
    val accent = stateColor(state)

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        // The ring is the primary control: tap to connect when idle, tap to disconnect when
        // running. Taps are ignored mid-connect so the request cannot be cut off in flight.
        StatusRing(
            state = state,
            accent = accent,
            enabled = !connecting,
            onTap = if (running) onDisconnect else onConnect,
        )
        Spacer(Modifier.height(20.dp))
        Text(
            stateLabel(state),
            style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
            color = accent,
        )
        Spacer(Modifier.height(4.dp))
        // The elapsed line owns a fixed slot so the layout does not jump on connect. Tabular
        // figures keep the digits from dancing as the seconds tick.
        Text(
            if (running) formatElapsed(elapsedMs) else "00:00:00",
            style = MaterialTheme.typography.displaySmall.copy(fontFeatureSettings = "tnum"),
            color = if (running) MaterialTheme.colorScheme.onSurface
            else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(24.dp))
        Text(
            profile.name.ifBlank { "Unnamed profile" },
            style = MaterialTheme.typography.titleMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            "${profile.transport}  ·  ${profile.appScopeSummary()}".uppercase(),
            style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 1.5.sp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (notifDenied && running) {
            Spacer(Modifier.height(12.dp))
            Text(
                "Live speed and exit location show in the notification. Allow notifications to see them.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
        Spacer(Modifier.height(36.dp))

        Text(
            when {
                running -> "Tap the ring to disconnect"
                connecting -> "Connecting..."
                else -> "Tap the ring to connect"
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(16.dp))
        TextButton(onClick = onProfiles, modifier = Modifier.fillMaxWidth()) {
            Text("Profiles")
        }
    }
}

/**
 * The signature element: a transit-signal ring that frames a center light. It sweeps an
 * indeterminate arc while connecting, holds a full ring with a slow breathing halo while
 * connected, and rests as a quiet track when idle. All drawn on Canvas so it carries no
 * icon-font dependency and reads correctly in light and dark.
 */
@Composable
private fun StatusRing(
    state: String,
    accent: Color,
    enabled: Boolean = false,
    onTap: (() -> Unit)? = null,
) {
    val running = state == TunnelBahnVpnService.STATE_RUNNING
    val connecting = state == TunnelBahnVpnService.STATE_CONNECTING || state == "degraded"
    val error = state == TunnelBahnVpnService.STATE_ERROR
    val track = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.14f)

    val transition = rememberInfiniteTransition(label = "ring")
    val sweepStart by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(1100, easing = LinearEasing)),
        label = "sweep",
    )
    val breath by transition.animateFloat(
        initialValue = 0.30f,
        targetValue = 0.60f,
        animationSpec = infiniteRepeatable(tween(1700, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "breath",
    )
    val haloAlpha = when {
        running -> breath
        connecting || error -> 0.38f
        else -> 0f
    }
    val dotColor = if (running || connecting || error) accent else track.copy(alpha = 0.6f)

    val tapModifier = if (onTap != null) {
        Modifier
            .clip(CircleShape)
            .clickable(enabled = enabled, onClickLabel = if (running) "Disconnect" else "Connect") {
                onTap()
            }
    } else {
        Modifier
    }

    Box(modifier = tapModifier, contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(148.dp)) {
            val d = size.minDimension
            val stroke = 9.dp.toPx()
            val inset = stroke / 2f + 8.dp.toPx()
            val arcSize = Size(d - inset * 2, d - inset * 2)
            val topLeft = Offset(inset, inset)

            if (haloAlpha > 0f) {
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(accent.copy(alpha = haloAlpha), Color.Transparent),
                        radius = d / 2f,
                    ),
                    radius = d / 2f,
                )
            }
            drawCircle(color = track, radius = d / 2f - inset, style = Stroke(stroke))
            when {
                connecting -> drawArc(
                    color = accent, startAngle = sweepStart, sweepAngle = 96f, useCenter = false,
                    topLeft = topLeft, size = arcSize, style = Stroke(stroke, cap = StrokeCap.Round),
                )
                running || error -> drawArc(
                    color = accent, startAngle = -90f, sweepAngle = 360f, useCenter = false,
                    topLeft = topLeft, size = arcSize, style = Stroke(stroke, cap = StrokeCap.Round),
                )
            }
            drawCircle(color = dotColor, radius = 9.dp.toPx())
        }
    }
}

@Composable
private fun EmptyHome(onAddProfile: () -> Unit, onImport: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        StatusRing(state = TunnelBahnVpnService.STATE_DISCONNECTED, accent = stateColor(TunnelBahnVpnService.STATE_DISCONNECTED))
        Spacer(Modifier.height(12.dp))
        Text("No profile yet", style = MaterialTheme.typography.titleLarge)
        Text(
            "Add a profile to start tunneling.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(4.dp))
        Button(
            onClick = onAddProfile,
            modifier = Modifier.fillMaxWidth().height(56.dp),
        ) { Text("Add profile") }
        TextButton(onClick = onImport, modifier = Modifier.fillMaxWidth()) {
            Text("Import from QR")
        }
    }
}

/** Semantic accent for each tunnel state. The connected green and amber/red are tuned to
 *  stay legible on both light and dark surfaces; idle falls back to the theme's muted tone. */
@Composable
private fun stateColor(state: String): Color = when (state) {
    TunnelBahnVpnService.STATE_RUNNING -> Color(0xFF2E9E5B)
    TunnelBahnVpnService.STATE_CONNECTING, "degraded" -> Color(0xFFE0A106)
    TunnelBahnVpnService.STATE_ERROR -> Color(0xFFD1493F)
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

private fun stateLabel(state: String): String = when (state) {
    TunnelBahnVpnService.STATE_RUNNING -> "Connected"
    TunnelBahnVpnService.STATE_CONNECTING -> "Connecting"
    "degraded" -> "Reconnecting"
    TunnelBahnVpnService.STATE_ERROR -> "Failed to connect"
    else -> "Disconnected"
}

private fun formatElapsed(ms: Long): String {
    val s = ms / 1000
    val h = s / 3600
    val m = (s % 3600) / 60
    val sec = s % 60
    return "%02d:%02d:%02d".format(h, m, sec)
}

/** Re-reads the wall clock once a second while connected so the elapsed display advances.
 *  Returns 0 when [since] is 0 (not connected). Safe to call unconditionally. */
@Composable
private fun elapsedTicker(since: Long): Long {
    var now by remember(since) { mutableStateOf(System.currentTimeMillis()) }
    androidx.compose.runtime.LaunchedEffect(since) {
        if (since <= 0L) return@LaunchedEffect
        while (true) {
            now = System.currentTimeMillis()
            delay(1000)
        }
    }
    return if (since > 0L) now - since else 0L
}

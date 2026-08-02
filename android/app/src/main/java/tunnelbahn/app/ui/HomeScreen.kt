package tunnelbahn.app.ui

import android.net.VpnService
import androidx.compose.foundation.background
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
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

    fun connect() {
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
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onProfiles: () -> Unit,
) {
    val running = state == TunnelBahnVpnService.STATE_RUNNING
    val connecting = state == TunnelBahnVpnService.STATE_CONNECTING
    val dotColor = when (state) {
        TunnelBahnVpnService.STATE_RUNNING -> Color(0xFF2E7D32)
        TunnelBahnVpnService.STATE_CONNECTING -> Color(0xFFF9A825)
        TunnelBahnVpnService.STATE_ERROR -> Color(0xFFC62828)
        else -> Color(0xFF9E9E9E)
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(Modifier.size(20.dp).clip(CircleShape).background(dotColor))
        Spacer(Modifier.height(12.dp))
        Text(stateLabel(state), style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(8.dp))
        Text(
            profile.name.ifBlank { "Unnamed profile" },
            style = MaterialTheme.typography.titleMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            "${profile.transport} · ${profile.appScopeSummary()}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(16.dp))
        Text(
            if (running) formatElapsed(elapsedMs) else "—",
            style = MaterialTheme.typography.displaySmall,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(32.dp))

        if (running || connecting) {
            Button(
                onClick = onDisconnect,
                enabled = !connecting || running,
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFC62828)),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (connecting) "Connecting..." else "Disconnect") }
        } else {
            Button(onClick = onConnect, modifier = Modifier.fillMaxWidth()) { Text("Connect") }
        }
        Spacer(Modifier.height(12.dp))
        OutlinedButton(onClick = onProfiles, modifier = Modifier.fillMaxWidth()) {
            Text("Profiles")
        }
    }
}

@Composable
private fun EmptyHome(onAddProfile: () -> Unit, onImport: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("No profile yet", style = MaterialTheme.typography.titleLarge)
        Text(
            "Add a profile to start tunneling.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onAddProfile) { Text("Add profile") }
        OutlinedButton(onClick = onImport) { Text("Import from QR") }
    }
}

private fun stateLabel(state: String): String = when (state) {
    TunnelBahnVpnService.STATE_RUNNING -> "Connected"
    TunnelBahnVpnService.STATE_CONNECTING -> "Connecting"
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

package tunnelbahn.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import tunnelbahn.app.profile.AppScope
import tunnelbahn.app.profile.Profile
import tunnelbahn.app.profile.ProfileStore
import tunnelbahn.app.profile.RoutingMode
import tunnelbahn.app.profile.Transport

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileEditor(profileId: String?, onDone: () -> Unit) {
    val ctx = LocalContext.current
    val store = remember { ProfileStore(ctx) }
    var draft by remember {
        mutableStateOf(
            profileId?.let { store.load(it) }
                ?: Profile(id = newId(), name = "", transport = Transport.SSH),
        )
    }

    var subScreen by remember { mutableStateOf(EditorSub.NONE) }
    var showAdvanced by remember { mutableStateOf(false) }
    // Composed after AppRoot's handler, so it takes priority while a sub-screen is up.
    BackHandler(enabled = subScreen != EditorSub.NONE) { subScreen = EditorSub.NONE }
    when (subScreen) {
        EditorSub.APPS -> {
            AppPickerScreen(
                initialPackages = draft.packages,
                onDone = { pkgs ->
                    draft = draft.copy(packages = pkgs)
                    subScreen = EditorSub.NONE
                },
            )
            return
        }
        EditorSub.CIDRS -> {
            CidrRulesScreen(
                initialMode = draft.routingMode,
                initialInclude = draft.includeCIDRs,
                initialExclude = draft.excludeCIDRs,
                onDone = { mode, inc, exc ->
                    draft = draft.copy(routingMode = mode, includeCIDRs = inc, excludeCIDRs = exc)
                    subScreen = EditorSub.NONE
                },
            )
            return
        }
        EditorSub.NONE -> Unit
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (profileId == null) "New profile" else "Edit profile") },
                navigationIcon = { TextButton(onClick = onDone) { Text("Cancel") } },
                actions = {
                    TextButton(
                        onClick = { store.save(draft); onDone() },
                        enabled = draft.name.isNotBlank(),
                    ) {
                        Text("Save")
                    }
                },
            )
        },
    ) { pad ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(pad)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = draft.name,
                onValueChange = { draft = draft.copy(name = it) },
                label = { Text("Name") },
                singleLine = true,
                supportingText = if (draft.name.isBlank()) {
                    { Text("Required before you can save") }
                } else {
                    null
                },
                modifier = Modifier.fillMaxWidth(),
            )

            Text("Transport")
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(
                    selected = draft.transport == Transport.SSH,
                    onClick = { draft = draft.copy(transport = Transport.SSH) },
                )
                Text("SSH", Modifier.padding(end = 16.dp))
                RadioButton(
                    selected = draft.transport == Transport.WGWS,
                    onClick = { draft = draft.copy(transport = Transport.WGWS) },
                )
                Text("WG over TCP")
            }

            if (draft.transport == Transport.SSH) {
                SshFields(draft) { draft = it }
            } else {
                WgFields(draft) { draft = it }
            }

            OutlinedTextField(
                value = draft.resolver,
                onValueChange = { draft = draft.copy(resolver = it) },
                label = { Text("DNS resolver (ip:port)") },
                modifier = Modifier.fillMaxWidth(),
            )

            RoutingSection(
                draft = draft,
                onScope = { draft = draft.copy(appScope = it) },
                onChooseApps = { subScreen = EditorSub.APPS },
            )

            AdvancedSection(
                expanded = showAdvanced,
                onToggle = { showAdvanced = !showAdvanced },
                draft = draft,
                onDestinations = { subScreen = EditorSub.CIDRS },
            )
        }
    }
}

@Composable
private fun RoutingSection(draft: Profile, onScope: (AppScope) -> Unit, onChooseApps: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Routing")
        HelpTooltip("Full tunnel sends every app through. Or tunnel only chosen apps, or everything except them.")
    }
    ScopeRadio("Full tunnel", draft.appScope == AppScope.FULL) { onScope(AppScope.FULL) }
    ScopeRadio("Only selected apps", draft.appScope == AppScope.ONLY_SELECTED) { onScope(AppScope.ONLY_SELECTED) }
    ScopeRadio("All apps except selected", draft.appScope == AppScope.EXCEPT_SELECTED) { onScope(AppScope.EXCEPT_SELECTED) }

    if (draft.appScope != AppScope.FULL) {
        OutlinedButton(onClick = onChooseApps, modifier = Modifier.fillMaxWidth()) {
            Text("Choose apps (${draft.packages.size} selected)")
        }
    }
}

@Composable
private fun ScopeRadio(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        RadioButton(selected = selected, onClick = onClick)
        Text(label)
    }
}

@Composable
private fun AdvancedSection(
    expanded: Boolean,
    onToggle: () -> Unit,
    draft: Profile,
    onDestinations: () -> Unit,
) {
    TextButton(onClick = onToggle, modifier = Modifier.fillMaxWidth()) {
        Text(if (expanded) "Hide advanced" else "Advanced")
    }
    if (expanded) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Per-destination rules")
            HelpTooltip("Optional. Route only some IP ranges, or exclude some. Leave empty for all destinations.")
        }
        OutlinedButton(onClick = onDestinations, modifier = Modifier.fillMaxWidth()) {
            val count = if (draft.routingMode == RoutingMode.INCLUDE) draft.includeCIDRs.size else draft.excludeCIDRs.size
            Text("Destinations ($count rules, ${draft.routingMode})")
        }
    }
}

@Composable
private fun SshFields(draft: Profile, update: (Profile) -> Unit) {
    OutlinedTextField(
        value = draft.endpoint,
        onValueChange = { update(draft.copy(endpoint = it)) },
        label = { Text("SSH server (host:port)") },
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = draft.sshUser,
        onValueChange = { update(draft.copy(sshUser = it)) },
        label = { Text("SSH user") },
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = draft.sshPrivateKeyPem,
        onValueChange = { update(draft.copy(sshPrivateKeyPem = it)) },
        label = { Text("Private key (OpenSSH PEM)") },
        modifier = Modifier.fillMaxWidth(),
        minLines = 3,
    )
    OutlinedTextField(
        value = draft.sshHostKeyAuthorized,
        onValueChange = { update(draft.copy(sshHostKeyAuthorized = it)) },
        label = { Text("Host key (authorized_keys line)") },
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun WgFields(draft: Profile, update: (Profile) -> Unit) {
    OutlinedTextField(
        value = draft.wsUrl,
        onValueChange = { update(draft.copy(wsUrl = it)) },
        label = { Text("wstunnel URL (wss://host/path/events)") },
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = draft.wgPrivateKey,
        onValueChange = { update(draft.copy(wgPrivateKey = it)) },
        label = { Text("WG private key (base64)") },
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = draft.wgPeerPublicKey,
        onValueChange = { update(draft.copy(wgPeerPublicKey = it)) },
        label = { Text("WG peer public key (base64)") },
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = draft.wgLocalAddrs.joinToString(", "),
        onValueChange = { v -> update(draft.copy(wgLocalAddrs = v.split(',').map { it.trim() }.filter { it.isNotEmpty() })) },
        label = { Text("WG local addresses (comma separated)") },
        modifier = Modifier.fillMaxWidth(),
    )
}

private enum class EditorSub { NONE, APPS, CIDRS }

private fun newId(): String = "p-" + System.currentTimeMillis().toString(36)

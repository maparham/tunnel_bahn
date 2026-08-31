package tunnelbahn.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import tunnelbahn.app.profile.RoutingMode

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CidrRulesScreen(
    initialMode: RoutingMode,
    initialInclude: List<String>,
    initialExclude: List<String>,
    onDone: (RoutingMode, List<String>, List<String>) -> Unit,
) {
    var mode by remember { mutableStateOf(initialMode) }
    // Per-mode independent rule sets, mirroring the macOS design.
    val include = remember { mutableStateListOf<String>().apply { addAll(initialInclude) } }
    val exclude = remember { mutableStateListOf<String>().apply { addAll(initialExclude) } }
    var bulk by remember { mutableStateOf("") }
    var invalidNote by remember { mutableStateOf("") }

    val active = if (mode == RoutingMode.INCLUDE) include else exclude

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Destinations") },
                navigationIcon = {
                    TextButton(onClick = { onDone(initialMode, initialInclude, initialExclude) }) { Text("Cancel") }
                },
                actions = {
                    TextButton(onClick = { onDone(mode, include.toList(), exclude.toList()) }) { Text("Done") }
                },
            )
        },
    ) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = mode == RoutingMode.INCLUDE, onClick = { mode = RoutingMode.INCLUDE })
                Text("Tunnel only these", Modifier.padding(end = 16.dp))
                RadioButton(selected = mode == RoutingMode.EXCLUDE, onClick = { mode = RoutingMode.EXCLUDE })
                Text("Tunnel all except these")
                HelpTooltip("Each mode keeps its own list. Include tunnels only matching IPs; exclude bypasses them.")
            }

            OutlinedTextField(
                value = bulk,
                onValueChange = { bulk = it },
                label = { Text("Add CIDRs (one per line, e.g. 10.0.0.0/8)") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    val (ok, bad) = parseCidrLines(bulk)
                    ok.forEach { if (!active.contains(it)) active.add(it) }
                    invalidNote = if (bad.isEmpty()) "" else "Ignored invalid: ${bad.joinToString(", ")}"
                    bulk = ""
                }) { Text("Add") }
            }
            if (invalidNote.isNotEmpty()) {
                Text(invalidNote, color = Color(0xFFC62828), style = MaterialTheme.typography.bodySmall)
            }

            Text("${active.size} rules", style = MaterialTheme.typography.labelLarge)
            active.toList().forEach { cidr ->
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(cidr)
                    OutlinedButton(onClick = { active.remove(cidr) }) { Text("Remove") }
                }
            }
        }
    }
}

package tunnelbahn.app.ui

import android.content.Context
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class InstalledApp(val packageName: String, val label: String)

/** Case-insensitive filter over label and package. Pure, so it is unit-tested. */
fun filterApps(apps: List<InstalledApp>, query: String): List<InstalledApp> {
    val q = query.trim().lowercase()
    if (q.isEmpty()) return apps
    return apps.filter { it.label.lowercase().contains(q) || it.packageName.lowercase().contains(q) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppPickerScreen(
    initialPackages: List<String>,
    onDone: (List<String>) -> Unit,
) {
    val ctx = LocalContext.current
    val selected = remember { mutableStateListOf<String>().apply { addAll(initialPackages) } }
    var query by remember { mutableStateOf("") }

    val apps by produceState(initialValue = emptyList<InstalledApp>(), ctx) {
        value = withContext(Dispatchers.IO) { loadLaunchableApps(ctx) }
    }
    val visible = remember(apps, query) { filterApps(apps, query) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Apps (${selected.size})") },
                navigationIcon = { TextButton(onClick = { onDone(initialPackages) }) { Text("Cancel") } },
                actions = { TextButton(onClick = { onDone(selected.toList()) }) { Text("Done") } },
            )
        },
    ) { pad ->
        Column(Modifier.fillMaxSize().padding(pad)) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text("Search apps") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            )
            LazyColumn(Modifier.fillMaxSize()) {
                items(visible, key = { it.packageName }) { app ->
                    val checked = selected.contains(app.packageName)
                    AppRow(app, checked) {
                        if (checked) selected.remove(app.packageName) else selected.add(app.packageName)
                    }
                }
            }
        }
    }
}

@Composable
private fun AppRow(app: InstalledApp, checked: Boolean, onToggle: () -> Unit) {
    val ctx = LocalContext.current
    val icon by produceState<ImageBitmap?>(initialValue = null, app.packageName) {
        value = withContext(Dispatchers.IO) { loadIcon(ctx, app.packageName) }
    }
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = checked, onCheckedChange = null)
        icon?.let {
            Image(it, contentDescription = null, modifier = Modifier.padding(start = 12.dp).size(32.dp))
        }
        Column(Modifier.padding(start = 12.dp)) {
            Text(app.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(app.packageName, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

private fun loadLaunchableApps(ctx: Context): List<InstalledApp> {
    val pm = ctx.packageManager
    val intent = android.content.Intent(android.content.Intent.ACTION_MAIN)
        .addCategory(android.content.Intent.CATEGORY_LAUNCHER)
    return pm.queryIntentActivities(intent, 0)
        .mapNotNull { ri ->
            val pkg = ri.activityInfo?.packageName ?: return@mapNotNull null
            InstalledApp(pkg, ri.loadLabel(pm).toString())
        }
        .distinctBy { it.packageName }
        .sortedBy { it.label.lowercase() }
}

private fun loadIcon(ctx: Context, pkg: String): ImageBitmap? = try {
    ctx.packageManager.getApplicationIcon(pkg).toBitmap(96, 96).asImageBitmap()
} catch (_: Exception) {
    null
}

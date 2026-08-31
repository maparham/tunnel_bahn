package tunnelbahn.app.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import tunnelbahn.mobile.Mobile

/** How often the view re-reads the buffer, so a connect attempt can be watched live. */
private const val REFRESH_MS = 1000L

/**
 * Shows the core's diagnostic log.
 *
 * The buffer lives in the Go core rather than in this screen or the service, so it still
 * holds the story of a connect attempt that failed and tore its session down — which is
 * exactly when someone opens this screen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LogScreen(onBack: () -> Unit) {
    var text by remember { mutableStateOf(Mobile.logText()) }
    val clipboard: ClipboardManager = LocalClipboardManager.current
    val listState = rememberLazyListState()
    // Hoisted above the empty/non-empty branch so the remember is unconditional.
    val hScroll = rememberScrollState()

    // Poll rather than push: the core writes from several goroutines and a callback per
    // line would cross the JNI boundary on the packet path. A 1s repaint is plenty for
    // reading, and it means the screen follows a live connect without any wiring.
    LaunchedEffect(Unit) {
        while (true) {
            delay(REFRESH_MS)
            text = Mobile.logText()
        }
    }

    val lines = remember(text) { if (text.isBlank()) emptyList() else text.split("\n") }

    // Follow the tail as new lines arrive, which is what you want while watching a
    // connect. Scrolling up to read history is not fought, because this only runs when
    // the line count actually changes.
    LaunchedEffect(lines.size) {
        if (lines.isNotEmpty()) listState.scrollToItem(lines.size - 1)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Logs") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { text = Mobile.logText() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                    IconButton(
                        enabled = lines.isNotEmpty(),
                        onClick = { clipboard.setText(AnnotatedString(text)) },
                    ) {
                        Icon(Icons.Default.Share, contentDescription = "Copy to clipboard")
                    }
                    IconButton(
                        enabled = lines.isNotEmpty(),
                        onClick = {
                            Mobile.clearLog()
                            text = Mobile.logText()
                        },
                    ) {
                        Icon(Icons.Default.Delete, contentDescription = "Clear")
                    }
                },
            )
        },
    ) { pad ->
        if (lines.isEmpty()) {
            Box(
                Modifier.fillMaxSize().padding(pad).padding(24.dp),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("No log entries yet", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Connect a profile and the attempt will be recorded here.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            return@Scaffold
        }

        // Log lines are long and must not be reflowed: wrapping a timestamped line makes
        // the column of times unreadable. Scroll horizontally instead.
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().padding(pad).padding(horizontal = 12.dp),
        ) {
            items(lines) { line ->
                Text(
                    line,
                    modifier = Modifier.fillMaxWidth().horizontalScroll(hScroll),
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    maxLines = 1,
                    softWrap = false,
                    color = lineColor(line),
                )
            }
        }
    }
}

/** Tints the lines that matter: failures red, carrier trouble amber. */
@Composable
private fun lineColor(line: String) = when {
    line.contains("failed") || line.contains("error") -> MaterialTheme.colorScheme.error
    line.contains("dropped") || line.contains("watchdog") -> MaterialTheme.colorScheme.tertiary
    else -> MaterialTheme.colorScheme.onSurface
}

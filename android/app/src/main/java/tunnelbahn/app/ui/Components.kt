package tunnelbahn.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import tunnelbahn.app.vpn.TunnelBahnVpnService

/** Small colored status pill reflecting the tunnel state flow. */
@Composable
fun StateChip(state: String) {
    val (label, color) = when (state) {
        TunnelBahnVpnService.STATE_RUNNING -> "Connected" to Color(0xFF2E7D32)
        TunnelBahnVpnService.STATE_CONNECTING -> "Connecting" to Color(0xFFF9A825)
        "degraded" -> "Reconnecting" to Color(0xFFF9A825)
        TunnelBahnVpnService.STATE_ERROR -> "Error" to Color(0xFFC62828)
        else -> "Disconnected" to Color(0xFF616161)
    }
    ElevatedCard(
        colors = CardDefaults.elevatedCardColors(containerColor = color),
        shape = RoundedCornerShape(50),
    ) {
        Text(
            label,
            color = Color.White,
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
        )
    }
}

/** Questionmark glyph that reveals a short tooltip on tap. Keep text to one or two
 *  short sentences and no em dashes. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HelpTooltip(text: String) {
    val state = rememberTooltipState(isPersistent = false)
    val scope = rememberCoroutineScope()
    TooltipBox(
        positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = { PlainTooltip { Text(text) } },
        state = state,
    ) {
        Row {
            Icon(
                Icons.AutoMirrored.Filled.HelpOutline,
                contentDescription = "Help",
                modifier = Modifier
                    .padding(start = 4.dp)
                    .clickableNoRipple { scope.launch { state.show() } },
            )
        }
    }
}

@Composable
private fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier =
    this.clickable(
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
        onClick = onClick,
    )

package tunnelbahn.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

/** Minimal state-based navigation to avoid pulling in a nav library. */
sealed interface Screen {
    data object Home : Screen
    data object Profiles : Screen
    /** [returnTo] is where onDone lands, so adding from Home returns to Home. */
    data class Edit(val profileId: String?, val returnTo: Screen) : Screen
    data object SpeedTest : Screen
    data object Logs : Screen
}

@Composable
fun AppRoot() {
    var screen: Screen by remember { mutableStateOf(Screen.Home) }

    BackHandler(enabled = screen != Screen.Home) {
        screen = when (val s = screen) {
            is Screen.Edit -> s.returnTo
            else -> Screen.Home
        }
    }

    when (val s = screen) {
        is Screen.Home -> HomeScreen(
            onProfiles = { screen = Screen.Profiles },
            onAddProfile = { screen = Screen.Edit(null, returnTo = Screen.Home) },
            onEditProfile = { id -> screen = Screen.Edit(id, returnTo = Screen.Home) },
            onSpeedTest = { screen = Screen.SpeedTest },
            onLogs = { screen = Screen.Logs },
        )
        is Screen.Profiles -> ProfilesScreen(
            onBack = { screen = Screen.Home },
            onAdd = { screen = Screen.Edit(null, returnTo = Screen.Profiles) },
            onEdit = { id -> screen = Screen.Edit(id, returnTo = Screen.Profiles) },
        )
        is Screen.Edit -> ProfileEditor(
            profileId = s.profileId,
            onDone = { screen = s.returnTo },
        )
        is Screen.SpeedTest -> SpeedTestScreen(onBack = { screen = Screen.Home })
        is Screen.Logs -> LogScreen(onBack = { screen = Screen.Home })
    }
}

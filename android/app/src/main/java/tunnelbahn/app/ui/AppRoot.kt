package tunnelbahn.app.ui

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
}

@Composable
fun AppRoot() {
    var screen: Screen by remember { mutableStateOf(Screen.Home) }

    when (val s = screen) {
        is Screen.Home -> HomeScreen(
            onProfiles = { screen = Screen.Profiles },
            onAddProfile = { screen = Screen.Edit(null, returnTo = Screen.Home) },
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
    }
}

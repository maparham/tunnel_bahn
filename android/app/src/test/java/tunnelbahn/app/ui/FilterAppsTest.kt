package tunnelbahn.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class FilterAppsTest {

    private val apps = listOf(
        InstalledApp("com.android.chrome", "Chrome"),
        InstalledApp("org.telegram.messenger", "Telegram"),
        InstalledApp("com.instagram.android", "Instagram"),
    )

    @Test
    fun emptyQueryReturnsAll() {
        assertEquals(apps, filterApps(apps, "   "))
    }

    @Test
    fun matchesLabelCaseInsensitively() {
        assertEquals(listOf(apps[1]), filterApps(apps, "TELE"))
    }

    @Test
    fun matchesPackage() {
        assertEquals(listOf(apps[0]), filterApps(apps, "android.chrome"))
    }

    @Test
    fun noMatchReturnsEmpty() {
        assertEquals(emptyList<InstalledApp>(), filterApps(apps, "signal"))
    }
}

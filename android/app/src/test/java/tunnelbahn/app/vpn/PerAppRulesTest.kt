package tunnelbahn.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Test
import tunnelbahn.app.profile.AppScope

class PerAppRulesTest {

    private val own = "tunnelbahn.app"

    @Test
    fun fullTunnelDisallowsOnlyOwnPackage() {
        assertEquals(
            listOf(AppRule.Disallow(own)),
            perAppRules(AppScope.FULL, listOf("com.a", "com.b"), own),
        )
    }

    @Test
    fun onlySelectedAllowsEachPackageAndNotOwn() {
        assertEquals(
            listOf(AppRule.Allow("com.a"), AppRule.Allow("com.b")),
            perAppRules(AppScope.ONLY_SELECTED, listOf("com.a", "com.b"), own),
        )
    }

    @Test
    fun onlySelectedWithEmptyListFallsBackToFullTunnel() {
        assertEquals(
            listOf(AppRule.Disallow(own)),
            perAppRules(AppScope.ONLY_SELECTED, emptyList(), own),
        )
    }

    @Test
    fun exceptSelectedDisallowsEachPackagePlusOwn() {
        assertEquals(
            listOf(AppRule.Disallow("com.a"), AppRule.Disallow("com.b"), AppRule.Disallow(own)),
            perAppRules(AppScope.EXCEPT_SELECTED, listOf("com.a", "com.b"), own),
        )
    }

    @Test
    fun exceptSelectedWithEmptyListIsFullTunnel() {
        assertEquals(
            listOf(AppRule.Disallow(own)),
            perAppRules(AppScope.EXCEPT_SELECTED, emptyList(), own),
        )
    }
}

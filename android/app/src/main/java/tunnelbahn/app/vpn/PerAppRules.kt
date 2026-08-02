package tunnelbahn.app.vpn

import tunnelbahn.app.profile.AppScope

/** A single per-app decision to apply to the VpnService.Builder. */
sealed interface AppRule {
    data class Allow(val pkg: String) : AppRule
    data class Disallow(val pkg: String) : AppRule
}

/**
 * Pure mapping from an [AppScope] + selected packages to the allow/disallow calls the
 * tun builder must make. Kept free of Android types so it can be unit-tested.
 *
 * VpnService allows OR denies, never both. Our own package is always kept out of the
 * tun so the carrier socket never loops back through it.
 *
 *  - FULL: disallow only our own package (every other app is tunneled).
 *  - ONLY_SELECTED: allow each selected package; our own is not allowed, so it is
 *    excluded and cannot loop. Empty selection falls back to FULL, since an empty
 *    allow-list would tunnel nothing and strand the user.
 *  - EXCEPT_SELECTED: disallow each selected package plus our own.
 */
fun perAppRules(scope: AppScope, packages: List<String>, ownPackage: String): List<AppRule> =
    when (scope) {
        AppScope.FULL -> listOf(AppRule.Disallow(ownPackage))
        AppScope.ONLY_SELECTED ->
            if (packages.isEmpty()) listOf(AppRule.Disallow(ownPackage))
            else packages.map { AppRule.Allow(it) }
        AppScope.EXCEPT_SELECTED ->
            packages.map { AppRule.Disallow(it) } + AppRule.Disallow(ownPackage)
    }

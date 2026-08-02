package tunnelbahn.app.profile

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

enum class Transport { SSH, WGWS }

enum class RoutingMode { INCLUDE, EXCLUDE }

/**
 * Which apps' traffic enters the tunnel.
 *  - FULL: every app (a plain full-tunnel VPN). This is the default.
 *  - ONLY_SELECTED: only the apps in [Profile.packages].
 *  - EXCEPT_SELECTED: every app except the ones in [Profile.packages].
 */
enum class AppScope { FULL, ONLY_SELECTED, EXCEPT_SELECTED }

/**
 * A connection profile. Mirrors the macOS TunnelBahn schema fields this client needs.
 * Key material (sshPrivateKeyPem, wgPrivateKey, wgPresharedKey) is persisted separately
 * in EncryptedSharedPreferences, never in the plain profile JSON.
 */
@Serializable
data class Profile(
    val id: String,
    val name: String,
    val transport: Transport,
    // SSH
    val endpoint: String = "",            // host:port of the SSH server
    val sshUser: String = "",
    val sshPrivateKeyPem: String = "",
    val sshHostKeyAuthorized: String = "",
    // WG-over-wstunnel
    val wgPrivateKey: String = "",
    val wgPeerPublicKey: String = "",
    val wgPresharedKey: String = "",
    val wgLocalAddrs: List<String> = emptyList(),
    val wgDns: List<String> = emptyList(),
    val wgMtu: Int = 1280,
    val wsUrl: String = "",
    val wsForwardHost: String = "",
    val wsForwardPort: Int = 0,
    // Routing
    val routingMode: RoutingMode = RoutingMode.EXCLUDE,
    val includeCIDRs: List<String> = emptyList(),
    val excludeCIDRs: List<String> = emptyList(),
    val resolver: String = "1.1.1.1:53",
    // Per-app
    val appScope: AppScope = AppScope.FULL,
    val packages: List<String> = emptyList(),
)

/** One-line, human-readable summary of what this profile tunnels, for the UI. Matches
 *  the empty-selection fallback in [tunnelbahn.app.vpn.perAppRules]. */
fun Profile.appScopeSummary(): String = when (appScope) {
    AppScope.FULL -> "Full tunnel"
    AppScope.ONLY_SELECTED ->
        if (packages.isEmpty()) "Full tunnel"
        else "${packages.size} app" + if (packages.size == 1) "" else "s"
    AppScope.EXCEPT_SELECTED ->
        if (packages.isEmpty()) "Full tunnel" else "All except ${packages.size}"
}

/**
 * Builds the exact JSON that the Go core's parseConfig expects (see android/core/config.go).
 * Key material is included here because it cannot live in the Android Keystore directly.
 */
fun Profile.toCoreConfigJson(): String {
    fun arr(items: List<String>) = JsonArray(items.map { JsonPrimitive(it) })

    val obj = buildJsonObject {
        put("transport", if (transport == Transport.SSH) "ssh" else "wgws")
        put("mode", if (routingMode == RoutingMode.INCLUDE) "include" else "exclude")
        put("mtu", wgMtu)
        put("includeCIDRs", arr(includeCIDRs))
        put("excludeCIDRs", arr(excludeCIDRs))
        put("resolver", resolver)
        put("ssh", sshBlock())
        put("wg", wgBlock())
    }
    return Json.encodeToString(JsonObject.serializer(), obj)
}

private fun Profile.sshBlock(): JsonObject = buildJsonObject {
    put("addr", endpoint)
    put("user", sshUser)
    put("privateKeyPEM", sshPrivateKeyPem)
    put("hostKeyAuthorized", sshHostKeyAuthorized)
}

private fun Profile.wgBlock(): JsonObject = buildJsonObject {
    put("privateKey", wgPrivateKey)
    put("peerPublicKey", wgPeerPublicKey)
    put("peerPresharedKey", wgPresharedKey)
    put("localAddrs", JsonArray(wgLocalAddrs.map { JsonPrimitive(it) }))
    put("dns", JsonArray(wgDns.map { JsonPrimitive(it) }))
    put("mtu", wgMtu)
    put("wsURL", wsUrl)
    put("forwardHost", wsForwardHost)
    put("forwardPort", wsForwardPort)
}

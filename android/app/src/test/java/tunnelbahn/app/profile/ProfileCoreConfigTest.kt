package tunnelbahn.app.profile

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class ProfileCoreConfigTest {
    private fun wgProfile() = Profile(
        id = "p1", name = "AWS", transport = Transport.WG,
        wgPrivateKey = "pk", wgPeerPublicKey = "peer",
        wgLocalAddrs = listOf("10.9.0.2"), wgDns = listOf("1.1.1.1"),
        wgEndpoint = "3.139.146.5:51820", wgKeepalive = 15,
    )

    @Test fun plain_wg_emits_wg_transport_with_endpoint_and_keepalive() {
        val obj = Json.parseToJsonElement(wgProfile().toCoreConfigJson()).jsonObject
        assertEquals("wg", obj["transport"]!!.jsonPrimitive.content)
        val wg = obj["wg"]!!.jsonObject
        assertEquals("3.139.146.5:51820", wg["endpoint"]!!.jsonPrimitive.content)
        assertEquals("15", wg["keepalive"]!!.jsonPrimitive.content)
    }

    @Test fun wgws_still_emits_wgws_transport() {
        val obj = Json.parseToJsonElement(wgProfile().copy(transport = Transport.WGWS).toCoreConfigJson()).jsonObject
        assertEquals("wgws", obj["transport"]!!.jsonPrimitive.content)
    }

    @Test fun display_endpoint_follows_transport() {
        val p = wgProfile().copy(endpoint = "ssh:22", wsUrl = "wss://x/events")
        assertEquals("3.139.146.5:51820", p.displayEndpoint())
        assertEquals("ssh:22", p.copy(transport = Transport.SSH).displayEndpoint())
        assertEquals("wss://x/events", p.copy(transport = Transport.WGWS).displayEndpoint())
    }
}

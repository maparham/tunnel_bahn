package tunnelbahn.app.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QRImportTest {
    private val id = "fixed-id"

    @Test fun ssh_payload_maps_to_profile_with_blank_host_key() {
        val raw = """
            {"kind":"tunnelbahn.profile","name":"My SSH","transport":"ssh",
             "ssh":{"addr":"1.2.3.4:443","user":"tb","privateKeyPEM":"PEMDATA"}}
        """.trimIndent()
        val r = parseImportedProfile(raw, id) as QRImportResult.Ok
        val p = r.profile
        assertEquals(id, p.id)
        assertEquals("My SSH", p.name)
        assertEquals(Transport.SSH, p.transport)
        assertEquals("1.2.3.4:443", p.endpoint)
        assertEquals("tb", p.sshUser)
        assertEquals("PEMDATA", p.sshPrivateKeyPem)
        assertEquals("", p.sshHostKeyAuthorized) // TOFU fills this on first connect
        assertEquals(AppScope.FULL, p.appScope)
    }

    @Test fun wg_payload_maps_relay_fields() {
        val raw = """
            {"kind":"tunnelbahn.profile","name":"My WG","transport":"wgws",
             "wg":{"privateKey":"pk","peerPublicKey":"peer","presharedKey":"",
                   "localAddrs":["10.9.0.2/32"],"dns":["1.1.1.1"],"mtu":1280,
                   "wsURL":"wss://1.2.3.4:443/tun/events","forwardHost":"127.0.0.1","forwardPort":51840}}
        """.trimIndent()
        val p = (parseImportedProfile(raw, id) as QRImportResult.Ok).profile
        assertEquals(Transport.WGWS, p.transport)
        assertEquals("pk", p.wgPrivateKey)
        assertEquals("peer", p.wgPeerPublicKey)
        assertEquals(listOf("10.9.0.2/32"), p.wgLocalAddrs)
        assertEquals(1280, p.wgMtu)
        assertEquals("wss://1.2.3.4:443/tun/events", p.wsUrl)
        assertEquals("127.0.0.1", p.wsForwardHost)
        assertEquals(51840, p.wsForwardPort)
    }

    @Test fun foreign_kind_is_rejected() {
        val raw = """{"kind":"something-else","name":"x","transport":"ssh"}"""
        assertTrue(parseImportedProfile(raw, id) is QRImportResult.Error)
    }

    @Test fun malformed_json_is_rejected() {
        assertTrue(parseImportedProfile("not json", id) is QRImportResult.Error)
    }

    @Test fun missing_transport_block_is_rejected() {
        val raw = """{"kind":"tunnelbahn.profile","name":"x","transport":"ssh"}"""
        assertTrue(parseImportedProfile(raw, id) is QRImportResult.Error)
    }
}

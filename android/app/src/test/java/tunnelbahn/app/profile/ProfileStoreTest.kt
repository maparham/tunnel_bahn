package tunnelbahn.app.profile

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** In-memory secret store: keeps the round-trip test off the Android Keystore, which
 *  Robolectric does not fully implement. Production uses EncryptedSecretStore. */
private class FakeSecretStore : SecretStore {
    private val m = mutableMapOf<String, String>()
    override fun put(key: String, value: String) { m[key] = value }
    override fun get(key: String): String? = m[key]
    override fun remove(key: String) { m.remove(key) }
}

private fun sampleProfile() = Profile(
    id = "p1",
    name = "SSH exit",
    transport = Transport.SSH,
    endpoint = "1.2.3.4:443",
    sshUser = "tb",
    sshPrivateKeyPem = "-----BEGIN OPENSSH PRIVATE KEY-----\nX\n-----END OPENSSH PRIVATE KEY-----\n",
    sshHostKeyAuthorized = "ssh-ed25519 AAAA",
    routingMode = RoutingMode.EXCLUDE,
    includeCIDRs = emptyList(),
    excludeCIDRs = listOf("10.0.0.0/8"),
    resolver = "1.1.1.1:53",
    appScope = AppScope.ONLY_SELECTED,
    packages = listOf("com.example.app"),
)

@RunWith(RobolectricTestRunner::class)
class ProfileStoreTest {

    private fun newStore(): ProfileStore {
        val ctx = ApplicationProvider.getApplicationContext<Context>()
        val prefs = ctx.getSharedPreferences("tb_profiles_test", Context.MODE_PRIVATE)
        prefs.edit().clear().apply()
        return ProfileStore(prefs, FakeSecretStore())
    }

    @Test
    fun saveThenLoadRoundTrips() {
        val store = newStore()
        val p = sampleProfile()
        store.save(p)

        val loaded = store.load("p1")!!
        assertEquals(p.sshPrivateKeyPem, loaded.sshPrivateKeyPem)
        assertEquals(listOf("10.0.0.0/8"), loaded.excludeCIDRs)
        assertEquals("tb", loaded.sshUser)
        assertEquals(listOf("com.example.app"), loaded.packages)
    }

    @Test
    fun secretsNotInPlainPrefs() {
        val ctx = ApplicationProvider.getApplicationContext<Context>()
        val prefs = ctx.getSharedPreferences("tb_profiles_test", Context.MODE_PRIVATE)
        prefs.edit().clear().apply()
        val store = ProfileStore(prefs, FakeSecretStore())
        store.save(sampleProfile())

        val plainBlob = prefs.getString("profile.p1", "")!!
        assertTrue("plain blob should exist", plainBlob.isNotEmpty())
        assertTrue(
            "private key must not appear in plain prefs",
            !plainBlob.contains("BEGIN OPENSSH PRIVATE KEY"),
        )
    }

    @Test
    fun coreConfigJsonShape() {
        val json = sampleProfile().toCoreConfigJson()
        assertTrue(json.contains("\"transport\":\"ssh\""))
        assertTrue(json.contains("\"excludeCIDRs\":[\"10.0.0.0/8\"]"))
        assertTrue(json.contains("\"mode\":\"exclude\""))
    }

    @Test
    fun deleteRemovesProfile() {
        val store = newStore()
        store.save(sampleProfile())
        store.delete("p1")
        assertNull(store.load("p1"))
    }
}

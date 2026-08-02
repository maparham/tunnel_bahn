package tunnelbahn.app.debug

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import tunnelbahn.app.profile.Profile
import tunnelbahn.app.profile.ProfileStore
import tunnelbahn.app.vpn.TunnelBahnVpnService
import java.net.HttpURLConnection
import java.net.URL

/**
 * Headless e2e driver, mirroring the macOS tunnelbahn://test URL driver.
 *
 *   adb shell am start -a android.intent.action.VIEW \
 *     -d "tunnelbahn-android://test?profile=<id>" tunnelbahn.app
 *
 * or seed a profile inline (base64 of the serialized Profile JSON) and connect it:
 *   adb shell am start -a android.intent.action.VIEW \
 *     -d "tunnelbahn-android://test?seed=<base64>" tunnelbahn.app
 *
 * It seeds/loads the profile, handles the one-time VPN consent dialog, waits for
 * RUNNING, fetches an exit-IP echo through the tunnel, and logs PASS/FAIL. View via:
 *   adb logcat -s TB_E2E
 */
class HeadlessDriver : Activity() {

    private val json = Json { ignoreUnknownKeys = true }
    private var profileId: String? = null
    // Set only when this run seeded a throwaway profile; deleted after the probe so e2e
    // runs never leave rows behind in the user's real ProfileStore.
    private var seededId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val data = intent?.data
        val store = ProfileStore(this)

        // Extras avoid URI query URL-decoding mangling base64 (+ becomes space).
        val seed = intent?.getStringExtra("seed") ?: data?.getQueryParameter("seed")
        profileId = if (seed != null) {
            val jsonStr = String(Base64.decode(seed, Base64.DEFAULT), Charsets.UTF_8)
            val p = json.decodeFromString(Profile.serializer(), jsonStr)
            store.save(p)
            seededId = p.id
            Log.i(TAG, "seeded profile id=${p.id} name=${p.name}")
            p.id
        } else {
            intent?.getStringExtra("profile") ?: data?.getQueryParameter("profile")
        }

        val id = profileId
        if (id == null || store.load(id) == null) {
            Log.e(TAG, "FAIL: no usable profile (id=$id)")
            finish()
            return
        }

        val prep = VpnService.prepare(this)
        if (prep != null) {
            Log.i(TAG, "requesting VPN consent")
            startActivityForResult(prep, REQ_CONSENT)
        } else {
            connectAndProbe(id)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_CONSENT) {
            if (resultCode == RESULT_OK) {
                connectAndProbe(profileId!!)
            } else {
                Log.e(TAG, "FAIL: VPN consent denied")
                cleanupSeed()
                finish()
            }
        }
    }

    private fun connectAndProbe(id: String) {
        Log.i(TAG, "connecting profile=$id")
        val intent = Intent(this, TunnelBahnVpnService::class.java)
            .putExtra(TunnelBahnVpnService.EXTRA_PROFILE_ID, id)
        androidx.core.content.ContextCompat.startForegroundService(this, intent)

        CoroutineScope(Dispatchers.Main).launch {
            val ok = awaitState(TunnelBahnVpnService.STATE_RUNNING, timeoutMs = 20_000)
            if (!ok) {
                Log.e(TAG, "FAIL: never reached RUNNING (state=${TunnelBahnVpnService.state.value}, err=${TunnelBahnVpnService.lastError.value})")
                cleanupSeed()
                finish()
                return@launch
            }
            val direct = withContext(Dispatchers.IO) { fetchExitIp() }
            if (direct != null) {
                Log.i(TAG, "PASS: exit IP through tunnel = $direct")
            } else {
                Log.e(TAG, "FAIL: exit-IP probe failed through tunnel (err=${TunnelBahnVpnService.lastError.value})")
            }
            cleanupSeed()
            finish()
        }
    }

    private suspend fun awaitState(target: String, timeoutMs: Long): Boolean {
        var waited = 0L
        while (waited < timeoutMs) {
            when (TunnelBahnVpnService.state.value) {
                target -> return true
                TunnelBahnVpnService.STATE_ERROR -> return false
            }
            delay(200)
            waited += 200
        }
        return TunnelBahnVpnService.state.value == target
    }

    /** Removes the throwaway profile this run seeded, if any. The service already holds
     *  the profile in memory, so deleting it from the store does not disturb the tunnel. */
    private fun cleanupSeed() {
        val id = seededId ?: return
        ProfileStore(this).delete(id)
        Log.i(TAG, "removed seeded profile id=$id")
        seededId = null
    }

    private fun fetchExitIp(): String? = try {
        val conn = URL(EXIT_IP_URL).openConnection() as HttpURLConnection
        conn.connectTimeout = 10000
        conn.readTimeout = 10000
        conn.inputStream.bufferedReader().use { it.readText().trim() }
    } catch (e: Exception) {
        Log.e(TAG, "exit-IP probe error: ${e.message}")
        null
    }

    private companion object {
        const val TAG = "TB_E2E"
        const val EXIT_IP_URL = "https://api.ipify.org"
        const val REQ_CONSENT = 1001
    }
}

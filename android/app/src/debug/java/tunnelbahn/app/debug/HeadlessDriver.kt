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
import kotlinx.serialization.json.Json
import tunnelbahn.app.profile.Profile
import tunnelbahn.app.profile.ProfileStore
import tunnelbahn.app.vpn.TunnelBahnVpnService

/**
 * Headless e2e driver, mirroring the macOS tunnelbahn://test URL driver. DEBUG-ONLY:
 * this Activity lives in the debug source set so it (and its browsable intent filter)
 * are compiled out of release builds entirely, never shipping a remotely-triggerable
 * VPN control surface.
 *
 *   adb shell am start -a android.intent.action.VIEW \
 *     -d "tunnelbahn-android://test?profile=<id>" tunnelbahn.app
 *
 * or seed a profile inline (base64 of the serialized Profile JSON) and connect it:
 *   adb shell am start -a android.intent.action.VIEW \
 *     -d "tunnelbahn-android://test?seed=<base64>" tunnelbahn.app
 *
 * It seeds/loads the profile, handles the one-time VPN consent dialog, waits for
 * RUNNING, then waits for the Go core's through-tunnel exit IP and asserts it differs
 * from the off-tunnel origin IP. View via:
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
            // Do NOT probe an echo service from this Activity: the app's own package is
            // excluded from the tun in every routing scope, so such a request rides the
            // normal network and returns the ORIGIN IP, passing on any connectivity (the
            // documented false-PASS bug). The Go core measures the exit IP through the
            // tunnel; gate PASS on that, and require it to differ from the off-tunnel origin.
            val exit = awaitExitIp(timeoutMs = 15_000)
            val origin = TunnelBahnVpnService.originIp.value
            when {
                exit == null ->
                    Log.e(TAG, "FAIL: no exit IP from core within timeout (err=${TunnelBahnVpnService.lastError.value})")
                origin.isNotBlank() && exit == origin ->
                    Log.e(TAG, "FAIL: exit IP == origin IP ($exit); traffic is not traversing the tunnel")
                else ->
                    Log.i(TAG, "PASS: exit IP through tunnel = $exit (origin=${origin.ifBlank { "unknown" }})")
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

    /** Waits for the Go core to report the through-tunnel exit IP, or null on timeout. */
    private suspend fun awaitExitIp(timeoutMs: Long): String? {
        var waited = 0L
        while (waited < timeoutMs) {
            val v = TunnelBahnVpnService.exitIp.value
            if (v.isNotBlank()) return v
            delay(200)
            waited += 200
        }
        return TunnelBahnVpnService.exitIp.value.ifBlank { null }
    }

    /** Removes the throwaway profile this run seeded, if any. The service already holds
     *  the profile in memory, so deleting it from the store does not disturb the tunnel. */
    private fun cleanupSeed() {
        val id = seededId ?: return
        ProfileStore(this).delete(id)
        Log.i(TAG, "removed seeded profile id=$id")
        seededId = null
    }

    private companion object {
        const val TAG = "TB_E2E"
        const val REQ_CONSENT = 1001
    }
}

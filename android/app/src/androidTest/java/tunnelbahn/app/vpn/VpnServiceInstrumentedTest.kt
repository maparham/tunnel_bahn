package tunnelbahn.app.vpn

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tunnelbahn.app.profile.AppScope
import tunnelbahn.app.profile.Profile
import tunnelbahn.app.profile.ProfileStore
import tunnelbahn.app.profile.RoutingMode
import tunnelbahn.app.profile.Transport

/**
 * On-device smoke test. Requires VPN consent already granted on the test device
 * (VpnService.prepare returns null once granted). Seeds a profile pointing at an
 * intentionally-unreachable SSH endpoint and asserts the service leaves DISCONNECTED
 * (reaches CONNECTING then errors), proving the tun build + core handoff path runs
 * without a live server. Full traffic validation is the Task 15 e2e checklist.
 */
@RunWith(AndroidJUnit4::class)
class VpnServiceInstrumentedTest {

    @Test
    fun serviceStartsAndLeavesInitialState() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext

        val profile = Profile(
            id = "instr-test",
            name = "instr",
            transport = Transport.SSH,
            endpoint = "127.0.0.1:1", // unreachable on purpose
            sshUser = "u",
            sshPrivateKeyPem = INVALID_PEM,
            sshHostKeyAuthorized = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample",
            routingMode = RoutingMode.EXCLUDE,
            excludeCIDRs = listOf("10.0.0.0/8"),
            resolver = "1.1.1.1:53",
            appScope = AppScope.FULL,
            packages = emptyList(),
        )
        ProfileStore(ctx).save(profile)

        val intent = Intent(ctx, TunnelBahnVpnService::class.java)
            .putExtra(TunnelBahnVpnService.EXTRA_PROFILE_ID, "instr-test")
        ctx.startService(intent)

        // The service should move off DISCONNECTED (to CONNECTING/ERROR) within the window.
        val reached = waitFor(8000) {
            TunnelBahnVpnService.state.value != TunnelBahnVpnService.STATE_DISCONNECTED
        }
        assertTrue("service never left DISCONNECTED", reached)

        ctx.startService(
            Intent(ctx, TunnelBahnVpnService::class.java).setAction(TunnelBahnVpnService.ACTION_STOP),
        )
    }

    private fun waitFor(timeoutMs: Long, cond: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (cond()) return true
            Thread.sleep(100)
        }
        return cond()
    }

    private companion object {
        const val INVALID_PEM = "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-real\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}

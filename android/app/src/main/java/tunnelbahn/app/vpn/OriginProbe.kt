package tunnelbahn.app.vpn

import tunnelbahn.app.ui.formatLocation
import tunnelbahn.mobile.Mobile
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Fetches the device's origin IP + geo once and publishes it to the service flows. The
 * probe is a blocking gomobile call, so it runs on a dedicated thread. Session-independent:
 * safe to call whether or not a tunnel is up. Skips work when origin is already known or a
 * probe is already in flight, so callers can trigger it freely (e.g. every time Home shows).
 */
object OriginProbe {
    private val running = AtomicBoolean(false)

    fun refresh() {
        if (TunnelBahnVpnService.originIp.value.isNotBlank()) return
        if (!running.compareAndSet(false, true)) return
        Thread {
            try {
                val info = Mobile.probeOrigin()
                TunnelBahnVpnService.originIp.value = info.ip
                TunnelBahnVpnService.originLocation.value = formatLocation(info.city, info.country)
            } catch (_: Exception) {
                // Origin is informational; leave the flows blank so the UI keeps showing
                // "Locating..." and a later refresh() can retry.
            } finally {
                running.set(false)
            }
        }.start()
    }
}

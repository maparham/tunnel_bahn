package tunnelbahn.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.flow.MutableStateFlow
import tunnelbahn.app.MainActivity
import tunnelbahn.app.profile.Profile
import tunnelbahn.app.profile.ProfileStore
import tunnelbahn.app.profile.RoutingMode
import tunnelbahn.app.profile.toCoreConfigJson
import tunnelbahn.app.ui.Haptics
import tunnelbahn.mobile.EventSink
import tunnelbahn.mobile.Mobile
import tunnelbahn.mobile.Session

/**
 * Owns OS integration: builds the tun (per-app allow/deny, coarse routes, DNS), runs
 * the Go core session on a worker thread, and surfaces state. All packet movement and
 * routing decisions live in the Go core.
 */
class TunnelBahnVpnService : VpnService() {

    private var session: Session? = null
    private var worker: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Per-attempt outcome tracking. A teardown that never reached RUNNING and was not a
    // user-initiated stop is a "failed to connect", which drives the error latch + haptic.
    private var reachedRunning = false
    private var userStopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                userStopping = true
                endSession(failed = false)
                return START_NOT_STICKY
            }
        }
        val profileId = intent?.getStringExtra(EXTRA_PROFILE_ID)
        if (profileId == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val profile = ProfileStore(this).load(profileId)
        if (profile == null) {
            lastError.value = "profile not found: $profileId"
            endSession(failed = true)
            return START_NOT_STICKY
        }
        // Fresh attempt: clear the previous outcome so stale errors do not linger.
        reachedRunning = false
        userStopping = false
        lastError.value = ""
        startForeground(NOTIF_ID, buildNotification())
        state.value = STATE_CONNECTING
        startTunnel(profile)
        return START_STICKY
    }

    private fun startTunnel(profile: Profile) {
        val builder = Builder()
            .setSession("TunnelBahn")
            .setMtu(if (profile.wgMtu > 0) profile.wgMtu else 1500)
            .addAddress("10.0.0.2", 32)

        when (profile.routingMode) {
            RoutingMode.EXCLUDE -> builder.addRoute("0.0.0.0", 0)
            RoutingMode.INCLUDE -> {
                profile.includeCIDRs.forEach { addRouteCidr(builder, it) }
                resolverIp(profile.resolver)?.let { builder.addRoute(it, 32) }
            }
        }

        resolverIp(profile.resolver)?.let { builder.addDnsServer(it) }
        applyPerApp(builder, profile)

        val pfd = builder.establish()
        if (pfd == null) {
            lastError.value = "VpnService.establish() returned null (consent revoked?)"
            endSession(failed = true)
            return
        }

        val fd = pfd.detachFd() // hand fd ownership to the Go core; it closes on Stop
        val s = Mobile.newSession()
        session = s
        worker = Thread {
            try {
                s.start(fd.toLong(), profile.toCoreConfigJson(), AndroidProtector(this), Sink())
            } catch (e: Exception) {
                lastError.value = e.message ?: "session failed"
            }
            // Start returns on failure (Go has already closed the tun fd) or on Stop. If we
            // never reached RUNNING and the user did not stop us, it is a failed connect.
            mainHandler.post { endSession(failed = !reachedRunning && !userStopping) }
        }.also { it.start() }
    }

    /** Per-app allow OR deny (VpnService cannot mix both). The decision logic lives in
     *  the pure [perAppRules]; here we just apply it. */
    private fun applyPerApp(builder: Builder, p: Profile) {
        perAppRules(p.appScope, p.packages, packageName).forEach { rule ->
            when (rule) {
                is AppRule.Allow -> tryAllow(builder, rule.pkg)
                is AppRule.Disallow -> tryDisallow(builder, rule.pkg)
            }
        }
    }

    private fun tryAllow(builder: Builder, pkg: String) {
        try {
            builder.addAllowedApplication(pkg)
        } catch (_: Exception) {
        }
    }

    private fun tryDisallow(builder: Builder, pkg: String) {
        try {
            builder.addDisallowedApplication(pkg)
        } catch (_: Exception) {
        }
    }

    private fun addRouteCidr(builder: Builder, cidr: String) {
        val slash = cidr.indexOf('/')
        if (slash < 0) return
        val addr = cidr.substring(0, slash)
        val prefix = cidr.substring(slash + 1).toIntOrNull() ?: return
        try {
            builder.addRoute(addr, prefix)
        } catch (_: Exception) {
        }
    }

    private fun resolverIp(resolver: String): String? {
        val i = resolver.lastIndexOf(':')
        val ip = if (i > 0) resolver.substring(0, i) else resolver
        return ip.ifEmpty { null }
    }

    /**
     * Ends the current session and foreground. [failed] latches STATE_ERROR (so the
     * "Failed to connect" surface survives teardown, unlike a value the conflated flow
     * would overwrite) and buzzes the failure pattern; otherwise it settles DISCONNECTED.
     * Idempotent: safe to call twice (e.g. user stop, then the worker's own teardown).
     */
    private fun endSession(failed: Boolean) {
        session?.stop()
        session = null
        worker = null
        connectedSince.value = 0L
        if (failed) {
            state.value = STATE_ERROR
            Haptics.failure(this)
        } else {
            state.value = STATE_DISCONNECTED
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        session?.stop()
        super.onDestroy()
    }

    override fun onRevoke() {
        userStopping = true
        endSession(failed = false)
    }

    private inner class Sink : EventSink {
        override fun onState(s: String) {
            state.value = s
            if (s == STATE_RUNNING) {
                connectedSince.value = System.currentTimeMillis()
                if (!reachedRunning) {
                    reachedRunning = true
                    Haptics.success(this@TunnelBahnVpnService)
                }
            }
        }

        override fun onError(msg: String) {
            lastError.value = msg
        }
    }

    private fun buildNotification(): Notification {
        val mgr = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Tunnel", NotificationManager.IMPORTANCE_LOW)
            mgr.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return b
            .setContentTitle("TunnelBahn")
            .setContentText("Tunnel active")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val EXTRA_PROFILE_ID = "profileId"
        const val ACTION_STOP = "tunnelbahn.app.STOP"

        const val STATE_DISCONNECTED = "disconnected"
        const val STATE_CONNECTING = "connecting"
        const val STATE_RUNNING = "running"
        const val STATE_ERROR = "error"

        private const val NOTIF_ID = 1
        private const val CHANNEL_ID = "tunnel"

        /** Observed by the UI. Single-process, so a shared flow is simpler than a broadcast. */
        val state = MutableStateFlow(STATE_DISCONNECTED)
        val lastError = MutableStateFlow("")

        /** Epoch millis when the tunnel reached RUNNING, or 0 when not running. Drives the
         *  Home screen's elapsed-time display. */
        val connectedSince = MutableStateFlow(0L)
    }
}

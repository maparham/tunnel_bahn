package tunnelbahn.app.ui

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import tunnelbahn.app.vpn.TunnelBahnVpnService

/** Starts the tunnel service for [profileId]. Caller must have cleared VPN consent. */
internal fun startVpn(ctx: Context, profileId: String) {
    val intent = Intent(ctx, TunnelBahnVpnService::class.java)
        .putExtra(TunnelBahnVpnService.EXTRA_PROFILE_ID, profileId)
    ContextCompat.startForegroundService(ctx, intent)
}

internal fun stopVpn(ctx: Context) {
    ctx.startService(
        Intent(ctx, TunnelBahnVpnService::class.java).setAction(TunnelBahnVpnService.ACTION_STOP),
    )
}

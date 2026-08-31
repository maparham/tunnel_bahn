package tunnelbahn.app.ui

import tunnelbahn.app.vpn.TunnelBahnVpnService

/**
 * Whether [state] means a session exists that the user can end.
 *
 * "degraded" belongs here and used to be missing: it means the carrier dropped and the
 * transport is retrying, which it does indefinitely by design. Treating it as not-live
 * made every stop control offer *Connect* instead, so on a network that kills long-lived
 * connections the app showed a spinner that no button could stop.
 */
fun isSessionLive(state: String): Boolean =
    state == TunnelBahnVpnService.STATE_RUNNING ||
        state == TunnelBahnVpnService.STATE_CONNECTING ||
        state == TunnelBahnVpnService.STATE_DEGRADED

/** What tapping the status ring should do. */
enum class RingAction { CONNECT, CANCEL, DISCONNECT }

/**
 * The ring is the only control on the Home screen, so it must always do something, and
 * while a session is live or in flight that something is "stop". It was previously inert
 * during CONNECTING, which left a connect attempt that never resolved with no way out.
 */
fun ringAction(state: String): RingAction = when {
    state == TunnelBahnVpnService.STATE_CONNECTING -> RingAction.CANCEL
    isSessionLive(state) -> RingAction.DISCONNECT
    else -> RingAction.CONNECT // disconnected, error, or anything unrecognised
}

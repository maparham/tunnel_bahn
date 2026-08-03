package tunnelbahn.app.ui

import tunnelbahn.app.vpn.TunnelBahnVpnService

/** What a profile card's primary button should do, given whether it is the active
 *  (last-connected) profile and the live VPN state. Only the active card can be live. */
enum class CardAction { CONNECT, DISCONNECT }

fun profileCardAction(isActive: Boolean, state: String): CardAction {
    val live = state == TunnelBahnVpnService.STATE_RUNNING ||
        state == TunnelBahnVpnService.STATE_CONNECTING
    return if (isActive && live) CardAction.DISCONNECT else CardAction.CONNECT
}

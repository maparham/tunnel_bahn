package tunnelbahn.app.ui

/** What a profile card's primary button should do, given whether it is the active
 *  (last-connected) profile and the live VPN state. Only the active card can be live. */
enum class CardAction { CONNECT, DISCONNECT }

fun profileCardAction(isActive: Boolean, state: String): CardAction =
    if (isActive && isSessionLive(state)) CardAction.DISCONNECT else CardAction.CONNECT

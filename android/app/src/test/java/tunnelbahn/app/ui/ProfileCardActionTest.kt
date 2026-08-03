package tunnelbahn.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import tunnelbahn.app.vpn.TunnelBahnVpnService

class ProfileCardActionTest {
    @Test fun activeAndRunningShowsDisconnect() {
        assertEquals(CardAction.DISCONNECT, profileCardAction(true, TunnelBahnVpnService.STATE_RUNNING))
    }

    @Test fun activeAndConnectingShowsDisconnect() {
        assertEquals(CardAction.DISCONNECT, profileCardAction(true, TunnelBahnVpnService.STATE_CONNECTING))
    }

    @Test fun activeButDisconnectedShowsConnect() {
        assertEquals(CardAction.CONNECT, profileCardAction(true, TunnelBahnVpnService.STATE_DISCONNECTED))
    }

    @Test fun inactiveWhileAnotherRunsShowsConnect() {
        assertEquals(CardAction.CONNECT, profileCardAction(false, TunnelBahnVpnService.STATE_RUNNING))
    }
}

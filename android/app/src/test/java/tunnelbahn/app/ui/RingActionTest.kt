package tunnelbahn.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tunnelbahn.app.vpn.TunnelBahnVpnService

class RingActionTest {
    @Test fun idleRingConnects() {
        assertEquals(RingAction.CONNECT, ringAction(TunnelBahnVpnService.STATE_DISCONNECTED))
    }

    @Test fun connectedRingDisconnects() {
        assertEquals(RingAction.DISCONNECT, ringAction(TunnelBahnVpnService.STATE_RUNNING))
    }

    /** The ring used to be disabled while connecting, so an attempt that never resolved
     *  could not be called off. It must offer a cancel instead. */
    @Test fun connectingRingCancels() {
        assertEquals(RingAction.CANCEL, ringAction(TunnelBahnVpnService.STATE_CONNECTING))
    }

    /** The reported bug: the retry loop runs forever, so "degraded" fell through to the
     *  idle branch and the ring fired *connect* on an already-live session — restarting
     *  the same doomed attempt instead of stopping it. */
    @Test fun degradedRingDisconnects() {
        assertEquals(RingAction.DISCONNECT, ringAction(TunnelBahnVpnService.STATE_DEGRADED))
    }

    @Test fun failedRingRetries() {
        assertEquals(RingAction.CONNECT, ringAction(TunnelBahnVpnService.STATE_ERROR))
    }

    /** An unrecognised state must still leave the user able to start a tunnel. */
    @Test fun unknownStateRingConnects() {
        assertEquals(RingAction.CONNECT, ringAction("something-new"))
    }

    @Test fun liveStatesAreTheStoppableOnes() {
        assertTrue(isSessionLive(TunnelBahnVpnService.STATE_RUNNING))
        assertTrue(isSessionLive(TunnelBahnVpnService.STATE_CONNECTING))
        assertTrue(isSessionLive(TunnelBahnVpnService.STATE_DEGRADED))
        assertFalse(isSessionLive(TunnelBahnVpnService.STATE_DISCONNECTED))
        assertFalse(isSessionLive(TunnelBahnVpnService.STATE_ERROR))
    }

    /** The profile card shares the predicate, so it stops offering Connect for a session
     *  that is merely reconnecting. */
    @Test fun activeCardWhileDegradedShowsDisconnect() {
        assertEquals(
            CardAction.DISCONNECT,
            profileCardAction(true, TunnelBahnVpnService.STATE_DEGRADED),
        )
    }
}

package tunnelbahn.app.speedtest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SpeedTestMathTest {
    @Test fun throughputSeriesComputesPerIntervalRates() {
        // (0.5s, 1_000_000B) then (1.0s, 2_000_000B): each interval is 0.5s and 1_000_000B.
        // 1_000_000*8/0.5/1e6 = 16 Mbps per interval.
        val s = throughputSeries(listOf(0.5 to 1_000_000L, 1.0 to 2_000_000L))
        assertEquals(2, s.size)
        assertEquals(16.0, s[0].mbps, 1e-9)
        assertEquals(1.0, s[1].offsetSeconds, 1e-9)
        assertEquals(16.0, s[1].mbps, 1e-9)
    }

    @Test fun throughputSeriesSkipsNonAdvancingTime() {
        val s = throughputSeries(listOf(0.5 to 1_000_000L, 0.5 to 3_000_000L))
        assertEquals(1, s.size) // second point does not advance time, skipped
    }

    @Test fun deltaPercentNullOnZeroBaseline() {
        assertNull(deltaPercent(tunnel = 10.0, direct = 0.0))
        assertEquals(50.0, deltaPercent(tunnel = 15.0, direct = 10.0)!!, 1e-9)
    }

    @Test fun deltaSenseClassifies() {
        assertEquals(DeltaSense.Neutral, deltaSense(2.0, lowerIsBetter = false, neutralBand = 3.0))
        assertEquals(DeltaSense.Better, deltaSense(5.0, lowerIsBetter = false, neutralBand = 3.0))
        assertEquals(DeltaSense.Worse, deltaSense(5.0, lowerIsBetter = true, neutralBand = 3.0))
        assertEquals(DeltaSense.Better, deltaSense(-5.0, lowerIsBetter = true, neutralBand = 3.0))
    }
}

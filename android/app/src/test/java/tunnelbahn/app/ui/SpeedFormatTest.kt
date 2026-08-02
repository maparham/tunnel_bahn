package tunnelbahn.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SpeedFormatTest {
    @Test
    fun humanizesAcrossUnits() {
        assertEquals("0 B/s", humanizeSpeed(0))
        assertEquals("512 B/s", humanizeSpeed(512))
        assertEquals("1.0 KB/s", humanizeSpeed(1024))
        assertEquals("1.5 KB/s", humanizeSpeed(1536))
        assertEquals("2.0 MB/s", humanizeSpeed(2L * 1024 * 1024))
    }

    @Test
    fun bytesPerSecondIsNonNegativeDelta() {
        assertEquals(300, bytesPerSecond(1000, 1300))
        assertEquals(0, bytesPerSecond(0, 0))
        // counter reset / first sample: never a negative speed
        assertEquals(0, bytesPerSecond(5000, 100))
    }

    @Test
    fun formatsLocationCityAndCountryName() {
        assertEquals("Berlin, Germany", formatLocation("Berlin", "DE"))
        assertEquals("Germany", formatLocation("", "DE"))
        assertEquals("Berlin", formatLocation("Berlin", ""))
        assertEquals("XX", formatLocation("", "XX")) // unknown code passes through
    }
}

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
    fun bytesPerSecondNormalizesByElapsedTime() {
        // 300 bytes over exactly 1s -> 300 B/s
        assertEquals(300, bytesPerSecond(1000, 1300, 1000))
        // 3000 bytes over 2s -> 1500 B/s (the poll interval no longer skews the rate)
        assertEquals(1500, bytesPerSecond(1000, 4000, 2000))
        // 300 bytes over 500ms -> 600 B/s
        assertEquals(600, bytesPerSecond(1000, 1300, 500))
        assertEquals(0, bytesPerSecond(0, 0, 2000))
        // counter reset / first sample: never a negative speed
        assertEquals(0, bytesPerSecond(5000, 100, 2000))
        // degenerate zero interval floors at 1ms rather than dividing by zero
        assertEquals(300_000, bytesPerSecond(1000, 1300, 0))
    }

    @Test
    fun formatsLocationCityAndCountryName() {
        assertEquals("Berlin, Germany", formatLocation("Berlin", "DE"))
        assertEquals("Germany", formatLocation("", "DE"))
        assertEquals("Berlin", formatLocation("Berlin", ""))
        assertEquals("XX", formatLocation("", "XX")) // unknown code passes through
    }
}

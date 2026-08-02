package tunnelbahn.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class CidrParseTest {
    @Test
    fun splitsValidFromInvalid() {
        val (ok, bad) = parseCidrLines("10.0.0.0/8\n not-a-cidr \n192.168.1.0/24\n999.1.1.1/8")
        assertEquals(listOf("10.0.0.0/8", "192.168.1.0/24"), ok)
        assertEquals(listOf("not-a-cidr", "999.1.1.1/8"), bad)
    }

    @Test
    fun acceptsIpv6AndRejectsBadPrefix() {
        val (ok, bad) = parseCidrLines("2001:db8::/32\n10.0.0.0/33\n10.0.0.0/-1")
        assertEquals(listOf("2001:db8::/32"), ok)
        assertEquals(listOf("10.0.0.0/33", "10.0.0.0/-1"), bad)
    }

    @Test
    fun ignoresBlankLines() {
        val (ok, bad) = parseCidrLines("\n  \n10.0.0.0/8\n\n")
        assertEquals(listOf("10.0.0.0/8"), ok)
        assertEquals(emptyList<String>(), bad)
    }
}

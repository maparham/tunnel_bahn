package tunnelbahn.app.ui

import java.util.Locale
import kotlin.math.max

/** Formats a byte/second rate as B/s, KB/s, or MB/s. One decimal at KB/s and above. */
fun humanizeSpeed(bytesPerSec: Long): String {
    val b = max(0L, bytesPerSec)
    return when {
        b < 1024 -> "$b B/s"
        b < 1024L * 1024 -> String.format(Locale.US, "%.1f KB/s", b / 1024.0)
        else -> String.format(Locale.US, "%.1f MB/s", b / (1024.0 * 1024.0))
    }
}

/** Rate in bytes/second between two cumulative counters over a measured interval, clamped
 *  at 0 so a counter reset (new session) or the first sample never renders a negative speed.
 *  Dividing by the actual elapsed time (rather than assuming a fixed tick) keeps the reading
 *  steady when the poll drifts, matching the desktop app. elapsedMs is floored at 1 to avoid
 *  divide-by-zero on a degenerate back-to-back sample. */
fun bytesPerSecond(prevBytes: Long, curBytes: Long, elapsedMs: Long): Long {
    val delta = max(0L, curBytes - prevBytes)
    return delta * 1000L / max(1L, elapsedMs)
}

/** Builds a short "City, Country" label. Maps an ISO 3166 alpha-2 code to a display
 *  country name via Locale; an unknown code passes through unchanged. */
fun formatLocation(city: String, countryCode: String): String {
    val country = if (countryCode.length == 2) {
        Locale("", countryCode).displayCountry.ifBlank { countryCode }
    } else {
        countryCode
    }
    return listOf(city, country).filter { it.isNotBlank() }.joinToString(", ")
}

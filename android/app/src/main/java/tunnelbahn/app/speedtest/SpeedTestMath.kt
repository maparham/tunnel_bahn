package tunnelbahn.app.speedtest

import kotlin.math.abs

/** Megabits per second from a byte count over a wall-clock window. Zero for a non-positive window. */
fun throughputMbps(bytes: Long, seconds: Double): Double =
    if (seconds <= 0) 0.0 else bytes * 8.0 / seconds / 1_000_000.0

/**
 * Converts cumulative (offsetSeconds, bytes) snapshots into per-interval instantaneous rates.
 * The first interval is measured from (0, 0). Snapshots that do not advance time are skipped.
 */
fun throughputSeries(cumulative: List<Pair<Double, Long>>): List<ThroughputSample> {
    val out = ArrayList<ThroughputSample>(cumulative.size)
    var lastTime = 0.0
    var lastBytes = 0L
    for ((offset, bytes) in cumulative) {
        val dt = offset - lastTime
        if (dt <= 0) continue
        out.add(ThroughputSample(offset, throughputMbps(bytes - lastBytes, dt)))
        lastTime = offset
        lastBytes = bytes
    }
    return out
}

/** Signed percentage change of tunnel relative to the direct baseline; null when baseline is 0. */
fun deltaPercent(tunnel: Double, direct: Double): Double? =
    if (direct == 0.0) null else (tunnel - direct) / direct * 100.0

enum class DeltaSense { Better, Worse, Neutral }

/** Classifies a signed delta for display; magnitudes at or below neutralBand are noise. */
fun deltaSense(delta: Double, lowerIsBetter: Boolean, neutralBand: Double): DeltaSense {
    if (abs(delta) <= neutralBand) return DeltaSense.Neutral
    val improved = if (lowerIsBetter) delta < 0 else delta > 0
    return if (improved) DeltaSense.Better else DeltaSense.Worse
}

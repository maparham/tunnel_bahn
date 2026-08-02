package tunnelbahn.app.ui

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Tactile feedback for connection outcomes. Success is one firm pulse; failure is a
 * distinct triple buzz so the two feel clearly different without looking at the screen.
 */
object Haptics {

    fun success(ctx: Context) = vibrate(ctx, longArrayOf(0, 120))

    fun failure(ctx: Context) = vibrate(ctx, longArrayOf(0, 60, 60, 60, 60, 60))

    private fun vibrate(ctx: Context, timings: LongArray) {
        val vib = vibrator(ctx) ?: return
        if (!vib.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vib.vibrate(VibrationEffect.createWaveform(timings, -1))
        } else {
            @Suppress("DEPRECATION")
            vib.vibrate(timings, -1)
        }
    }

    private fun vibrator(ctx: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val mgr = ctx.getSystemService(VibratorManager::class.java)
            mgr?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
}

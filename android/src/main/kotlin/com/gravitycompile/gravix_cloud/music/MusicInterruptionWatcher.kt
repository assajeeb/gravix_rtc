package com.gravitycompile.gravix_cloud.music

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Reports a phone call (cellular or another app's call) while room music plays,
 * without READ_PHONE_STATE: the audio mode turns RINGTONE / IN_CALL /
 * CALL_SCREENING / CALL_REDIRECT. MODE_IN_COMMUNICATION is not a call signal
 * (the room itself runs in it).
 *
 * Android 12+: AudioManager.addOnModeChangedListener. Older: a 500 ms poll of
 * AudioManager.mode on the main looper, only while music is active.
 */
class MusicInterruptionWatcher(
    context: Context,
    private val onCallChanged: (inCall: Boolean) -> Unit,
) {
    private val am = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var inCall = false
    private var running = false
    private var modeListener: Any? = null

    private val poll = object : Runnable {
        override fun run() {
            if (!running) return
            onMode(am.mode)
            main.postDelayed(this, 500)
        }
    }

    fun start() {
        if (running) return
        running = true
        inCall = isCallMode(am.mode)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val l = AudioManager.OnModeChangedListener { mode -> onMode(mode) }
                am.addOnModeChangedListener({ r -> main.post(r) }, l)
                modeListener = l
                return
            } catch (e: Throwable) {
                Log.w(TAG, "mode listener unavailable, polling: $e")
            }
        }
        main.postDelayed(poll, 500)
    }

    fun stop() {
        running = false
        main.removeCallbacks(poll)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let {
                runCatching { am.removeOnModeChangedListener(it) }
            }
        }
        modeListener = null
    }

    private fun onMode(mode: Int) {
        if (!running) return
        val call = isCallMode(mode)
        if (call == inCall) return
        inCall = call
        onCallChanged(call)
    }

    companion object {
        private const val TAG = "GxMusicInterrupt"

        fun isCallMode(mode: Int): Boolean =
            mode == AudioManager.MODE_RINGTONE ||
                mode == AudioManager.MODE_IN_CALL ||
                mode == 4 /* MODE_CALL_SCREENING (API 30) */ ||
                mode == 5 /* MODE_CALL_REDIRECT (API 33) */
    }
}

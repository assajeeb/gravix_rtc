package com.gravitycompile.gravix_cloud.music

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer
import kotlin.math.sqrt

/**
 * The per-buffer mixing math, free of Android types so it is unit-tested on the
 * JVM (MusicMixKernelTest).
 *
 *   out = clip(voice * micGain + music * musicGain * duck * env)
 *
 *  - env: a linear fade (0..1) moved toward [envTarget] by one step per sample,
 *    [rampSamples] samples for a full 0<->1 swing (~20 ms): start, pause, resume,
 *    stop and track switches never click.
 *  - duck: with [ducking] on, the music gain follows [duckLevel] while the voice
 *    is above [duckThresholdRms] (attack ~30 ms, release ~400 ms, per buffer).
 *  - musicGain changes are smoothed per buffer too (no zipper noise on a slider).
 *
 * Not thread-safe: only the capture thread calls [mix]; control fields are
 * volatile and read once per buffer.
 */
class MusicMixKernel {
    @Volatile var micGain: Float = 1f
    @Volatile var musicGain: Float = 1f
    @Volatile var ducking: Boolean = false
    @Volatile var duckLevel: Float = 0.35f
    @Volatile var envTarget: Float = 1f

    var rampSamples: Int = 960
    var duckThresholdRms: Double = 700.0

    /** Current fade position (0..1). */
    var env: Float = 0f
        private set

    /** Current (smoothed) ducking multiplier (duckLevel..1). */
    var duck: Float = 1f
        private set

    private var smoothedMusicGain: Float = -1f

    /** Last buffer's voice RMS (before micGain), for tests and logs. */
    var lastVoiceRms: Double = 0.0
        private set

    companion object {
        /**
         * Native-order 16-bit view over ALL of [buffer], whatever its position
         * and limit: WebRtcAudioRecord's module mute rewrites the buffer with a
         * relative put, which leaves the position at the end.
         */
        fun wholeShortView(buffer: ByteBuffer): ShortBuffer {
            val whole = buffer.duplicate()
            whole.clear()
            return whole.order(ByteOrder.nativeOrder()).asShortBuffer()
        }
    }

    fun reset(startEnv: Float) {
        env = startEnv
        duck = 1f
        smoothedMusicGain = -1f
    }

    /**
     * Mixes [n] samples of [music] (pre-gain) into [voice] in place.
     * [musicOut] (size >= n) receives the scaled music actually mixed, for the
     * host's monitor. [music] == null mixes nothing (voice gain only).
     * [buffersPerSecond] sizes the ducking time constants.
     */
    fun mix(
        voice: ShortArray,
        music: ShortArray?,
        musicOut: ShortArray?,
        n: Int,
        buffersPerSecond: Int = 100,
    ) {
        val mg = micGain
        // voice level BEFORE gain: a muted (zeroed) voice never ducks
        var acc = 0.0
        for (i in 0 until n) { val v = voice[i].toDouble(); acc += v * v }
        lastVoiceRms = if (n > 0) sqrt(acc / n) else 0.0

        // ducking envelope, one step per buffer
        val duckTarget = if (ducking && lastVoiceRms > duckThresholdRms) duckLevel.coerceIn(0f, 1f) else 1f
        val attack = (1f / (0.03f * buffersPerSecond)).coerceAtMost(1f)  // ~30 ms
        val release = (1f / (0.4f * buffersPerSecond)).coerceAtMost(1f)  // ~400 ms
        duck = if (duckTarget < duck) {
            (duck - attack).coerceAtLeast(duckTarget)
        } else {
            (duck + release).coerceAtMost(duckTarget)
        }

        // music gain smoothing: halfway to the target per buffer
        val target = musicGain.coerceIn(0f, 2f)
        smoothedMusicGain = if (smoothedMusicGain < 0f) target else smoothedMusicGain + (target - smoothedMusicGain) * 0.5f
        if (kotlin.math.abs(smoothedMusicGain - target) < 0.001f) smoothedMusicGain = target

        val step = 1f / rampSamples.coerceAtLeast(1)
        val et = envTarget
        val g = smoothedMusicGain * duck
        for (i in 0 until n) {
            var e = env
            if (e < et) { e += step; if (e > et) e = et } else if (e > et) { e -= step; if (e < et) e = et }
            env = e
            val v = if (mg == 1f) voice[i].toInt() else (voice[i] * mg).toInt()
            val m = if (music == null) 0 else (music[i] * g * e).toInt()
            if (musicOut != null) musicOut[i] = m.coerceIn(-32768, 32767).toShort()
            voice[i] = (v + m).coerceIn(-32768, 32767).toShort()
        }
    }
}

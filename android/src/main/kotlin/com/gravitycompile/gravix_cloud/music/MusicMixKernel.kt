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

    /**
     * Route-switch fade (voice effect toggled mid-song, MusicCaptureRouter):
     * a second linear fade, same [rampSamples], independent of [envTarget]
     * (pause/stop own that one). At 1 with target 1, [mix] runs its original
     * loop untouched.
     */
    @Volatile var gateTarget: Float = 1f
    var gate: Float = 1f
        private set

    private var smoothedMusicGain: Float = -1f

    /** music gain * duck of the last [voicePass], used by [postMusic]. */
    private var passGain: Float = 1f

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
        gate = 1f
        gateTarget = 1f
    }

    /** Snaps the route-switch fade (a fallback with no audible music in flight). */
    fun snapGate(value: Float) { gate = value }

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
        perBuffer(voice, n, buffersPerSecond)

        val step = 1f / rampSamples.coerceAtLeast(1)
        val et = envTarget
        val g = smoothedMusicGain * duck
        if (gate != 1f || gateTarget != 1f) {
            // route switch in progress: the same loop with the switch fade
            val gt = gateTarget
            for (i in 0 until n) {
                var e = env
                if (e < et) { e += step; if (e > et) e = et } else if (e > et) { e -= step; if (e < et) e = et }
                env = e
                var q = gate
                if (q < gt) { q += step; if (q > gt) q = gt } else if (q > gt) { q -= step; if (q < gt) q = gt }
                gate = q
                val v = if (mg == 1f) voice[i].toInt() else (voice[i] * mg).toInt()
                val m = if (music == null) 0 else (music[i] * g * e * q).toInt()
                if (musicOut != null) musicOut[i] = m.coerceIn(-32768, 32767).toShort()
                voice[i] = (v + m).coerceIn(-32768, 32767).toShort()
            }
            return
        }
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

    /** Voice RMS (before gain), ducking envelope and music-gain smoothing: one step per buffer. */
    private fun perBuffer(voice: ShortArray, n: Int, buffersPerSecond: Int) {
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
    }

    /**
     * Post-mix route, first half (pre-APM capture callback): the raw voice
     * sets the ducking (same threshold as [mix]) and gets [micGain], in place.
     * The fades do not move; [postMusic] steps them at the post site.
     */
    fun voicePass(voice: ShortArray, n: Int, buffersPerSecond: Int = 100) {
        val mg = micGain
        perBuffer(voice, n, buffersPerSecond)
        passGain = smoothedMusicGain * duck
        if (mg != 1f) {
            for (i in 0 until n) voice[i] = (voice[i] * mg).toInt().coerceIn(-32768, 32767).toShort()
        }
    }

    /**
     * Post-mix route, second half: the music to add after the voice effect,
     * [n] samples of [music] (null = silence) into [musicOut] with the gains
     * of the last [voicePass] and the same fades and rounding as [mix]
     * (MusicCaptureRouter delays it and adds it to the frame).
     */
    fun postMusic(music: ShortArray?, musicOut: ShortArray, n: Int) {
        val step = 1f / rampSamples.coerceAtLeast(1)
        val et = envTarget
        val gt = gateTarget
        val g = passGain
        for (i in 0 until n) {
            var e = env
            if (e < et) { e += step; if (e > et) e = et } else if (e > et) { e -= step; if (e < et) e = et }
            env = e
            var q = gate
            if (q < gt) { q += step; if (q > gt) q = gt } else if (q > gt) { q -= step; if (q < gt) q = gt }
            gate = q
            val m = if (music == null) 0 else (music[i] * g * e * q).toInt()
            musicOut[i] = m.coerceIn(-32768, 32767).toShort()
        }
    }
}

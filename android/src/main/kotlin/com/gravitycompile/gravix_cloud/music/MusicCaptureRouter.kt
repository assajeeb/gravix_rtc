package com.gravitycompile.gravix_cloud.music

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer

/**
 * Where the room music joins the capture stream (Android types free, so it is
 * unit-tested on the JVM: MusicCaptureRouterTest).
 *
 *  - PRE (default, and always with no voice effect): mixed into the
 *    WebRtcAudioRecord buffer before WebRTC's APM, exactly as before this
 *    class existed. The voice effect is bypassed (dry) so the music is never
 *    pitch shifted.
 *  - POST (a voice effect is on): the pre-APM callback only consumes the ring
 *    (position, completion, mic gain, ducking level) and hands the samples to
 *    the APM capturePostProcessing processor, which adds them AFTER the
 *    effect. The effect stays on the voice and never touches the music.
 *
 * SYNC: on POST the voice reaches the post site later than the music by the
 * noise suppressor's and the effect chain's delay; the music goes through a
 * delay line of that length ([delayTargetSamples], set by the control side
 * from gx_ns / gx_fx status), so listeners hear both as on PRE. The host's
 * monitor is not delayed (as on PRE). A delay change (effect switched) fades
 * the music out, re-times while silent, and fades it back in.
 *
 * LEVEL: the post-site music is the kernel's output unchanged (file level x
 * music volume), the same level PRE gives whenever WebRTC's AGC/NS are off,
 * which GravixRoomMusic does for every session (relaxVoiceProcessing). With
 * WebRTC's AGC left on (raw peers, relaxVoiceProcessing=false) PRE music is
 * lifted by the AGC and POST is not.
 *
 * One mix site per buffer. A mid-song switch fades the music out at the old
 * site (MusicMixKernel.gate, ~20 ms), waits for the delay line to drain,
 * flips, and fades it in at the new one. PRE -> POST keeps the effect bypassed
 * until the pre-mixed music has drained out of NS and the effect chain. The
 * hand-off to the post site is a one-shot token: when the processor does not
 * run (not installed, APM shape changed), the next capture callback falls
 * back to PRE. A capture restart (mic republish: a gap of > 100 ms between
 * capture callbacks) discards the token without falling back.
 *
 * Threads: [pre] and [post] run on WebRTC's record thread (the APM runs
 * synchronously inside the record callback); [begin]/[end] and the volatile
 * inputs on the control thread.
 */
class MusicCaptureRouter(private val kernel: MusicMixKernel) {

    enum class Route { PRE, POST }

    /** The playing track, as the router needs it. */
    interface Track {
        /** Not consuming (paused). */
        val paused: Boolean
        /** Ring read + position bookkeeping; returns the samples read. */
        fun read(dst: ShortArray, n: Int): Int
        /** [read] returned less than asked (underrun / end of track). */
        fun onShort(got: Int)
        /** The exact music samples mixed (host monitor). */
        fun monitor(musicOut: ShortArray, n: Int)
        /** The fade envelope reached 0 (pause / stop requests complete). */
        fun onEnvZero()
    }

    /** The voice-effect side: bypass = music is in the pre-APM buffer. */
    interface Fx {
        fun setMusicBypass(on: Boolean)
    }

    companion object {
        const val MAX_DELAY = 8192 // samples (170 ms at 48 kHz)
        private const val LINE = 16384
        private const val MASK = LINE - 1
        private const val GAP_NS = 100_000_000L
    }

    /** A voice effect (not "none") is configured. Control thread. */
    @Volatile var effectWanted: Boolean = false

    /**
     * Voice delay between the capture callback and the post site (NS + effect
     * chain), in samples at the capture rate. Control thread; -1 = unknown.
     */
    @Volatile var delayTargetSamples: Int = -1

    @Volatile var fx: Fx? = null

    @Volatile var route: Route = Route.PRE
        private set

    /** Hand-offs the post site never took (processor not running). */
    @Volatile var droppedTokens: Int = 0
        private set

    /** Route flips (logs). */
    @Volatile var switches: Int = 0
        private set

    /** Capture restarts seen (gaps), delay re-timings (logs). */
    @Volatile var captureGaps: Int = 0
        private set
    @Volatile var retimes: Int = 0
        private set

    /** Music delay in use on POST, samples. */
    @Volatile var delaySamples: Int = 0
        private set

    // ---- post-site shape, written by [post] ----
    @Volatile private var postFrames = 0
    @Volatile private var postShapeOk = false
    @Volatile private var postLastNs = 0L
    private var preSincePost = Int.MAX_VALUE / 2
    private var lastPreNs = 0L

    // ---- record-thread state ----
    private var switching = false
    private var retiming = false
    private var bypassHoldBuffers = 0
    private var tokenPending = false
    private var tokenHasMusic = false
    private var tokenN = 0
    private var tokenTrack: Track? = null
    private var voice = ShortArray(0)
    private var music = ShortArray(0)
    private var musicOut = ShortArray(0)
    private var postMusic = ShortArray(0)
    private var postMusicOut = ShortArray(0)
    private val line = ShortArray(LINE)
    private var lineW = 0
    /** Consecutive zero samples written to the delay line (drained when >= [delaySamples]). */
    private var zeroRun = Int.MAX_VALUE / 2

    /**
     * The post site ran recently with a frame that can take a [rate]/[channels]
     * track one-to-one: mono, 10 ms frames at the same rate. Any thread.
     */
    fun postCompatible(rate: Int, channels: Int, nowNs: Long = System.nanoTime()): Boolean =
        channels == 1 && postShapeOk && postFrames * 100 == rate &&
            postLastNs != 0L && nowNs - postLastNs < 500_000_000L

    /** For logs and getState: why the route is what it is. */
    fun describe(): String =
        "route=$route effect=$effectWanted postFrames=$postFrames postOk=$postShapeOk " +
            "postAgeMs=${if (postLastNs == 0L) -1 else (System.nanoTime() - postLastNs) / 1_000_000} " +
            "delay=$delaySamples/$delayTargetSamples switches=$switches dropped=$droppedTokens " +
            "gaps=$captureGaps retimes=$retimes"

    private fun target(): Int = delayTargetSamples.coerceIn(0, MAX_DELAY)

    /** Session start (control thread, before the first [pre]). */
    fun begin(rate: Int, channels: Int) {
        tokenPending = false
        tokenTrack = null
        switching = false
        retiming = false
        bypassHoldBuffers = 0
        preSincePost = 0
        lastPreNs = 0L
        route = if (effectWanted && postCompatible(rate, channels)) Route.POST else Route.PRE
        if (route == Route.POST) retimeIfDrained()
        fx?.setMusicBypass(route == Route.PRE)
    }

    /**
     * Session end (control thread, after the fade-out). The delay line keeps
     * draining its faded tail at the post site.
     */
    fun end() {
        tokenPending = false
        tokenTrack = null
        switching = false
        retiming = false
        bypassHoldBuffers = 0
        route = Route.PRE
        fx?.setMusicBypass(false)
    }

    /**
     * Pre-APM capture callback for one buffer of [samples] 16-bit samples in
     * [sb] (a view over the whole buffer). [channels]/[sampleRate] = capture
     * format, [bps] = buffers per second.
     */
    fun pre(
        sb: ShortBuffer, samples: Int, channels: Int, sampleRate: Int, bps: Int, t: Track,
        nowNs: Long = System.nanoTime(),
    ) {
        if (voice.size != samples) {
            voice = ShortArray(samples)
            music = ShortArray(samples)
            musicOut = ShortArray(samples)
        }
        val gap = lastPreNs != 0L && nowNs - lastPreNs > GAP_NS
        lastPreNs = nowNs
        if (gap) {
            // capture restart (mic republish, track change): the post site stopped with
            // the capture; whatever it was handed last is stale, it is not dead
            if (tokenPending) {
                tokenPending = false
                tokenTrack = null
            }
            captureGaps++
            preSincePost = 0
        } else if (tokenPending) {
            // the post site never took the last buffer: it is not running
            tokenPending = false
            tokenTrack = null
            droppedTokens++
            preSincePost = Int.MAX_VALUE / 2
        }
        if (preSincePost < Int.MAX_VALUE / 2) preSincePost++
        val alive = preSincePost <= 3
        val shapeOk = channels == 1 && postShapeOk && postFrames == samples && postFrames * 100 == sampleRate
        val want = effectWanted && alive && shapeOk

        if (route == Route.POST && (!alive || !shapeOk)) {
            // the processor stopped or its frame no longer fits (it drops our tokens):
            // back to PRE right away (nothing of ours is in flight there)
            switching = false
            retiming = false
            flip(Route.PRE)
            kernel.snapGate(0f)
            kernel.gateTarget = 1f
        } else if (route == Route.POST && !want && !switching) {
            switching = true // fades out at the post site, flips there
            kernel.gateTarget = 0f
        } else if (route == Route.PRE && want && !switching) {
            switching = true
            kernel.gateTarget = 0f
        } else if (switching && want == (route == Route.POST)) {
            switching = false // changed its mind mid-fade: fade back in where we are
            kernel.gateTarget = if (retiming) 0f else 1f
        }
        if (route == Route.POST && !switching && !retiming && target() != delaySamples) {
            retiming = true // the effect's delay changed: fade out, re-time while silent, fade in
            kernel.gateTarget = 0f
            retimes++
        }

        sb.get(voice, 0, samples)
        val consuming = !t.paused
        if (consuming) {
            val got = t.read(music, samples)
            if (got < samples) {
                // underrun or end of track: pad the tail with silence
                java.util.Arrays.fill(music, got, samples, 0)
                t.onShort(got)
            }
        }

        if (route == Route.PRE) {
            kernel.mix(voice, if (consuming) music else null, musicOut, samples, bps)
            sb.position(0)
            sb.put(voice, 0, samples)
            if (consuming) {
                t.monitor(musicOut, samples)
                if (kernel.env == 0f) t.onEnvZero()
            }
            if (switching && kernel.gate == 0f) {
                switching = false
                flip(Route.POST)
                kernel.gateTarget = 1f
                retimeIfDrained()
                // the effect stays dry until the music mixed so far has left NS + the chain
                val ms = (if (delayTargetSamples >= 0) delayTargetSamples * 1000 / sampleRate.coerceAtLeast(1) else 50) + 20
                bypassHoldBuffers = ((ms * bps + 999) / 1000).coerceAtLeast(1)
            }
            return
        }

        // POST: the voice keeps its gain and sets the ducking here; the music waits for the post site
        kernel.voicePass(voice, samples, bps)
        if (kernel.micGain != 1f) {
            sb.position(0)
            sb.put(voice, 0, samples)
        }
        if (postMusic.size != samples) {
            postMusic = ShortArray(samples)
            postMusicOut = ShortArray(samples)
        }
        if (consuming) System.arraycopy(music, 0, postMusic, 0, samples)
        tokenHasMusic = consuming
        tokenN = samples
        tokenTrack = t
        tokenPending = true
    }

    /**
     * APM capturePostProcessing, after the voice effect: [frame] = [numFrames]
     * int16-scale floats, [channels] from the APM's initialize (0 = unknown).
     */
    fun post(frame: ByteBuffer, numFrames: Int, channels: Int, nowNs: Long = System.nanoTime()) {
        postFrames = numFrames
        postShapeOk = frame.isDirect && channels <= 1 && frame.capacity() == numFrames * 4
        postLastNs = nowNs
        preSincePost = 0
        if (!tokenPending) {
            // no music handed over: the delay line's tail (a fade-out) still plays out
            if (zeroRun < delaySamples && postShapeOk) {
                if (postMusicOut.size < numFrames) postMusicOut = ShortArray(numFrames)
                java.util.Arrays.fill(postMusicOut, 0, numFrames, 0)
                addDelayed(frame, postMusicOut, numFrames)
            }
            return
        }
        tokenPending = false
        val t = tokenTrack
        tokenTrack = null
        if (t == null || numFrames != tokenN || !postShapeOk) {
            droppedTokens++
            return
        }
        val n = tokenN
        kernel.postMusic(if (tokenHasMusic) postMusic else null, postMusicOut, n)
        if (tokenHasMusic) {
            t.monitor(postMusicOut, n) // the host hears it undelayed, as on PRE
            if (kernel.env == 0f) t.onEnvZero()
        }
        addDelayed(frame, postMusicOut, n)
        if (bypassHoldBuffers > 0 && --bypassHoldBuffers == 0) fx?.setMusicBypass(false)
        val silent = kernel.gate == 0f && zeroRun >= delaySamples
        if (switching && silent) {
            switching = false
            retiming = false
            flip(Route.PRE)
            kernel.gateTarget = 1f
        } else if (retiming && silent) {
            retiming = false
            retimeIfDrained()
            kernel.gateTarget = 1f
        }
    }

    /**
     * Takes the current target delay once the line's audible content has
     * played out; the line is cleared so a longer delay never replays old music.
     */
    private fun retimeIfDrained() {
        if (zeroRun < delaySamples) return
        java.util.Arrays.fill(line, 0)
        zeroRun = Int.MAX_VALUE / 2
        delaySamples = target()
    }

    /** Writes [m] into the delay line and adds the line's output, [delaySamples] back, to [frame]. */
    private fun addDelayed(frame: ByteBuffer, m: ShortArray, n: Int) {
        val order = frame.order()
        frame.order(ByteOrder.nativeOrder())
        val d = delaySamples
        var w = lineW
        var z = zeroRun
        for (i in 0 until n) {
            val s = m[i]
            line[w] = s
            if (s.toInt() == 0) { if (z < Int.MAX_VALUE / 2) z++ } else z = 0
            val out = line[(w - d) and MASK].toInt()
            w = (w + 1) and MASK
            if (out != 0) {
                val at = i * 4
                frame.putFloat(at, (frame.getFloat(at) + out).coerceIn(-32768f, 32767f))
            }
        }
        lineW = w
        zeroRun = z
        frame.order(order)
    }

    private fun flip(to: Route) {
        route = to
        switches++
        bypassHoldBuffers = 0
        // PRE: dry right away (the next music enters the chain >= 10 ms later);
        // POST: released by [post] after the drain
        if (to == Route.PRE) fx?.setMusicBypass(true)
    }
}

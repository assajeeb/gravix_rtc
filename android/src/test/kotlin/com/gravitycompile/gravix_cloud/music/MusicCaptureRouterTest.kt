package com.gravitycompile.gravix_cloud.music

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The capture chain as WebRTC runs it, with a stand-in effect:
 *   pre-APM callback (router.pre) -> int16 -> int16-scale float ("APM")
 *   -> effect (ring modulation at 300 Hz: moves every partial, like a pitch
 *      shift; dry while bypassed) -> post-processing (router.post).
 */
class MusicCaptureRouterTest {
    private val rate = 48000
    private val n = 480

    private class FakeTrack(val sample: (Long) -> Short) : MusicCaptureRouter.Track {
        var pos = 0L
        override var paused = false
        var envZero = 0
        override fun read(dst: ShortArray, n: Int): Int {
            for (i in 0 until n) dst[i] = sample(pos + i)
            pos += n
            return n
        }
        override fun onShort(got: Int) {}
        override fun monitor(musicOut: ShortArray, n: Int) {}
        override fun onEnvZero() { envZero++ }
    }

    private class FakeFx : MusicCaptureRouter.Fx {
        var bypass = false
        val log = ArrayList<Boolean>()
        override fun setMusicBypass(on: Boolean) { bypass = on; log.add(on) }
    }

    private inner class Chain(val effect: Boolean = true) {
        val kernel = MusicMixKernel().apply { rampSamples = rate / 50 }
        val router = MusicCaptureRouter(kernel)
        val fx = FakeFx()
        var t = 0L // effect phase, samples
        var postRuns = true
        var now = System.nanoTime() // record-thread clock: 10 ms per buffer

        init {
            router.fx = fx
            router.effectWanted = effect
        }

        /** One 10 ms buffer through the chain; returns the int16-scale output. */
        fun step(voice: ShortArray, track: FakeTrack?): FloatArray {
            val pcm = ByteBuffer.allocateDirect(n * 2).order(ByteOrder.nativeOrder())
            pcm.asShortBuffer().put(voice)
            now += 10_000_000L
            if (track != null) router.pre(MusicMixKernel.wholeShortView(pcm), n, 1, rate, 100, track, now)
            // "APM": the frame WebRTC hands to capturePostProcessing. Default (big-endian)
            // order on the Java side, native floats in memory, like JNI's NewDirectByteBuffer.
            val frame = ByteBuffer.allocateDirect(n * 4)
            val nat = frame.duplicate().order(ByteOrder.nativeOrder())
            val sv = MusicMixKernel.wholeShortView(pcm)
            for (i in 0 until n) nat.putFloat(i * 4, sv.get(i).toFloat())
            if (effect && !fx.bypass) {
                for (i in 0 until n) {
                    val g = cos(2 * PI * 300.0 * (t + i) / rate).toFloat()
                    nat.putFloat(i * 4, nat.getFloat(i * 4) * g)
                }
            }
            t += n
            if (postRuns) router.post(frame, n, 1, now)
            assertEquals(ByteOrder.BIG_ENDIAN, frame.order()) // restored
            return FloatArray(n) { nat.getFloat(it * 4) }
        }

        /** Teaches the router the post-site shape (as the processor does before music starts). */
        fun warm() { repeat(3) { step(ShortArray(n), null) } }
    }

    private fun sine(f: Double, amp: Double) = { i: Long -> (amp * sin(2 * PI * f * i / 48000)).toInt().toShort() }

    private fun goertzel(x: FloatArray, f: Double): Double {
        val w = 2 * PI * f / rate
        val c = 2 * cos(w)
        var s1 = 0.0
        var s2 = 0.0
        for (v in x) { val s0 = v + c * s1 - s2; s2 = s1; s1 = s0 }
        val p = s1 * s1 + s2 * s2 - c * s1 * s2
        return 2 * sqrt(abs(p)) / x.size // amplitude of the tone
    }

    private fun rms(x: FloatArray): Double = sqrt(x.sumOf { it.toDouble() * it } / x.size)

    @Test
    fun withAnEffectTheMusicComesOutUnalteredAtFullLevel() {
        val c = Chain()
        c.warm()
        c.router.begin(rate, 1)
        assertEquals(MusicCaptureRouter.Route.POST, c.router.route)
        assertFalse("the effect must stay on", c.fx.bypass)
        val track = FakeTrack(sine(1000.0, 8000.0))
        val out = ArrayList<Float>()
        repeat(100) { out.addAll(c.step(ShortArray(n), track).toList()) } // music only, 1 s
        val tail = out.subList(48000 / 2, out.size).toFloatArray()
        val ref = FloatArray(tail.size) { sine(1000.0, 8000.0)((48000 / 2 + it).toLong()).toFloat() }
        var maxErr = 0f
        for (i in tail.indices) maxErr = maxOf(maxErr, abs(tail[i] - ref[i]))
        assertTrue("music sample error $maxErr", maxErr <= 1f)
        // level: an 8000-peak sine is 5657 RMS; nothing at the effect's 700 / 1300 Hz sidebands
        assertEquals(5657.0, rms(tail), 30.0)
        assertEquals(8000.0, goertzel(tail, 1000.0), 40.0)
        assertTrue(goertzel(tail, 700.0) < 20.0)
        assertTrue(goertzel(tail, 1300.0) < 20.0)
    }

    @Test
    fun theVoiceKeepsTheEffectWhileMusicPlays() {
        val c = Chain()
        c.warm()
        c.router.begin(rate, 1)
        val track = FakeTrack(sine(1000.0, 8000.0))
        val voice = sine(200.0, 6000.0)
        val out = ArrayList<Float>()
        var vi = 0L
        repeat(100) {
            val v = ShortArray(n) { voice(vi + it) }
            vi += n
            out.addAll(c.step(v, track).toList())
        }
        val tail = out.subList(24000, out.size).toFloatArray()
        // the voice (200 Hz) is ring-modulated to 100 / 500 Hz; the dry 200 Hz is gone
        assertTrue("dry voice left: ${goertzel(tail, 200.0)}", goertzel(tail, 200.0) < 30.0)
        assertEquals(3000.0, goertzel(tail, 500.0), 60.0)
        assertEquals(3000.0, goertzel(tail, 100.0), 60.0)
        // the music rides next to it at its own level
        assertEquals(8000.0, goertzel(tail, 1000.0), 40.0)
    }

    @Test
    fun negativeControlMusicBeforeTheEffectIsAltered() {
        // what the post route avoids: the same music mixed pre-APM through a live effect
        val c = Chain()
        c.router.effectWanted = false
        c.warm()
        c.router.begin(rate, 1)
        assertEquals(MusicCaptureRouter.Route.PRE, c.router.route)
        assertTrue("pre route must bypass the effect", c.fx.bypass)
        c.fx.bypass = false // force the old bug
        val track = FakeTrack(sine(1000.0, 8000.0))
        val out = ArrayList<Float>()
        repeat(100) { out.addAll(c.step(ShortArray(n), track).toList()) }
        val tail = out.subList(24000, out.size).toFloatArray()
        assertTrue(goertzel(tail, 1000.0) < 40.0)
        assertTrue(goertzel(tail, 1300.0) > 3000.0)
    }

    @Test
    fun withoutAnEffectThePreRouteIsByteIdenticalToTheKernel() {
        val c = Chain(effect = false)
        c.warm()
        c.router.begin(rate, 1)
        val ref = MusicMixKernel().apply { rampSamples = rate / 50; ducking = true; micGain = 0.8f }
        c.kernel.ducking = true
        c.kernel.micGain = 0.8f
        val track = FakeTrack(sine(440.0, 12000.0))
        val music = sine(440.0, 12000.0)
        val voice = sine(150.0, 9000.0)
        var p = 0L
        repeat(60) {
            val v = ShortArray(n) { voice(p + it) }
            val mine = ByteBuffer.allocateDirect(n * 2).order(ByteOrder.nativeOrder())
            mine.asShortBuffer().put(v)
            c.now += 10_000_000L
            c.router.pre(MusicMixKernel.wholeShortView(mine), n, 1, rate, 100, track, c.now)
            val expect = v.copyOf()
            ref.mix(expect, ShortArray(n) { music(p + it) }, ShortArray(n), n, 100)
            val got = ShortArray(n).also { MusicMixKernel.wholeShortView(mine).get(it) }
            assertArrayEquals("buffer $it", expect, got)
            p += n
        }
    }

    @Test
    fun effectToggledMidSongNeverDoublesOrDropsTheMusic() {
        val c = Chain()
        c.router.effectWanted = false
        c.warm()
        c.router.begin(rate, 1)
        val track = FakeTrack { 10000 } // DC: a double mix shows as 20000, a gap as 0
        val levels = ArrayList<FloatArray>()
        for (b in 0 until 300) {
            if (b == 100) c.router.effectWanted = true
            if (b == 200) c.router.effectWanted = false
            levels.add(c.step(ShortArray(n), track))
        }
        assertEquals("every buffer consumed once", 300L * n, track.pos)
        assertEquals(2, c.router.switches)
        assertEquals(0, c.router.droppedTokens)
        assertEquals(MusicCaptureRouter.Route.PRE, c.router.route)
        for ((b, buf) in levels.withIndex()) {
            for (v in buf) assertTrue("buffer $b level $v", v in -0.5f..10000.5f)
            val inSwitch = b in 100..106 || b in 200..206
            if (b >= 5 && !inSwitch) assertEquals("buffer $b", 10000f, buf[n - 1], 0.5f)
        }
        // the dip is a fade (<= 1 LSB-ish steps of 10000/960), never a jump
        val flat = levels.flatMap { it.toList() }
        for (i in 48000 / 20 until flat.size) assertTrue("jump at $i", abs(flat[i] - flat[i - 1]) <= 10000f / 960f + 1f)
        // bypass: on (pre) -> off once the pre-mixed music drained -> on again (pre)
        assertEquals(listOf(true, false, true), c.fx.log)
    }

    @Test
    fun processorNotRunningFallsBackToThePreRoute() {
        val c = Chain()
        c.warm()
        c.router.begin(rate, 1)
        assertEquals(MusicCaptureRouter.Route.POST, c.router.route)
        val track = FakeTrack { 10000 }
        repeat(10) { c.step(ShortArray(n), track) }
        c.postRuns = false // processor removed / APM shape changed
        val out = ArrayList<FloatArray>()
        repeat(10) { out.add(c.step(ShortArray(n), track)) }
        assertEquals(MusicCaptureRouter.Route.PRE, c.router.route)
        assertTrue(c.fx.bypass)
        assertEquals(1, c.router.droppedTokens) // one 10 ms buffer lost, then the music is back
        assertEquals(10000f, out.last()[n - 1], 0.5f)
    }

    @Test
    fun apmFrameShapeChangeMidSongFallsBackToThePreRoute() {
        val c = Chain()
        c.warm()
        c.router.begin(rate, 1)
        val track = FakeTrack { 10000 }
        repeat(10) { c.step(ShortArray(n), track) }
        assertEquals(MusicCaptureRouter.Route.POST, c.router.route)
        // the APM re-initialises at 16 kHz: its frame no longer fits the 48 kHz track
        c.now += 10_000_000L
        c.router.post(ByteBuffer.allocateDirect(160 * 4), 160, 1, c.now)
        c.router.pre(MusicMixKernel.wholeShortView(ByteBuffer.allocateDirect(n * 2)), n, 1, rate, 100, track, c.now)
        assertEquals(MusicCaptureRouter.Route.PRE, c.router.route)
        assertTrue(c.fx.bypass)
        c.postRuns = false // keep the post site out of it: its 480-frame shape would re-arm POST
        val out = ArrayList<FloatArray>()
        repeat(5) { out.add(c.step(ShortArray(n), track)) }
        assertEquals(10000f, out.last()[n - 1], 0.5f)
    }

    @Test
    fun postMusicIsDelayedByTheVoiceChainLatency() {
        val c = Chain()
        c.router.delayTargetSamples = 1920 // NS 10 ms + effect 30 ms at 48 kHz
        c.warm()
        c.router.begin(rate, 1)
        assertEquals(1920, c.router.delaySamples)
        c.kernel.reset(1f) // no fade-in: compare sample for sample
        val src = sine(1000.0, 8000.0)
        val track = FakeTrack(src)
        val out = ArrayList<Float>()
        repeat(50) { out.addAll(c.step(ShortArray(n), track).toList()) }
        for (i in 0 until 1920) assertEquals("before the delay $i", 0f, out[i], 0f)
        var maxErr = 0f
        for (i in 1920 until out.size) maxErr = maxOf(maxErr, abs(out[i] - src((i - 1920).toLong())))
        assertTrue("delayed music error $maxErr", maxErr <= 1f)
    }

    @Test
    fun aLatencyChangeRetimesWithAFadeNoJumpNoDoubling() {
        val c = Chain()
        c.router.delayTargetSamples = 1920
        c.warm()
        c.router.begin(rate, 1)
        val track = FakeTrack { 10000 }
        val flat = ArrayList<Float>()
        for (b in 0 until 200) {
            if (b == 80) c.router.delayTargetSamples = 0 // girl -> robot
            if (b == 140) c.router.delayTargetSamples = 2160 // robot -> transformer (45 ms)
            flat.addAll(c.step(ShortArray(n), track).toList())
        }
        assertEquals(2, c.router.retimes)
        assertEquals(2160, c.router.delaySamples)
        assertEquals(MusicCaptureRouter.Route.POST, c.router.route)
        assertEquals(200L * n, track.pos)
        for (v in flat) assertTrue("level $v", v in -0.5f..10000.5f)
        for (i in 4000 until flat.size) assertTrue("jump at $i", abs(flat[i] - flat[i - 1]) <= 10000f / 960f + 1f)
        assertEquals(10000f, flat.last(), 0.5f)
        assertEquals(10000f, flat[120 * n], 0.5f) // back up after the first re-time
    }

    @Test
    fun theDelayedTailPlaysOutAfterStop() {
        val c = Chain()
        c.router.delayTargetSamples = 1920
        c.warm()
        c.router.begin(rate, 1)
        val track = FakeTrack { 10000 }
        repeat(20) { c.step(ShortArray(n), track) }
        c.kernel.envTarget = 0f // stop: fade out
        val flat = ArrayList<Float>()
        repeat(3) { flat.addAll(c.step(ShortArray(n), track).toList()) }
        assertTrue(track.envZero > 0)
        c.router.end()
        repeat(10) { flat.addAll(c.step(ShortArray(n), null).toList()) } // no session: post only
        for (i in 1 until flat.size) assertTrue("jump at $i", abs(flat[i] - flat[i - 1]) <= 10000f / 960f + 1f)
        assertEquals(0f, flat.last(), 0f)
    }

    @Test
    fun aCaptureRestartKeepsThePostRoute() {
        // GravixRoomMusic republishes the mic (DTX swap, track change): the record
        // thread stops for a while and comes back; the processor is still installed
        val c = Chain()
        c.warm()
        c.router.begin(rate, 1)
        val track = FakeTrack { 10000 }
        repeat(10) { c.step(ShortArray(n), track) }
        // the last capture callback before the stop handed a token the post site never saw
        c.now += 10_000_000L
        c.router.pre(MusicMixKernel.wholeShortView(ByteBuffer.allocateDirect(n * 2)), n, 1, rate, 100, track, c.now)
        c.now += 400_000_000L // 400 ms without capture
        val out = ArrayList<FloatArray>()
        repeat(10) { out.add(c.step(ShortArray(n), track)) }
        assertEquals(MusicCaptureRouter.Route.POST, c.router.route)
        assertEquals(0, c.router.droppedTokens)
        assertEquals(1, c.router.captureGaps)
        assertEquals(0, c.router.switches)
        assertFalse(c.fx.bypass)
        assertEquals(10000f, out.last()[n - 1], 0.5f)
    }

    @Test
    fun aRestartWithoutTheProcessorFallsBackToPre() {
        val c = Chain()
        c.warm()
        c.router.begin(rate, 1)
        val track = FakeTrack { 10000 }
        repeat(10) { c.step(ShortArray(n), track) }
        c.now += 400_000_000L
        c.postRuns = false // the new capture came back without our processor
        val out = ArrayList<FloatArray>()
        repeat(10) { out.add(c.step(ShortArray(n), track)) }
        assertEquals(MusicCaptureRouter.Route.PRE, c.router.route)
        assertTrue(c.fx.bypass)
        assertEquals(10000f, out.last()[n - 1], 0.5f)
    }

    @Test
    fun rateOrChannelMismatchKeepsThePreRoute() {
        val c = Chain()
        c.warm() // post site saw 480-frame (48 kHz) frames
        c.router.begin(44100, 1)
        assertEquals(MusicCaptureRouter.Route.PRE, c.router.route)
        c.router.begin(rate, 2)
        assertEquals(MusicCaptureRouter.Route.PRE, c.router.route)
        c.router.begin(rate, 1)
        assertEquals(MusicCaptureRouter.Route.POST, c.router.route)
        c.router.end()
        assertFalse(c.fx.bypass)
    }

    @Test
    fun floatAndShortMixAgreeWithinOneLsb() {
        val a = MusicMixKernel().apply { rampSamples = 960; ducking = true; musicGain = 0.7f; micGain = 1f }
        val b = MusicMixKernel().apply { rampSamples = 960; ducking = true; musicGain = 0.7f; micGain = 1f }
        a.reset(0f); b.reset(0f)
        val voice = sine(180.0, 5000.0)
        val music = sine(900.0, 20000.0)
        var p = 0L
        repeat(50) {
            val v = ShortArray(n) { voice(p + it) }
            val m = ShortArray(n) { music(p + it) }
            val s = v.copyOf()
            a.mix(s, m, null, n, 100)
            val vv = v.copyOf()
            b.voicePass(vv, n, 100)
            val mo = ShortArray(n)
            b.postMusic(m, mo, n)
            for (i in 0 until n) assertEquals("buffer $it sample $i", s[i].toFloat(), (vv[i] + mo[i]).coerceIn(-32768, 32767).toFloat(), 1f)
            p += n
        }
        assertEquals(a.env, b.env, 0f)
        assertEquals(a.duck, b.duck, 0f)
    }
}

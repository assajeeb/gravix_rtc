package com.gravitycompile.gravix_cloud.music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MusicMixKernelTest {
    private fun kernel(ramp: Int = 10) = MusicMixKernel().apply { rampSamples = ramp }

    @Test
    fun fadeInRampsFromZeroWithoutAJump() {
        val k = kernel(ramp = 100).apply { reset(0f); envTarget = 1f }
        val voice = ShortArray(100)
        val music = ShortArray(100) { 10000 }
        val out = ShortArray(100)
        k.mix(voice, music, out, 100)
        // linear ramp: first sample ~1 %, last sample 100 %
        assertTrue(voice[0] in 0..200)
        assertTrue(voice[99] >= 9990)
        for (i in 1 until 100) assertTrue("monotonic at $i", voice[i] >= voice[i - 1])
        assertEquals(1f, k.env, 0.001f)
    }

    @Test
    fun fadeOutReachesZero() {
        val k = kernel(ramp = 50).apply { reset(1f); envTarget = 0f }
        val voice = ShortArray(100)
        val music = ShortArray(100) { 8000 }
        k.mix(voice, music, ShortArray(100), 100)
        assertEquals(0f, k.env, 0f) // clamped at the target, exactly
        assertEquals(0, voice[99].toInt())
    }

    @Test
    fun voiceAndMusicAddWithGainsAndClip() {
        val k = kernel().apply { reset(1f); envTarget = 1f; micGain = 0.5f; musicGain = 1f }
        val voice = ShortArray(4) { 20000 }
        val music = ShortArray(4) { 30000 }
        k.mix(voice, music, ShortArray(4), 4)
        // 10000 + 30000 clipped
        assertEquals(32767, voice[0].toInt())
        val k2 = kernel().apply { reset(1f); envTarget = 1f; micGain = 1f; musicGain = 0.5f }
        val v2 = ShortArray(4) { 1000 }
        k2.mix(v2, ShortArray(4) { 2000 }, ShortArray(4), 4)
        assertEquals(2000, v2[3].toInt())
    }

    @Test
    fun mutedVoiceKeepsTheMusic() {
        // module mute: the voice arrives zeroed, the music still goes out
        val k = kernel().apply { reset(1f); envTarget = 1f; ducking = true }
        val voice = ShortArray(8)
        k.mix(voice, ShortArray(8) { 5000 }, ShortArray(8), 8)
        assertEquals(5000, voice[7].toInt())
        assertEquals(1f, k.duck, 0f) // zeros never duck
    }

    @Test
    fun noMusicAppliesOnlyTheVoiceGain() {
        val k = kernel().apply { reset(0f); micGain = 0.25f }
        val voice = ShortArray(4) { 4000 }
        val out = ShortArray(4) { 7 }
        k.mix(voice, null, out, 4)
        assertEquals(1000, voice[0].toInt())
        assertEquals(0, out[0].toInt())
    }

    @Test
    fun duckingDipsWhileTheHostTalksAndRecovers() {
        val k = kernel().apply { reset(1f); envTarget = 1f; ducking = true; duckLevel = 0.3f }
        val n = 480
        val loud = { ShortArray(n) { if (it % 2 == 0) 5000 else -5000 } }
        val music = ShortArray(n) { 10000 }
        repeat(10) { k.mix(loud(), music, ShortArray(n), n) } // 100 ms of speech
        assertEquals(0.3f, k.duck, 0.001f)
        val v = loud()
        val out = ShortArray(n)
        k.mix(v, music, out, n)
        assertEquals(3000, out[0].toInt())
        repeat(60) { k.mix(ShortArray(n), music, ShortArray(n), n) } // 600 ms of silence
        assertEquals(1f, k.duck, 0.001f)
    }

    @Test
    fun duckingOffNeverDips() {
        val k = kernel().apply { reset(1f); envTarget = 1f; ducking = false }
        val n = 480
        repeat(10) { k.mix(ShortArray(n) { 9000 }, ShortArray(n) { 100 }, ShortArray(n), n) }
        assertEquals(1f, k.duck, 0f)
    }

    @Test
    fun musicGainChangeIsSmoothed() {
        val k = kernel().apply { reset(1f); envTarget = 1f; musicGain = 1f }
        val out = ShortArray(4)
        k.mix(ShortArray(4), ShortArray(4) { 10000 }, out, 4)
        assertEquals(10000, out[0].toInt())
        k.musicGain = 0f
        k.mix(ShortArray(4), ShortArray(4) { 10000 }, out, 4)
        assertEquals(5000, out[0].toInt()) // halfway, not a jump to 0
    }

    @Test
    fun ringBufferWrapsAndClears() {
        val r = PcmRingBuffer(8)
        r.write(ShortArray(6) { (it + 1).toShort() }, 0, 6)
        val dst = ShortArray(4)
        assertEquals(4, r.read(dst, 4))
        assertEquals(listOf<Short>(1, 2, 3, 4), dst.toList())
        r.write(ShortArray(5) { (10 + it).toShort() }, 0, 5) // wraps
        val all = ShortArray(10)
        assertEquals(7, r.read(all, 10))
        assertEquals(listOf<Short>(5, 6, 10, 11, 12, 13, 14), all.take(7))
        r.write(ShortArray(3) { 1 }, 0, 3)
        r.clear()
        assertEquals(0, r.available())
    }

    @Test
    fun closedRingUnblocksAWriter() {
        val r = PcmRingBuffer(4)
        val t = Thread { r.write(ShortArray(16), 0, 16) }
        t.start()
        Thread.sleep(50)
        r.close()
        t.join(1000)
        assertTrue(!t.isAlive)
    }

    @Test
    fun wholeViewIgnoresAMovedPosition() {
        // field 2026-10-05: the module mute leaves the position at the end;
        // a view from the position had 0 samples (BufferUnderflowException)
        val b = java.nio.ByteBuffer.allocateDirect(960)
        b.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer().put(0, 1234)
        b.position(960)
        val v = MusicMixKernel.wholeShortView(b)
        assertEquals(480, v.remaining())
        assertEquals(1234, v.get(0).toInt())
        assertEquals(960, b.position()) // the original is untouched
        b.position(100); b.limit(200)
        assertEquals(480, MusicMixKernel.wholeShortView(b).remaining())
    }

    @Test
    fun callModesAreRecognised() {
        assertTrue(MusicInterruptionWatcher.isCallMode(1)) // RINGTONE
        assertTrue(MusicInterruptionWatcher.isCallMode(2)) // IN_CALL
        assertTrue(!MusicInterruptionWatcher.isCallMode(3)) // IN_COMMUNICATION (the room)
        assertTrue(!MusicInterruptionWatcher.isCallMode(0)) // NORMAL
    }
}

package com.gravitycompile.gravix_cloud.music

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log
import org.webrtc.audio.JavaAudioDeviceModule
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Mixes locally-decoded music PCM into WebRTC's microphone capture buffer.
 *
 * Installed ONCE as the AudioBufferCallback on flutter_webrtc's
 * WebRtcAudioRecord (via reflection — see MusicMixerPlugin.install()).
 * When no music session is active it is a cheap pass-through.
 *
 * onBuffer runs on WebRTC's AudioRecordThread every ~10ms — everything in
 * that path must be allocation-free after warm-up and must never block.
 *
 * POSITION: playedSamples counts the music samples actually consumed by the
 * capture thread (i.e. what listeners have heard), so positionMs() reflects
 * real playback progress, not decode progress. On seek the decoder calls
 * back with the landed time and the counter is rebased.
 */
object MusicMixerEngine : JavaAudioDeviceModule.AudioBufferCallback {

    private const val TAG = "MusicMixerEngine"

    // Observed capture format — updated on every callback, read by the
    // decoder when a session starts so it can resample to match.
    @Volatile var captureSampleRate: Int = 48000; private set
    @Volatile var captureChannels: Int = 1; private set
    @Volatile var captureSeen: Boolean = false; private set

    /**
     * Microphone muted in the audio device module (GravixClientPlugin
     * setMicrophoneMute): the capture buffer is already zeroed, and the mix is
     * held (not consumed) so the music pauses exactly as it did when a mute
     * stopped the recorder.
     */
    @Volatile var captureMuted: Boolean = false

    @Volatile private var session: Session? = null
    @Volatile var onCompleted: (() -> Unit)? = null

    class Session(
        val ring: PcmRingBuffer,
        val decoder: MusicDecoder,
        @Volatile var gain: Float,
        val monitor: MonitorPlayer?,
        val rate: Int,
        val channels: Int,
    ) {
        @Volatile var paused = false
        @Volatile var completedFired = false
        // playback position = baseUs (last seek target) + samples consumed
        @Volatile var baseUs: Long = 0
        @Volatile var playedSamples: Long = 0
        // scratch buffers, sized on first callback, reused every frame
        var music: ShortArray = ShortArray(0)
    }

    // ---- control (called from plugin / main thread) ----

    @Synchronized
    fun start(path: String, gain: Float, monitorEnabled: Boolean): Boolean {
        stopInternal()
        val rate = if (captureSeen) captureSampleRate else 48000
        val ch = if (captureSeen) captureChannels else 1
        val ring = PcmRingBuffer(rate * ch * 2) // ~2s of audio
        val decoder = MusicDecoder(path, rate, ch, ring)
        val monitor = if (monitorEnabled) MonitorPlayer.create(rate, ch) else null
        val s = Session(ring, decoder, gain, monitor, rate, ch)
        decoder.onSeekApplied = { us ->
            s.baseUs = us
            s.playedSamples = 0
        }
        session = s
        decoder.start()
        return true
    }

    @Synchronized
    fun change(path: String, gain: Float, monitorEnabled: Boolean): Boolean =
        start(path, gain, monitorEnabled)

    fun pause() {
        session?.paused = true
        session?.monitor?.pause()
    }

    fun resume() {
        session?.paused = false
        session?.monitor?.resume()
    }

    fun setGain(g: Float) { session?.gain = g }
    fun isActive(): Boolean = session != null
    fun isPaused(): Boolean = session?.paused ?: false

    /** Current playback position in ms, or -1 when no session. */
    fun positionMs(): Long {
        val s = session ?: return -1
        val played = s.playedSamples * 1000L / (s.rate.toLong() * s.channels)
        val posMs = s.baseUs / 1000 + played
        val dur = durationMs()
        return if (dur > 0) posMs.coerceAtMost(dur) else posMs
    }

    /** Track duration in ms, or -1 when unknown / no session. */
    fun durationMs(): Long {
        val us = session?.decoder?.durationUs ?: return -1
        return if (us > 0) us / 1000 else -1
    }

    /** Seek the current track. No-op when no session. */
    fun seekTo(positionMs: Long) {
        session?.decoder?.requestSeek(positionMs * 1000)
    }

    @Synchronized
    fun stop() = stopInternal()

    private fun stopInternal() {
        val s = session ?: return
        session = null
        s.decoder.shutdown()
        s.monitor?.release()
    }

    // ---- capture-thread hot path ----

    override fun onBuffer(
        buffer: ByteBuffer,
        audioFormat: Int,
        channelCount: Int,
        sampleRate: Int,
        bytesRead: Int,
        captureTimeNs: Long,
    ): Long {
        captureSampleRate = sampleRate
        captureChannels = channelCount
        captureSeen = true

        if (captureMuted) return captureTimeNs
        val s = session ?: return captureTimeNs
        if (s.paused) return captureTimeNs
        if (audioFormat != AudioFormat.ENCODING_PCM_16BIT) return captureTimeNs

        // After this callback WebRTC delivers buffer.capacity() bytes,
        // regardless of bytesRead — so mix across the full capacity.
        val samples = buffer.capacity() / 2
        if (s.music.size != samples) s.music = ShortArray(samples)

        val got = s.ring.read(s.music, samples)
        s.playedSamples += got
        if (got < samples) {
            // underrun or end of track — pad the tail with silence
            java.util.Arrays.fill(s.music, got, samples, 0)
            if (got == 0 && s.decoder.finished && !s.completedFired) {
                s.completedFired = true
                onCompleted?.invoke() // plugin marshals to main thread
            }
        }

        val dup = buffer.duplicate().order(ByteOrder.nativeOrder())
        val sb = dup.asShortBuffer()
        val g = s.gain
        for (i in 0 until samples) {
            val mixed = sb.get(i) + (s.music[i] * g).toInt()
            sb.put(i, mixed.coerceIn(-32768, 32767).toShort())
        }

        s.monitor?.write(s.music, samples, g)
        return captureTimeNs
    }
}

/** Single-producer / single-consumer circular PCM buffer (16-bit samples). */
class PcmRingBuffer(capacitySamples: Int) {
    private val buf = ShortArray(capacitySamples)
    private val lock = Object()
    private var readPos = 0
    private var writePos = 0
    private var count = 0
    @Volatile var closed = false

    /** Blocking write from the decoder thread. */
    fun write(src: ShortArray, offset: Int, len: Int) {
        var off = offset
        var remaining = len
        while (remaining > 0 && !closed) {
            synchronized(lock) {
                while (count == buf.size && !closed) lock.wait(100)
                if (closed) return
                val n = minOf(remaining, buf.size - count, buf.size - writePos)
                System.arraycopy(src, off, buf, writePos, n)
                writePos = (writePos + n) % buf.size
                count += n
                off += n
                remaining -= n
                lock.notifyAll()
            }
        }
    }

    /** Non-blocking read from the capture thread. Returns samples read. */
    fun read(dst: ShortArray, len: Int): Int {
        synchronized(lock) {
            val n = minOf(len, count)
            var copied = 0
            while (copied < n) {
                val chunk = minOf(n - copied, buf.size - readPos)
                System.arraycopy(buf, readPos, dst, copied, chunk)
                readPos = (readPos + chunk) % buf.size
                copied += chunk
            }
            count -= n
            lock.notifyAll()
            return n
        }
    }

    /** Drops all buffered samples and wakes a blocked writer (used by seek). */
    fun clear() {
        synchronized(lock) {
            readPos = 0
            writePos = 0
            count = 0
            lock.notifyAll()
        }
    }

    fun close() {
        closed = true
        synchronized(lock) { lock.notifyAll() }
    }
}

/**
 * Local playback so the HOST also hears the music. Fed the exact same
 * samples that get mixed into the outgoing track, so it can't drift.
 * Uses USAGE_MEDIA — devices with hardware AEC will strip this playout
 * from the mic signal, avoiding a doubled/echoed copy for listeners.
 */
class MonitorPlayer private constructor(private val track: AudioTrack) {
    private var scaled = ShortArray(0)

    fun write(music: ShortArray, samples: Int, gain: Float) {
        if (scaled.size != samples) scaled = ShortArray(samples)
        for (i in 0 until samples) {
            scaled[i] = (music[i] * gain).toInt().coerceIn(-32768, 32767).toShort()
        }
        track.write(scaled, 0, samples, AudioTrack.WRITE_NON_BLOCKING)
    }

    /** Flush on pause so resume doesn't replay ~stale buffered audio. */
    fun pause() = runCatching { track.pause(); track.flush() }
    fun resume() = runCatching { track.play() }
    fun release() = runCatching { track.stop(); track.release() }

    companion object {
        fun create(sampleRate: Int, channels: Int): MonitorPlayer? = try {
            val channelMask =
                if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO
                else AudioFormat.CHANNEL_OUT_MONO
            val minBuf = AudioTrack.getMinBufferSize(
                sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelMask)
                        .build())
                .setBufferSizeInBytes(minBuf * 4)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            track.play()
            MonitorPlayer(track)
        } catch (e: Exception) {
            Log.w("MonitorPlayer", "monitor unavailable: $e")
            null
        }
    }
}
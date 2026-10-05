package com.gravitycompile.gravix_cloud.music

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.SystemClock
import android.util.Log
import org.webrtc.audio.JavaAudioDeviceModule
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Mixes locally decoded music into WebRTC's microphone capture buffer: the
 * music rides on the published microphone track (one stream, no second track,
 * no server bot).
 *
 * Installed as the AudioBufferCallback of flutter_webrtc's WebRtcAudioRecord
 * (reflection, see MusicMixerPlugin.installCallback). With no session it is a
 * pass-through (after a chained foreign callback, if one was installed first).
 *
 * onBuffer runs on WebRTC's AudioRecordThread every ~10 ms: no allocation after
 * warm-up, never blocks.
 *
 * MUTE: GravixClientPlugin's module mute sets [captureMuted]; WebRtcAudioRecord
 * zeroes the PCM before this callback. With [holdOnMute] false (gravix_rtc
 * 0.4.10 default, `continueWhileMicMuted`) the music is still mixed onto the
 * zeroed voice: a voice-only mute. With [holdOnMute] true the music is held
 * (not consumed) while muted.
 *
 * POSITION: playedSamples counts the music samples consumed by the capture
 * thread (what listeners heard), rebased on seek.
 */
object MusicMixerEngine : JavaAudioDeviceModule.AudioBufferCallback {

    private const val TAG = "GxMusicMixer"

    interface Listener {
        fun onCompleted()
        fun onError(code: String, message: String)
        fun onInterruption(active: Boolean, reason: String, resumed: Boolean)
    }

    /** Application context (content URIs, AudioManager). Set by the plugin. */
    @Volatile var appContext: Context? = null
    @Volatile var listener: Listener? = null

    // Observed capture format, updated on every callback.
    @Volatile var captureSampleRate: Int = 48000; private set
    @Volatile var captureChannels: Int = 1; private set
    @Volatile var captureSeen: Boolean = false; private set
    @Volatile private var lastCaptureMs: Long = 0

    /** A capture callback ran within the last 500 ms (the recorder is live). */
    fun captureLive(): Boolean =
        lastCaptureMs != 0L && SystemClock.elapsedRealtime() - lastCaptureMs < 500

    /** Module mute engaged (GravixClientPlugin.handleSetMicrophoneMute). */
    @Volatile var captureMuted: Boolean = false

    /** Hold the music while [captureMuted] (continueWhileMicMuted = false). */
    @Volatile var holdOnMute: Boolean = false

    /** Pause on a phone call / audio focus loss. */
    @Volatile var pauseOnInterruption: Boolean = true

    /** A callback that held the slot before us (e.g. an app's own mixer). */
    @Volatile var downstream: JavaAudioDeviceModule.AudioBufferCallback? = null

    val kernel = MusicMixKernel()

    @Volatile private var session: Session? = null
    private var interruptions: MusicInterruptionWatcher? = null

    class Session(
        val ring: PcmRingBuffer,
        val decoder: MusicDecoder,
        val monitor: MonitorPlayer?,
        val rate: Int,
        val channels: Int,
    ) {
        @Volatile var paused = false            // not consuming
        @Volatile var pauseRequested = false    // fading out, then paused
        @Volatile var stopRequested = false     // fading out, then released
        @Volatile var fadedOut = false
        @Volatile var interrupted: String? = null
        @Volatile var completedFired = false
        @Volatile var baseUs: Long = 0
        @Volatile var playedSamples: Long = 0
        var voice: ShortArray = ShortArray(0)
        var music: ShortArray = ShortArray(0)
        var musicOut: ShortArray = ShortArray(0)
    }

    class StartException(val code: String, message: String) : Exception(message)

    // ---- control (plugin's worker thread) ----

    /**
     * Starts [source] (replacing a running track). Throws [StartException]
     * (CAPTURE_NOT_READY, OPEN_FAILED) instead of reporting a silent success.
     * Returns the duration in ms (-1 unknown).
     */
    @Synchronized
    fun start(
        source: String,
        isContentUri: Boolean,
        loop: Boolean,
        monitorEnabled: Boolean,
    ): Long {
        stopInternal()
        // The music is resampled to the LIVE capture format; guessing 48 kHz
        // mono plays chipmunked/slowed on devices capturing at 16 kHz.
        if (!captureLive()) {
            throw StartException("CAPTURE_NOT_READY", "the microphone capture is not running")
        }
        val rate = captureSampleRate
        val ch = captureChannels
        val ring = PcmRingBuffer(rate * ch * 2) // ~2 s
        val decoder = MusicDecoder(appContext, source, isContentUri, rate, ch, ring)
        decoder.loop = loop
        decoder.prepare()?.let { reason ->
            decoder.shutdown()
            throw StartException("OPEN_FAILED", reason)
        }
        val monitor = if (monitorEnabled) MonitorPlayer.create(rate, ch, monitorUsesMedia()) else null
        val s = Session(ring, decoder, monitor, rate, ch)
        decoder.onSeekApplied = { us ->
            s.baseUs = us
            s.playedSamples = 0
        }
        decoder.onFailed = { msg -> listener?.onError("DECODE_FAILED", msg) }
        kernel.rampSamples = (rate * ch / 50).coerceAtLeast(1) // 20 ms
        kernel.reset(0f)
        kernel.envTarget = 1f
        session = s
        decoder.start()
        startInterruptionWatch()
        Log.i(TAG, "music started: ${rate}Hz/${ch}ch loop=$loop monitor=${monitor != null}")
        return durationMs()
    }

    fun pause() {
        val s = session ?: return
        s.interrupted = null // a user pause is never auto-resumed
        requestPause(s)
    }

    private fun requestPause(s: Session) {
        if (s.paused || s.pauseRequested) return
        s.pauseRequested = true
        kernel.envTarget = 0f
        if (!captureLive()) s.paused = true
    }

    fun resume() {
        val s = session ?: return
        s.interrupted = null
        resumeInternal(s)
    }

    private fun resumeInternal(s: Session) {
        s.pauseRequested = false
        s.paused = false
        kernel.envTarget = 1f
    }

    fun setLoop(on: Boolean) { session?.decoder?.loop = on }
    fun isActive(): Boolean = session != null
    fun isPaused(): Boolean = session?.let { it.paused || it.pauseRequested } ?: false
    fun interruptedReason(): String? = session?.interrupted

    /** Current playback position in ms, or -1 when no session. */
    fun positionMs(): Long {
        val s = session ?: return -1
        val played = s.playedSamples * 1000L / (s.rate.toLong() * s.channels)
        var posMs = s.baseUs / 1000 + played
        val dur = durationMs()
        if (dur > 0) posMs = if (s.decoder.loop) posMs % dur else posMs.coerceAtMost(dur)
        return posMs
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
        // fade out first (<= 60 ms) so listeners hear no click
        if (captureLive() && !s.paused) {
            s.stopRequested = true
            kernel.envTarget = 0f
            val deadline = SystemClock.elapsedRealtime() + 60
            while (!s.fadedOut && SystemClock.elapsedRealtime() < deadline) {
                try { Thread.sleep(5) } catch (_: InterruptedException) { break }
            }
        }
        session = null
        stopInterruptionWatch()
        s.decoder.shutdown()
        s.monitor?.release()
        Log.i(TAG, "music stopped")
    }

    // ---- interruptions (phone call / audio focus) ----

    private fun startInterruptionWatch() {
        val ctx = appContext ?: return
        if (interruptions == null) {
            interruptions = MusicInterruptionWatcher(ctx) { inCall ->
                if (inCall) interruptionBegan("call") else interruptionEnded("call")
            }.also { it.start() }
        }
    }

    private fun stopInterruptionWatch() {
        interruptions?.stop()
        interruptions = null
    }

    /** From GxAudioSwitchManager's focus listener. */
    fun onAudioFocusChange(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> interruptionBegan("focusLossTransient")
            AudioManager.AUDIOFOCUS_LOSS -> {
                // permanent: paused like a user pause (no auto-resume)
                val s = session ?: return
                if (!pauseOnInterruption || s.paused || s.pauseRequested) return
                s.interrupted = null
                requestPause(s)
                listener?.onInterruption(true, "focusLoss", false)
            }
            AudioManager.AUDIOFOCUS_GAIN -> interruptionEnded("focusLossTransient")
            else -> Unit
        }
    }

    fun interruptionBegan(reason: String) {
        val s = session ?: return
        if (!pauseOnInterruption || s.interrupted != null) return
        if (s.paused || s.pauseRequested) return // already paused by the user
        s.interrupted = reason
        requestPause(s)
        Log.i(TAG, "music interrupted: $reason")
        listener?.onInterruption(true, reason, false)
    }

    fun interruptionEnded(reason: String) {
        val s = session ?: return
        if (s.interrupted != reason) return
        s.interrupted = null
        resumeInternal(s)
        Log.i(TAG, "music resumed after $reason")
        listener?.onInterruption(false, reason, true)
    }

    private fun monitorUsesMedia(): Boolean {
        val am = appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return true
        // A VOICE_COMMUNICATION track in MODE_NORMAL comes out of the earpiece,
        // a media track in MODE_IN_COMMUNICATION may take another route: follow
        // the room's mode.
        return am.mode != AudioManager.MODE_IN_COMMUNICATION
    }

    // ---- capture-thread hot path ----

    @Volatile private var mixFailureLogged = false

    override fun onBuffer(
        buffer: ByteBuffer,
        audioFormat: Int,
        channelCount: Int,
        sampleRate: Int,
        bytesRead: Int,
        captureTimeNs: Long,
    ): Long {
        // An exception here would kill WebRTC's record thread, and the app with
        // it: whatever goes wrong, the capture goes on unmixed.
        return try {
            mixInto(buffer, audioFormat, channelCount, sampleRate, bytesRead, captureTimeNs)
        } catch (e: Throwable) {
            if (!mixFailureLogged) {
                mixFailureLogged = true
                Log.e(TAG, "mix failed, passing the capture through", e)
            }
            captureTimeNs
        }
    }

    private fun mixInto(
        buffer: ByteBuffer,
        audioFormat: Int,
        channelCount: Int,
        sampleRate: Int,
        bytesRead: Int,
        captureTimeNs: Long,
    ): Long {
        var ts = captureTimeNs
        downstream?.let { d ->
            ts = try { d.onBuffer(buffer, audioFormat, channelCount, sampleRate, bytesRead, captureTimeNs) }
            catch (e: Throwable) { captureTimeNs }
        }
        captureSampleRate = sampleRate
        captureChannels = channelCount
        captureSeen = true
        lastCaptureMs = SystemClock.elapsedRealtime()

        val s = session ?: return ts
        if (audioFormat != AudioFormat.ENCODING_PCM_16BIT) return ts
        if (captureMuted && holdOnMute) return ts

        // WebRTC delivers buffer.capacity() bytes after this callback,
        // regardless of bytesRead, so operate across the full capacity.
        val samples = buffer.capacity() / 2
        if (s.voice.size != samples) {
            s.voice = ShortArray(samples)
            s.music = ShortArray(samples)
            s.musicOut = ShortArray(samples)
        }
        // A view over the WHOLE buffer: the record thread may hand it over with
        // its position moved (the module mute rewrites it with a relative put:
        // field 2026-10-05, BufferUnderflowException on the first muted frame).
        val sb = MusicMixKernel.wholeShortView(buffer)
        sb.get(s.voice, 0, samples)

        val consuming = !s.paused
        var got = 0
        if (consuming) {
            got = s.ring.read(s.music, samples)
            s.playedSamples += got
            if (got < samples) {
                // underrun or end of track: pad the tail with silence
                java.util.Arrays.fill(s.music, got, samples, 0)
                if (got == 0 && s.decoder.finished && s.decoder.failed == null && !s.completedFired) {
                    s.completedFired = true
                    listener?.onCompleted()
                }
            }
        }
        val frames = samples / channelCount.coerceAtLeast(1)
        val bps = if (frames > 0) (sampleRate / frames).coerceAtLeast(1) else 100
        kernel.mix(s.voice, if (consuming) s.music else null, s.musicOut, samples, bps)
        sb.position(0)
        sb.put(s.voice, 0, samples)

        if (consuming) {
            s.monitor?.write(s.musicOut, samples)
            if (kernel.env == 0f) {
                if (s.pauseRequested) { s.paused = true; s.pauseRequested = false }
                if (s.stopRequested) s.fadedOut = true
            }
        }
        return ts
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

    val capacity: Int get() = buf.size
    fun available(): Int = synchronized(lock) { count }

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
 * Local playback so the HOST hears the music, fed the exact samples mixed into
 * the outgoing track (no drift). Its usage follows the room's audio mode (see
 * MusicMixerEngine.monitorUsesMedia): a monitor on the wrong stream lands on a
 * different output at a different volume.
 */
class MonitorPlayer private constructor(private val track: AudioTrack) {
    fun write(music: ShortArray, samples: Int) {
        track.write(music, 0, samples, AudioTrack.WRITE_NON_BLOCKING)
    }

    fun release() = runCatching { track.pause(); track.flush(); track.stop(); track.release() }

    companion object {
        fun create(sampleRate: Int, channels: Int, mediaUsage: Boolean): MonitorPlayer? = try {
            val channelMask =
                if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO
                else AudioFormat.CHANNEL_OUT_MONO
            val minBuf = AudioTrack.getMinBufferSize(
                sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
            val attrs = if (mediaUsage) {
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            } else {
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            }
            val track = AudioTrack.Builder()
                .setAudioAttributes(attrs)
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
            Log.w("GxMusicMonitor", "monitor unavailable: $e")
            null
        }
    }
}

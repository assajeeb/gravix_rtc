package com.gravitycompile.gravix_cloud.music

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.util.Log
import java.util.concurrent.atomic.AtomicLong

/**
 * Decodes a local audio file or an Android `content://` URI (mp3/aac/m4a/ogg/
 * flac/wav: anything the device's MediaCodec handles) to 16-bit PCM,
 * resampled/remixed to the WebRTC capture format, and feeds a [PcmRingBuffer].
 *
 * [prepare] opens the source, selects the audio track and creates + starts the
 * codec SYNCHRONOUSLY, so a missing file, an unreadable URI, a file with no
 * audio track or a codec the device cannot decode is reported to the caller
 * (start() fails with OPEN_FAILED) instead of being discovered silently on the
 * decode thread (the pre-0.4.10 SDK engine returned success for all of those).
 *
 * The ring buffer's blocking write paces this thread: decode runs ~2 s ahead of
 * playback and then sleeps, so pause simply stops consumption.
 *
 * SEEK: [requestSeek] is safe from any thread. It clears the ring (which also
 * unblocks a decoder stuck in ring.write), and the decode loop applies the seek
 * at the next iteration: codec flush + extractor.seekTo + resampler reset + a
 * second ring.clear to drop any stale chunk written in between. [onSeekApplied]
 * fires with the actual landed presentation time so the engine can rebase its
 * position counter.
 *
 * LOOP: with [loop] on, end of stream rewinds to 0 WITHOUT clearing the ring, so
 * the tail of the track and its head join seamlessly.
 */
class MusicDecoder(
    private val context: Context?,
    private val source: String,
    private val isContentUri: Boolean,
    private val dstRate: Int,
    private val dstChannels: Int,
    private val ring: PcmRingBuffer,
) : Thread("GxMusicDecoder") {

    @Volatile var finished = false; private set
    @Volatile var failed: String? = null; private set
    @Volatile var durationUs: Long = -1; private set
    @Volatile var loop = false
    @Volatile private var stopped = false

    /** Invoked on the decoder thread right after a seek lands (actual µs). */
    @Volatile var onSeekApplied: ((Long) -> Unit)? = null
    /** Invoked on the decoder thread when decoding fails mid-track. */
    @Volatile var onFailed: ((String) -> Unit)? = null
    /** Invoked on the decoder thread each time a loop rewinds to 0. */
    @Volatile var onLooped: (() -> Unit)? = null

    private val pendingSeekUs = AtomicLong(-1)

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var isRawPcm = false
    private var prepared = false

    // linear-resampler state
    private var srcRate = dstRate
    private var srcChannels = dstChannels
    private var pos = 0.0
    private var hasPrev = false
    private val lastFrame = ShortArray(8)
    private var out = ShortArray(0)

    /**
     * Opens the source and the codec. Returns null on success, else a reason.
     * Must be called (once) before [start].
     */
    fun prepare(): String? {
        var ex: MediaExtractor? = null
        try {
            ex = MediaExtractor()
            if (isContentUri) {
                val ctx = context ?: return "no Android context for a content URI"
                ex.setDataSource(ctx, Uri.parse(source), null)
            } else {
                ex.setDataSource(source)
            }
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val m = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (m.startsWith("audio/")) { trackIndex = i; format = f; break }
            }
            if (trackIndex < 0 || format == null) {
                runCatching { ex.release() }
                return "no audio track in the source"
            }
            ex.selectTrack(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceIn(1, 8)
            if (format.containsKey(MediaFormat.KEY_DURATION)) {
                durationUs = format.getLong(MediaFormat.KEY_DURATION)
            }
            isRawPcm = mime == MediaFormat.MIMETYPE_AUDIO_RAW
            if (!isRawPcm) {
                // createDecoderByType/configure/start are where an unsupported
                // codec actually fails, so they belong here.
                val c = MediaCodec.createDecoderByType(mime)
                try {
                    c.configure(format, null, null, 0)
                    c.start()
                } catch (e: Exception) {
                    runCatching { c.release() }
                    throw e
                }
                codec = c
            }
            extractor = ex
            prepared = true
            return null
        } catch (e: Exception) {
            runCatching { ex?.release() }
            Log.w(TAG, "prepare failed: $e")
            return e.message ?: e.javaClass.simpleName
        }
    }

    fun shutdown() {
        stopped = true
        ring.close()
        interrupt()
        // A thread that was never started never runs its finally block.
        if (state == State.NEW) releaseCodec()
    }

    /** Thread-safe. Position in microseconds; clamped to >= 0. */
    fun requestSeek(positionUs: Long) {
        pendingSeekUs.set(positionUs.coerceAtLeast(0))
        // Frees space + wakes a blocked write() so the loop reaches the seek
        // check promptly instead of waiting for playback to drain.
        ring.clear()
    }

    override fun run() {
        try {
            check(prepared) { "prepare() first" }
            val ex = extractor!!
            val c = codec
            if (isRawPcm || c == null) pumpRaw(ex) else pumpCodec(ex, c)
        } catch (e: Exception) {
            if (!stopped) {
                Log.e(TAG, "decode failed: $e")
                failed = e.message ?: e.javaClass.simpleName
                onFailed?.invoke(failed!!)
            }
        } finally {
            finished = true
            releaseCodec()
        }
    }

    @Synchronized
    private fun releaseCodec() {
        val c = codec
        codec = null
        if (c != null) runCatching { c.stop() }.also { runCatching { c.release() } }
        val ex = extractor
        extractor = null
        if (ex != null) runCatching { ex.release() }
    }

    /** Applies a pending seek, if any. Returns true when a seek happened. */
    private fun maybeSeek(extractor: MediaExtractor, codec: MediaCodec?): Boolean {
        val us = pendingSeekUs.getAndSet(-1)
        if (us < 0) return false
        runCatching { codec?.flush() }
        extractor.seekTo(us, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        // Drop anything decoded before the seek that slipped into the ring
        // between requestSeek()'s clear and now.
        ring.clear()
        pos = 0.0
        hasPrev = false
        val actual = extractor.sampleTime.let { if (it >= 0) it else us }
        onSeekApplied?.invoke(actual)
        return true
    }

    /** Rewinds for [loop] without touching the ring (seamless). */
    private fun rewind(extractor: MediaExtractor, codec: MediaCodec?) {
        runCatching { codec?.flush() }
        extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        onLooped?.invoke()
    }

    private fun pumpCodec(extractor: MediaExtractor, codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var pcm = ShortArray(0)
        while (!stopped) {
            if (maybeSeek(extractor, codec)) inputDone = false

            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val inBuf = codec.getInputBuffer(inIdx)!!
                    val size = extractor.readSampleData(inBuf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            when (val outIdx = codec.dequeueOutputBuffer(info, 10_000)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // decoders may output a different rate/layout than the
                    // container declares (e.g. HE-AAC): trust this format
                    val f = codec.outputFormat
                    srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    srcChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceIn(1, 8)
                    if (f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) != AudioFormat.ENCODING_PCM_16BIT) {
                        Log.w(TAG, "non-16bit PCM output; audio may be wrong")
                    }
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> { /* loop */ }
                else -> if (outIdx >= 0) {
                    val outBuf = codec.getOutputBuffer(outIdx)!!
                    if (info.size > 0) {
                        outBuf.position(info.offset)
                        outBuf.limit(info.offset + info.size)
                        val n = info.size / 2
                        if (pcm.size < n) pcm = ShortArray(n)
                        outBuf.order(java.nio.ByteOrder.nativeOrder())
                            .asShortBuffer().get(pcm, 0, n)
                        feed(pcm, n)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        // A seek can race EOS: if one is pending, honor it
                        // instead of ending the track.
                        if (pendingSeekUs.get() >= 0 && maybeSeek(extractor, codec)) {
                            inputDone = false
                            continue
                        }
                        if (loop && !stopped) {
                            rewind(extractor, codec)
                            inputDone = false
                            continue
                        }
                        return
                    }
                }
            }
        }
    }

    private fun pumpRaw(extractor: MediaExtractor) {
        val buf = java.nio.ByteBuffer.allocate(64 * 1024)
        var pcm = ShortArray(0)
        while (!stopped) {
            maybeSeek(extractor, null)
            buf.clear()
            val size = extractor.readSampleData(buf, 0)
            if (size < 0) {
                if (pendingSeekUs.get() >= 0) continue // seek raced EOS
                if (loop && !stopped) { rewind(extractor, null); continue }
                return
            }
            val n = size / 2
            if (pcm.size < n) pcm = ShortArray(n)
            buf.limit(size)
            buf.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer().get(pcm, 0, n)
            feed(pcm, n)
            extractor.advance()
        }
    }

    /** Downmix/upmix to dstChannels, linear-resample to dstRate, push to ring. */
    private fun feed(pcm: ShortArray, len: Int) {
        val srcFrames = len / srcChannels
        if (srcFrames == 0) return

        if (srcChannels == dstChannels && srcRate == dstRate) {
            ring.write(pcm, 0, srcFrames * srcChannels)
            return
        }
        // channel conversion: average to mono, copy to every destination channel
        val mono = ShortArray(srcFrames * dstChannels)
        for (f in 0 until srcFrames) {
            var acc = 0
            for (c in 0 until srcChannels) acc += pcm[f * srcChannels + c]
            val sample = (acc / srcChannels).toShort()
            for (c in 0 until dstChannels) mono[f * dstChannels + c] = sample
        }

        if (srcRate == dstRate) { ring.write(mono, 0, mono.size); return }

        // linear resample over [prevFrame, mono...] so chunks join seamlessly
        val prevFrames = if (hasPrev) 1 else 0
        val totalFrames = srcFrames + prevFrames
        fun sampleAt(idx: Int, c: Int): Double =
            if (idx < prevFrames) lastFrame[c].toDouble()
            else mono[(idx - prevFrames) * dstChannels + c].toDouble()

        val step = srcRate.toDouble() / dstRate
        val maxOut = ((totalFrames / step) + 2).toInt() * dstChannels
        if (out.size < maxOut) out = ShortArray(maxOut)
        var outFrames = 0
        while (pos < totalFrames - 1) {
            val i = pos.toInt()
            val frac = pos - i
            for (c in 0 until dstChannels) {
                val a = sampleAt(i, c)
                val b = sampleAt(i + 1, c)
                out[outFrames * dstChannels + c] = (a + (b - a) * frac).toInt()
                    .coerceIn(-32768, 32767).toShort()
            }
            outFrames++
            pos += step
        }
        // re-base pos against the new carried frame (= last frame of chunk)
        pos -= (totalFrames - 1)
        if (pos < 0) pos = 0.0
        for (c in 0 until dstChannels) {
            lastFrame[c] = mono[(srcFrames - 1) * dstChannels + c]
        }
        hasPrev = true
        ring.write(out, 0, outFrames * dstChannels)
    }

    private companion object {
        const val TAG = "GxMusicDecoder"
    }
}

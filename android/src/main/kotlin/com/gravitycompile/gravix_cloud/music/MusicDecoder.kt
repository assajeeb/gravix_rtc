package com.gravitycompile.gravix_cloud.music

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.util.concurrent.atomic.AtomicLong

/**
 * Decodes an arbitrary local audio file (mp3/aac/m4a/ogg/flac/wav — anything
 * the device's MediaCodec handles) to 16-bit PCM, resampled/remixed to the
 * WebRTC capture format, and feeds it into a PcmRingBuffer.
 *
 * The ring buffer's blocking write is what paces this thread: decode runs
 * ~2s ahead of playback and then sleeps, so pause simply stops consumption.
 *
 * SEEK: requestSeek() is safe from any thread. It clears the ring (which
 * also unblocks a decoder stuck in ring.write), and the decode loop applies
 * the seek at the next iteration: codec flush + extractor.seekTo + resampler
 * reset + a second ring.clear to drop any stale chunk written in between.
 * onSeekApplied fires with the actual landed presentation time so the engine
 * can rebase its position counter.
 */
class MusicDecoder(
    private val path: String,
    private val dstRate: Int,
    private val dstChannels: Int,
    private val ring: PcmRingBuffer,
) : Thread("MusicDecoder") {

    @Volatile var finished = false; private set
    @Volatile var durationUs: Long = -1; private set
    @Volatile private var stopped = false

    /** Invoked on the decoder thread right after a seek lands (actual µs). */
    @Volatile var onSeekApplied: ((Long) -> Unit)? = null

    private val pendingSeekUs = AtomicLong(-1)

    // linear-resampler state
    private var srcRate = dstRate
    private var srcChannels = dstChannels
    private var pos = 0.0
    private var hasPrev = false
    private var lastFrame = ShortArray(8)
    private var out = ShortArray(0)

    fun shutdown() {
        stopped = true
        ring.close()
        interrupt()
    }

    /** Thread-safe. Position in microseconds; clamped to >= 0. */
    fun requestSeek(positionUs: Long) {
        pendingSeekUs.set(positionUs.coerceAtLeast(0))
        // Frees space + wakes a blocked write() so the loop reaches the
        // seek check promptly instead of waiting for playback to drain.
        ring.clear()
    }

    override fun run() {
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        try {
            extractor = MediaExtractor().apply { setDataSource(path) }
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) { trackIndex = i; format = f; break }
            }
            if (trackIndex < 0 || format == null) throw IllegalArgumentException("no audio track in $path")
            extractor.selectTrack(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            if (format.containsKey(MediaFormat.KEY_DURATION)) {
                durationUs = format.getLong(MediaFormat.KEY_DURATION)
            }

            if (mime == MediaFormat.MIMETYPE_AUDIO_RAW) {
                pumpRaw(extractor)
            } else {
                codec = MediaCodec.createDecoderByType(mime)
                codec.configure(format, null, null, 0)
                codec.start()
                pumpCodec(extractor, codec)
            }
        } catch (e: Exception) {
            if (!stopped) Log.e("MusicDecoder", "decode failed: $e")
        } finally {
            finished = true
            runCatching { codec?.stop(); codec?.release() }
            runCatching { extractor?.release() }
        }
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

    private fun pumpCodec(extractor: MediaExtractor, codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
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
                    // container declares (e.g. HE-AAC) — trust this format
                    val f = codec.outputFormat
                    srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    srcChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    if (f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) != AudioFormat.ENCODING_PCM_16BIT) {
                        Log.w("MusicDecoder", "non-16bit PCM output; audio may be wrong")
                    }
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> { /* loop */ }
                else -> if (outIdx >= 0) {
                    val outBuf = codec.getOutputBuffer(outIdx)!!
                    if (info.size > 0) {
                        outBuf.position(info.offset)
                        outBuf.limit(info.offset + info.size)
                        val pcm = ShortArray(info.size / 2)
                        outBuf.order(java.nio.ByteOrder.nativeOrder())
                            .asShortBuffer().get(pcm)
                        feed(pcm)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        // A seek can race EOS: if one is pending, honor it
                        // instead of ending the track.
                        if (pendingSeekUs.get() >= 0) {
                            if (maybeSeek(extractor, codec)) { inputDone = false; continue }
                        }
                        return
                    }
                }
            }
        }
    }

    private fun pumpRaw(extractor: MediaExtractor) {
        val buf = java.nio.ByteBuffer.allocate(64 * 1024)
        while (!stopped) {
            maybeSeek(extractor, null)
            buf.clear()
            val size = extractor.readSampleData(buf, 0)
            if (size < 0) {
                if (pendingSeekUs.get() >= 0) continue // seek raced EOS
                return
            }
            val pcm = ShortArray(size / 2)
            buf.limit(size)
            buf.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer().get(pcm)
            feed(pcm)
            extractor.advance()
        }
    }

    /** Downmix/upmix to dstChannels, linear-resample to dstRate, push to ring. */
    private fun feed(pcm: ShortArray) {
        val srcFrames = pcm.size / srcChannels
        if (srcFrames == 0) return

        // channel conversion into mono-or-matching interleaved frames
        val mono: ShortArray
        if (srcChannels == dstChannels && srcRate == dstRate) {
            ring.write(pcm, 0, pcm.size)
            return
        }
        mono = ShortArray(srcFrames * dstChannels)
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
}
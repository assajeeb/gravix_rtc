package com.gravitycompile.gravix_cloud.rtc

import android.content.Context
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Diagnostic (2026-10-22, the gift-echo measurements): records the capture the SFU
 * receives, as two mono 16-bit WAVs per capture: `pre` = what reaches
 * GxNoiseProcessor (after WebRTC's APM: AEC, high-pass; WebRTC NS is off while
 * ours runs) and `post` = after Gravix NS / AGC (what is encoded).
 *
 * Off unless `adb shell setprop debug.gravix.capdump 1` before the capture
 * starts. Files: <external files>/gxdump/cap-<time>-{pre,post}.wav. The audio
 * thread only copies into a pooled array; a writer thread does the I/O.
 */
internal object GxCaptureDump {
  private const val TAG = "GravixNS"
  private const val MAX_FRAMES = 480
  private const val MAX_SECONDS = 300

  private class Block(val pre: FloatArray = FloatArray(MAX_FRAMES), val post: FloatArray = FloatArray(MAX_FRAMES)) {
    var n = 0
    var hasPost = false
  }

  private val pool = ArrayBlockingQueue<Block>(400)
  private val queue = ArrayBlockingQueue<Block>(400)
  @Volatile private var active = false
  @Volatile private var pending: Block? = null
  @Volatile private var dropped = 0
  private var writer: Thread? = null

  /** True when the property is set (checked at each capture start). */
  fun enabled(): Boolean = try {
    val c = Class.forName("android.os.SystemProperties")
    (c.getMethod("get", String::class.java).invoke(null, "debug.gravix.capdump") as String) == "1"
  } catch (t: Throwable) {
    false
  }

  @Synchronized
  fun start(ctx: Context?, rate: Int) {
    if (active || ctx == null || rate <= 0 || !enabled()) return
    val dir = File(ctx.getExternalFilesDir(null), "gxdump").apply { mkdirs() }
    val stamp = java.text.SimpleDateFormat("HHmmss", java.util.Locale.US).format(java.util.Date())
    val pre = File(dir, "cap-$stamp-pre.wav")
    val post = File(dir, "cap-$stamp-post.wav")
    if (pool.isEmpty()) repeat(400) { pool.offer(Block()) }
    queue.clear()
    dropped = 0
    active = true
    writer = Thread({ writeLoop(pre, post, rate) }, "GravixCapDump").apply { start() }
    Log.i(TAG, "[GravixNS] capdump start rate=$rate pre=${pre.absolutePath}")
  }

  /** Audio thread, before NS. */
  fun onPre(buffer: ByteBuffer, numFrames: Int) {
    if (!active || numFrames > MAX_FRAMES) return
    val b = pool.poll() ?: run { dropped++; return }
    val f = buffer.duplicate().order(ByteOrder.nativeOrder())
    for (i in 0 until numFrames) b.pre[i] = f.getFloat(i * 4)
    b.n = numFrames
    b.hasPost = false
    pending = b
  }

  /** Audio thread, after NS (or right after [onPre] when NS did not run). */
  fun onPost(buffer: ByteBuffer, numFrames: Int, processed: Boolean) {
    val b = pending ?: return
    pending = null
    if (processed) {
      val f = buffer.duplicate().order(ByteOrder.nativeOrder())
      for (i in 0 until numFrames) b.post[i] = f.getFloat(i * 4)
    } else {
      System.arraycopy(b.pre, 0, b.post, 0, numFrames)
    }
    b.hasPost = true
    if (!queue.offer(b)) { dropped++; pool.offer(b) }
  }

  private fun writeLoop(pre: File, post: File, rate: Int) {
    val maxSamples = rate.toLong() * MAX_SECONDS
    var samples = 0L
    try {
      RandomAccessFile(pre, "rw").use { a ->
        RandomAccessFile(post, "rw").use { b ->
          a.setLength(0); b.setLength(0)
          a.write(header(rate, 0)); b.write(header(rate, 0))
          val bytes = ByteArray(MAX_FRAMES * 2)
          while (active && samples < maxSamples) {
            val blk = queue.poll(200, TimeUnit.MILLISECONDS) ?: continue
            a.write(bytes, 0, pcm(blk.pre, blk.n, bytes))
            b.write(bytes, 0, pcm(blk.post, blk.n, bytes))
            samples += blk.n
            pool.offer(blk)
            if (samples % rate < blk.n) {
              // keep the header valid while recording (the app may be killed)
              patch(a, rate, samples); patch(b, rate, samples)
            }
          }
          patch(a, rate, samples); patch(b, rate, samples)
        }
      }
      Log.i(TAG, "[GravixNS] capdump end seconds=${samples / rate} dropped=$dropped")
    } catch (t: Throwable) {
      Log.w(TAG, "[GravixNS] capdump failed: $t")
    } finally {
      active = false
    }
  }

  private fun pcm(src: FloatArray, n: Int, out: ByteArray): Int {
    for (i in 0 until n) {
      val v = src[i].toInt().coerceIn(-32768, 32767)
      out[2 * i] = (v and 0xff).toByte()
      out[2 * i + 1] = ((v shr 8) and 0xff).toByte()
    }
    return n * 2
  }

  private fun patch(f: RandomAccessFile, rate: Int, samples: Long) {
    val pos = f.filePointer
    f.seek(0)
    f.write(header(rate, samples))
    f.seek(pos)
  }

  private fun header(rate: Int, samples: Long): ByteArray {
    val data = (samples * 2).toInt()
    return ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
      put("RIFF".toByteArray()); putInt(36 + data); put("WAVE".toByteArray())
      put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(1); putInt(rate); putInt(rate * 2)
      putShort(2); putShort(16)
      put("data".toByteArray()); putInt(data)
    }.array()
  }
}

// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Voice effects on the capture stream (native/gxfx). Runs right after noise
 * suppression, inside [GxNoiseProcessor.process], so the order cannot change.
 *
 * Until the first effect is asked for, process() is one volatile read and the
 * library is not loaded. The native instance lives for the process.
 * Threads: process() = WebRTC capture thread; the rest = main / [worker].
 */
internal object GxVoiceFx {
  private const val TAG = "GravixRTC"
  private const val WATCHDOG_US = 6000
  private const val WATCHDOG_CONSECUTIVE = 5
  val PRESETS = listOf(
    "none", "studio", "hall", "robot", "girl", "transformer", "boy", "child", "woman", "man", "foreigner", "ethereal", "magnetic", "fresh", "energetic", "rich", "muffled", "round", "falsetto", "full", "clear", "resonant", "loudClear", "softRoom", "largeRoom", "valley", "basement", "ktv", "enhancedKtv", "popular", "rock", "vocalConcert", "gramophone", "autotuneMajorC", "autotuneMinorA", "autotuneHarmonicMinor",
  )

  @Volatile var eventSink: ((Map<String, Any?>) -> Unit)? = null
  @Volatile private var used = false
  @Volatile private var handle = 0L
  @Volatile private var musicActive = false
  private var loadError: String? = null
  private val worker by lazy { Executors.newSingleThreadExecutor { r -> Thread(r, "gravix-fx") } }

  private val loaded: Boolean by lazy {
    try {
      System.loadLibrary("gxfx")
      true
    } catch (t: Throwable) {
      loadError = "library_missing"
      Log.w(TAG, "[GravixFX] library missing: ${t.javaClass.simpleName}")
      false
    }
  }

  fun wanted(): Boolean = used

  /** Capture thread, after noise suppression. Mono full-band floats only. */
  fun process(buffer: ByteBuffer, numFrames: Int, channels: Int) {
    if (!used) return
    val h = handle
    if (h == 0L) return
    if (GxNsFrameShape.reject(numFrames, buffer.capacity(), buffer.isDirect, channels) != null) return
    when (nativeProcess(h, buffer, numFrames, numFrames * 100)) {
      RESULT_NEED_REBUILD -> worker.execute { nativeRebuild(handle) }
      RESULT_WATCHDOG -> worker.execute {
        Log.w(TAG, "[GravixFX] watchdog budget_us=$WATCHDOG_US consecutive=$WATCHDOG_CONSECUTIVE: effect off")
        eventSink?.invoke(state(handle) + ("type" to "watchdog"))
      }
    }
  }

  /** fxConfigure from Dart: {effect}. Main thread. */
  @Synchronized
  fun configure(plugin: FlutterWebRTCPlugin?, args: Map<String, Any?>): Map<String, Any?> {
    val name = args["effect"] as? String ?: "none"
    val preset = PRESETS.indexOf(name)
    if (preset < 0) return mapOf("ok" to false, "reason" to "unknown_effect")
    if (preset == 0 && handle == 0L) return mapOf("ok" to true, "effect" to "none", "active" to "none", "reason" to "ok")
    if (!loaded) return mapOf("ok" to false, "reason" to (loadError ?: "library_missing"))
    if (handle == 0L) {
      handle = nativeCreate()
      nativeSetWatchdog(handle, WATCHDOG_US, WATCHDOG_CONSECUTIVE)
      nativeSetBypass(handle, musicActive)
    }
    val rc = nativeSetPreset(handle, preset)
    used = true
    val installed = GxNoiseProcessor.installOn(plugin, "fxConfigure")
    Log.i(TAG, "[GravixFX] step=configure effect=$name rc=$rc installed=$installed music=$musicActive")
    return state(handle) + mapOf("ok" to (rc == 0), "installed" to installed, "reason" to if (rc == 0) "ok" else "failed")
  }

  /** Any thread. */
  fun onMusic(active: Boolean) {
    if (musicActive == active) return
    musicActive = active
    val h = handle
    if (h == 0L) return
    nativeSetBypass(h, active)
    Log.i(TAG, "[GravixFX] step=music bypass=$active")
    eventSink?.invoke(state(h) + ("type" to "music"))
  }

  fun stats(): Map<String, Any?> {
    if (handle == 0L) return mapOf("ok" to true, "effect" to "none", "active" to "none", "reason" to "ok")
    return state(handle) + mapOf("ok" to true, "reason" to "ok")
  }

  /** On a private chain, off the audio path. */
  fun benchmark(args: Map<String, Any?>, done: (Map<String, Any?>) -> Unit) {
    val preset = PRESETS.indexOf(args["effect"] as? String ?: "girl")
    val rate = (args["rate"] as? Number)?.toInt() ?: 48000
    val seconds = (args["seconds"] as? Number)?.toInt() ?: 5
    if (preset < 0 || !loaded) return done(mapOf("ok" to false, "reason" to (loadError ?: "unknown_effect")))
    worker.execute {
      val v = IntArray(5)
      val rc = nativeBenchmark(preset, rate, seconds, v)
      Log.i(TAG, "[GravixFX] step=benchmark effect=${PRESETS[preset]} rate=$rate p50=${v[1]} p95=${v[2]} max=${v[3]} rc=$rc")
      done(mapOf("ok" to (rc == 0), "effect" to PRESETS[preset], "rate" to rate, "blocks" to v[0],
        "p50Us" to v[1], "p95Us" to v[2], "maxUs" to v[3], "latencyMs" to v[4]))
    }
  }

  private fun state(h: Long): Map<String, Any?> {
    val v = IntArray(9)
    nativeStatus(h, v)
    return mapOf("effect" to PRESETS[v[0]], "active" to PRESETS[v[1]], "rate" to v[2], "musicBypass" to (v[3] != 0),
      "watchdog" to (v[4] != 0), "latencyMs" to v[5], "frames" to v[6], "over" to v[7], "maxUs" to v[8])
  }

  private const val RESULT_NEED_REBUILD = 2
  private const val RESULT_WATCHDOG = 3

  @JvmStatic private external fun nativeCreate(): Long
  @JvmStatic private external fun nativeSetPreset(h: Long, preset: Int): Int
  @JvmStatic private external fun nativeRebuild(h: Long)
  @JvmStatic private external fun nativeSetBypass(h: Long, on: Boolean)
  @JvmStatic private external fun nativeSetWatchdog(h: Long, budgetUs: Int, consecutive: Int)
  @JvmStatic private external fun nativeProcess(h: Long, buffer: ByteBuffer, frames: Int, rate: Int): Int
  @JvmStatic private external fun nativeStatus(h: Long, out: IntArray)
  @JvmStatic private external fun nativeBenchmark(preset: Int, rate: Int, seconds: Int, out: IntArray): Int
}

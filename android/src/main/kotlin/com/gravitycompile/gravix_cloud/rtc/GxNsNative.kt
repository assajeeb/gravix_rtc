package com.gravitycompile.gravix_cloud.rtc

import java.nio.ByteBuffer

/**
 * libgxns.so (android/src/main/cpp/gx_ns_jni.c over native/gxns). Loaded on
 * first use; [loadError] says why it is unavailable (ABI without the library,
 * a stripped build), in which case noise suppression resolves to off.
 */
internal object GxNsNative {
  // gx_ns_engine
  const val ENGINE_OFF = 0
  const val ENGINE_RNNOISE = 1
  const val ENGINE_DFN3 = 2

  // gx_ns_agc_order
  const val AGC_AFTER_NS = 0
  const val AGC_BEFORE_NS = 1

  @Volatile var loadError: String? = null
    private set

  private val loaded: Boolean by lazy {
    try {
      System.loadLibrary("gxns")
      true
    } catch (t: Throwable) {
      loadError = "library_missing: ${t.javaClass.simpleName}"
      false
    }
  }

  fun available(): Boolean = loaded

  fun engineName(e: Int): String = when (e) {
    ENGINE_RNNOISE -> "rnnoise"
    ENGINE_DFN3 -> "dfn3"
    else -> "off"
  }

  fun engineOf(name: String?): Int = when (name) {
    "rnnoise" -> ENGINE_RNNOISE
    "dfn3" -> ENGINE_DFN3
    else -> ENGINE_OFF
  }

  @JvmStatic external fun nativeCreate(engine: Int, agcEnabled: Int, agcOrder: Int, watchdogUs: Int, p95WindowBlocks: Int): Long
  @JvmStatic external fun nativeDestroy(h: Long)
  @JvmStatic external fun nativeProcess(h: Long, buf: ByteBuffer, n: Int, rate: Int): Int
  @JvmStatic external fun nativeSetEngine(h: Long, engine: Int)
  @JvmStatic external fun nativeSetBypass(h: Long, bypass: Boolean)
  @JvmStatic external fun nativeSetAgc(h: Long, on: Boolean, order: Int)
  @JvmStatic external fun nativeRequestReset(h: Long)
  @JvmStatic external fun nativeResetStats(h: Long)

  /** Studio attenuation limit (centi-dB, 0 = none) + rolling-p95 budget (us, 0 = off), live. */
  @JvmStatic external fun nativeSetStudioLimits(h: Long, attenCentiDb: Int, p95BudgetUs: Int)

  /** out[0..9] = frames, p50, p95, p99, max, over, consecutive, underflows, extErrors, switches */
  @JvmStatic external fun nativeStats(h: Long, out: IntArray)

  /** out[0..6] = requested, active, crossfading, reason, rate, latency, agcGainDb*100; returns vad*1000 */
  @JvmStatic external fun nativeStatus(h: Long, out: IntArray): Int
  @JvmStatic external fun nativeReasonName(reason: Int): String
  /** gx_ns_pregain_for_level: the pre-gain (dB) for speech at [db] dBFS. */
  @JvmStatic external fun nativePregainForLevel(db: Float): Float

  /** Studio seam: a `gx_ns_external_engine*` from the engine's own library, or 0 to detach. */
  @JvmStatic external fun nativeAttachExternal(h: Long, enginePtr: Long): Int
  @JvmStatic external fun nativeBlocks(h: Long): Int
}

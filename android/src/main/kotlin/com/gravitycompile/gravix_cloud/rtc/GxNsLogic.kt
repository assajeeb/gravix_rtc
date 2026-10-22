package com.gravitycompile.gravix_cloud.rtc

/**
 * Pure decisions of the noise-suppression processor (no Android, no JNI), so
 * the JVM unit tests cover them: frame shape, route names, the watchdog and
 * the engine actually used.
 */
internal object GxNsFrameShape {
  private val RATES = intArrayOf(8000, 16000, 24000, 32000, 44100, 48000)

  /** APM frames are 10 ms: rate = numFrames * 100, if gx_ns supports it. */
  fun rateOf(numFrames: Int): Int? {
    val r = numFrames * 100
    return if (r in RATES) r else null
  }

  /**
   * Null when the buffer can be processed in place as mono full-band floats,
   * else the reason to stay passthrough. [channels] = initialize()'s count
   * (0 = not seen; the hook may be added after APM initialized).
   */
  fun reject(numFrames: Int, capacityBytes: Int, direct: Boolean, channels: Int): String? = when {
    !direct -> "buffer_not_direct"
    channels > 1 -> "channels_$channels"
    rateOf(numFrames) == null -> "rate_${numFrames * 100}"
    capacityBytes != numFrames * 4 -> "layout_cap${capacityBytes}_frames$numFrames"
    else -> null
  }
}

internal object GxNsRoute {
  /**
   * The plan's route names from GxAudioSwitchManager's `current` (AudioRoutePolicy)
   * and the audio mode: Bluetooth in a communication mode is SCO (HFP),
   * in the media mode A2DP.
   */
  fun of(current: String?, audioMode: Int?): String = when (current) {
    AudioRoutePolicy.SPEAKER -> "speaker"
    AudioRoutePolicy.EARPIECE -> "earpiece"
    AudioRoutePolicy.WIRED -> "wired"
    AudioRoutePolicy.USB -> "usb"
    AudioRoutePolicy.BLUETOOTH ->
      if (audioMode == AudioRoutePolicy.MODE_IN_COMMUNICATION || audioMode == AudioRoutePolicy.MODE_IN_CALL) "bt-sco" else "bt-a2dp"
    else -> "unknown"
  }

  fun isBluetooth(route: String): Boolean = route.startsWith("bt-")

  /** SCO / HFP microphones are 8-16 kHz content (auto keeps RNNoise there). */
  fun isNarrowband(route: String): Boolean = route == "bt-sco"
}

/** 3 consecutive frames over the budget (owner spec §4). Audio thread only. */
internal class GxNsWatchdog(private val limitNs: Long, private val consecutive: Int) {
  private var run = 0
  var tripped = false
    private set

  /** Returns true exactly once, on the frame that trips it. */
  fun onFrame(ns: Long): Boolean {
    if (ns > limitNs) run++ else run = 0
    if (!tripped && run >= consecutive) {
      tripped = true
      return true
    }
    return false
  }

  fun rearm() {
    tripped = false
    run = 0
  }
}

/** The engine actually run, from the requested one and the live conditions. */
internal object GxNsFallback {
  data class Decision(val engine: Int, val reason: String)

  fun decide(
    requested: Int,
    requestReason: String,
    watchdogTripped: Boolean,
    thermalHot: Boolean,
    batterySaver: Boolean,
    preferHeadset: Boolean,
    route: String,
    thermalFallback: Boolean = true,
    batterySaverFallback: Boolean = true,
    studioSlow: Boolean = false,
    studioSuppress: Boolean = false,
  ): Decision {
    if (requested == GxNsNative.ENGINE_OFF) return Decision(GxNsNative.ENGINE_OFF, requestReason)
    if (preferHeadset && GxNsRoute.isBluetooth(route)) return Decision(GxNsNative.ENGINE_OFF, "headset_ns")
    if (requested == GxNsNative.ENGINE_DFN3) {
      if (watchdogTripped) return Decision(GxNsNative.ENGINE_RNNOISE, "watchdog_frame")
      // gx_ns rolling p95 of the studio engine over ~2 s above budget (thermal drift mid-call)
      if (studioSlow) return Decision(GxNsNative.ENGINE_RNNOISE, "studio_slow")
      // gx_ns: studio output speech collapsed vs its input (live guard)
      if (studioSuppress) return Decision(GxNsNative.ENGINE_RNNOISE, "studio_suppress")
      if (thermalFallback && thermalHot) return Decision(GxNsNative.ENGINE_RNNOISE, "thermal")
      if (batterySaverFallback && batterySaver) return Decision(GxNsNative.ENGINE_RNNOISE, "battery_saver")
    }
    return Decision(requested, requestReason)
  }
}

/** Our AGC runs only with an engine on and the own-AGC order (off / kill switch: WebRTC's AGC owns the level). */
internal object GxNsAgc {
  fun ownOn(requested: Int, agcOrder: String?): Boolean =
    requested != GxNsNative.ENGINE_OFF && agcOrder != "webrtcBeforeNs" && agcOrder != "none"
}

/**
 * Capture blocks inside gx_ns: the counter is odd while one is running. A
 * retired studio engine is freed at once when [idle], else after [advancedSince].
 */
internal class GxNsInFlight {
  private val seq = java.util.concurrent.atomic.AtomicLong(0)
  fun enter() { seq.incrementAndGet() }
  fun exit() { seq.incrementAndGet() }
  fun snapshot(): Long = seq.get()
  fun advancedSince(s0: Long): Boolean = seq.get() != s0
  companion object {
    fun idle(s: Long): Boolean = s and 1L == 0L
  }
}

/** Copies at most [limit] bytes; returns the count, or -1 once the source has more (never reads past limit + 1). */
internal fun gxNsCopyBounded(inp: java.io.InputStream, out: java.io.OutputStream, limit: Long): Long {
  val buf = ByteArray(64 * 1024)
  var total = 0L
  while (true) {
    val want = minOf(buf.size.toLong(), limit - total + 1).toInt()
    val n = inp.read(buf, 0, want)
    if (n < 0) return total
    total += n
    if (total > limit) return -1
    out.write(buf, 0, n)
  }
}

/** Studio packs only over https (the SHA-256 check is the integrity guard, https keeps the URL private). */
internal fun gxNsPackUrlOk(url: String): Boolean = url.startsWith("https://", ignoreCase = true)

/** `[GravixNS] <step> eng=<> route=<> rate=<> [+<ms>ms] [detail]` (plan §3, same as Dart/JS). */
internal fun gxNsLine(step: String, eng: String, route: String, rate: Int, elapsedMs: Long? = null, detail: String? = null): String {
  val b = StringBuilder("[GravixNS] ").append(step).append(" eng=").append(eng).append(" route=").append(route)
    .append(" rate=").append(if (rate > 0) rate.toString() else "?")
  if (elapsedMs != null) b.append(" +").append(elapsedMs).append("ms")
  if (!detail.isNullOrEmpty()) b.append(' ').append(detail)
  return b.toString()
}

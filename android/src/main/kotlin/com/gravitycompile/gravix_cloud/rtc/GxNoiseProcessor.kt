package com.gravitycompile.gravix_cloud.rtc

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import com.cloudwebrtc.webrtc.audio.AudioProcessingController
import java.io.File
import java.nio.ByteBuffer

/**
 * On-device noise suppression on WebRTC's capture path (plan 2026-10-15 §1b):
 * flutter_webrtc's APM capturePostProcessing slot, i.e. after AEC (and after
 * WebRTC's own NS/AGC, which the SDK turns off while ours runs). One processor
 * per process: the audio device module has one capture stream.
 *
 * process() runs on WebRTC's audio thread, in place on the APM's direct float
 * buffer (int16 scale), through libgxns (RNNoise + crossfades + our AGC +
 * limiter). It never allocates or logs; a 1 s ticker thread does the logging
 * (`[GravixNS]`, tag GravixNS) and the events to Dart.
 *
 * The native state is created once and kept for the process lifetime (never
 * destroyed under a running audio thread). "Off" after install = engine OFF
 * (dry, +10 ms delay), so a later "on" crossfades instead of jumping.
 */
internal object GxNoiseProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
  private const val TAG = "GravixNS"
  private const val SUMMARY_EVERY_S = 10

  @Volatile private var handle = 0L
  @Volatile private var controller: AudioProcessingController? = null
  @Volatile private var appContext: Context? = null

  /** Events to Dart (`onNoiseSuppression`); set by GravixClientPlugin. Called on the ticker/main thread. */
  @Volatile var eventSink: ((Map<String, Any?>) -> Unit)? = null

  /** WebRTC's audio processing state readback (is its NS/AGC really off?); set by GravixClientPlugin. */
  @Volatile var stateReader: (() -> String?)? = null

  // --- configuration from Dart (nsConfigure) ---
  @Volatile private var mode = "off"
  @Volatile private var requested = GxNsNative.ENGINE_OFF
  @Volatile private var requestReason = "mode_off"
  @Volatile private var agcOn = true
  @Volatile private var agcOrder = GxNsNative.AGC_AFTER_NS
  @Volatile private var agcOrderName = "ownAfterNs"
  @Volatile private var musicBypassEnabled = true
  @Volatile private var preferHeadset = false
  @Volatile private var thermalFallback = true
  @Volatile private var saverFallback = true
  @Volatile private var watchdogNs = 8_000_000L
  @Volatile private var watchdogConsecutive = 3

  // --- live conditions ---
  @Volatile private var route = "unknown"
  @Volatile private var thermalHot = false
  @Volatile private var batterySaver = false
  @Volatile private var musicActive = false
  @Volatile private var musicSinceMs = 0L
  @Volatile private var decided = GxNsNative.ENGINE_OFF
  @Volatile private var decidedReason = "mode_off"

  // --- audio thread state ---
  @Volatile private var initRate = 0
  @Volatile private var initChannels = 0
  @Volatile private var lastNumFrames = -1
  @Volatile private var lastBands = -1
  @Volatile private var lastCap = -1
  @Volatile private var lastDirect = false
  @Volatile private var procRate = 0
  @Volatile private var shapeReject: String? = "no_frame"
  @Volatile private var shapeSeq = 0
  @Volatile private var processErrors = 0
  @Volatile private var audioTid = 0
  @Volatile private var watchdog = GxNsWatchdog(watchdogNs, watchdogConsecutive)
  @Volatile private var watchdogTripped = false
  // studio attenuation limit + mid-call rolling-p95 fallback (gx_ns), LL opt-in
  @Volatile private var studioAttenLimitDb = 40.0
  @Volatile private var studioP95BudgetUs = 3000
  @Volatile private var studioP95WindowMs = 2000
  @Volatile private var studioLowLatency = false
  @Volatile private var studioSlow = false
  @Volatile private var studioSuppress = false
  @Volatile private var watchdogLogged = false

  // --- studio (DFN3) ---
  @Volatile private var studioModel: GxNsStudio.Model = GxNsStudio.STD
  @Volatile private var studioEngine: GxNsStudio.Engine? = null
  @Volatile private var studioAttached = false
  @Volatile private var studioLoading = false
  @Volatile private var studioSource = "auto"
  @Volatile private var studioDownload = "unmeteredIdle"
  @Volatile private var studioPackUrl: String? = null
  /** Is a capture block inside gx_ns right now (frees retired engines without waiting). */
  private val inFlight = GxNsInFlight()
  private val studioExec = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "GravixNS-studio") }

  // --- ticker ---
  private var ticker: Handler? = null
  private var shapeSeqLogged = 0
  private var lastActive = -1
  private var lastReasonName = ""
  private var tick = 0
  private var cpuTicks0 = -1L
  private var cpuWall0 = 0L
  private val statsBuf = IntArray(13)
  private val statusBuf = IntArray(11)

  // ============================== audio thread ==============================

  override fun initialize(sampleRateHz: Int, numChannels: Int) {
    initRate = sampleRateHz
    initChannels = numChannels
    lastNumFrames = -1 // re-check the shape at the next frame
  }

  override fun reset(newRate: Int) {
    initRate = newRate
    lastNumFrames = -1
  }

  override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
    val h = handle
    if (h == 0L) return
    val cap = buffer.capacity()
    if (numFrames != lastNumFrames || cap != lastCap || numBands != lastBands) {
      // first frame or a new shape (rare): validate, the ticker logs it
      lastNumFrames = numFrames
      lastCap = cap
      lastBands = numBands
      lastDirect = buffer.isDirect
      procRate = GxNsFrameShape.rateOf(numFrames) ?: 0
      shapeReject = GxNsFrameShape.reject(numFrames, cap, lastDirect, initChannels)
      audioTid = Process.myTid()
      shapeSeq++
      if (procRate > 0) GxCaptureDump.start(appContext, procRate) // diagnostic: no-op unless debug.gravix.capdump=1
    }
    GxCaptureDump.onPre(buffer, numFrames)
    if (shapeReject != null) {
      GxCaptureDump.onPost(buffer, numFrames, false)
      return
    }
    val t0 = System.nanoTime()
    inFlight.enter()
    try {
      if (GxNsNative.nativeProcess(h, buffer, numFrames, procRate) != 0) processErrors++
    } finally {
      inFlight.exit()
    }
    GxCaptureDump.onPost(buffer, numFrames, true)
    if (watchdog.onFrame(System.nanoTime() - t0)) {
      watchdogTripped = true
      // studio -> standard right here (an atomic store in gx_ns); RNNoise over
      // budget is only logged (nothing lighter to fall back to)
      if (requested == GxNsNative.ENGINE_DFN3) GxNsNative.nativeSetEngine(h, GxNsNative.ENGINE_RNNOISE)
    }
  }

  // ============================== control (main thread) ==============================

  /** nsConfigure from Dart. Returns `{ok, installed, reason?, engine, route, rate}`. */
  @Synchronized
  fun configure(context: Context?, plugin: FlutterWebRTCPlugin?, args: Map<String, Any?>): Map<String, Any?> {
    val t0 = SystemClock.elapsedRealtime()
    if (context != null) appContext = context.applicationContext
    mode = args["mode"] as? String ?: "off"
    requested = GxNsNative.engineOf(args["engine"] as? String)
    requestReason = args["reason"] as? String ?: "mode_$mode"
    // off / kill switch: WebRTC's AGC is back on there, ours must not stack on it (review #1)
    agcOn = GxNsAgc.ownOn(requested, args["agcOrder"] as? String)
    agcOrderName = args["agcOrder"] as? String ?: "ownAfterNs"
    agcOrder = GxNsNative.AGC_AFTER_NS
    musicBypassEnabled = args["musicBypass"] as? Boolean ?: true
    preferHeadset = args["headsetNs"] == "preferHeadset"
    thermalFallback = args["thermalFallback"] as? Boolean ?: true
    saverFallback = args["batterySaverFallback"] as? Boolean ?: true
    watchdogNs = ((args["watchdogFrameUs"] as? Number)?.toLong() ?: 8000L) * 1000L
    watchdogConsecutive = (args["watchdogConsecutive"] as? Number)?.toInt() ?: 3
    watchdog = GxNsWatchdog(watchdogNs, watchdogConsecutive)
    watchdogTripped = false
    watchdogLogged = false
    studioAttenLimitDb = (args["studioAttenLimitDb"] as? Number)?.toDouble() ?: 40.0
    studioP95BudgetUs = (args["studioP95BudgetUs"] as? Number)?.toInt() ?: 3000
    studioP95WindowMs = (args["studioP95WindowMs"] as? Number)?.toInt() ?: 2000
    studioLowLatency = args["studioLowLatency"] as? Boolean ?: false
    studioSlow = false
    studioSuppress = false
    studioSource = args["studioSource"] as? String ?: "auto"
    studioDownload = args["studioDownload"] as? String ?: "unmeteredIdle"
    studioPackUrl = args["studioPackUrl"] as? String
    // LL only when the app opted in (studioLowLatency); otherwise the bundled standard model
    (args["studioModel"] as? String)?.let { studioModel = if (it == "ll" && studioLowLatency) GxNsStudio.LL else GxNsStudio.STD }
    if (!studioLowLatency) studioModel = GxNsStudio.STD

    if (!GxNsNative.available()) {
      val why = GxNsNative.loadError ?: "library_missing"
      log("install", GxNsNative.ENGINE_OFF, "ok=false reason=$why abi=${Build.SUPPORTED_ABIS.firstOrNull()}", t0)
      return mapOf("ok" to false, "installed" to false, "reason" to why)
    }
    if (handle == 0L) {
      if (requested == GxNsNative.ENGINE_OFF) {
        // legacy / off at join: nothing on the capture path, zero cost
        log("install", GxNsNative.ENGINE_OFF, "skipped mode=$mode", t0)
        return mapOf("ok" to true, "installed" to false, "engine" to "off", "route" to route)
      }
      val h = GxNsNative.nativeCreate(requested, if (agcOn) 1 else 0, agcOrder, (watchdogNs / 1000L).toInt(), studioP95WindowMs / 10)
      if (h == 0L) {
        log("install", GxNsNative.ENGINE_OFF, "ok=false reason=create_failed", t0)
        return mapOf("ok" to false, "installed" to false, "reason" to "create_failed")
      }
      handle = h
      startTicker()
      watchPower()
    }
    val h = handle
    GxNsNative.nativeSetAgc(h, agcOn, agcOrder)
    GxNsNative.nativeSetStudioLimits(h, (studioAttenLimitDb * 100).toInt(), studioP95BudgetUs)
    GxNsNative.nativeSetBypass(h, musicBypassEnabled && musicActive)
    applyDecision("configure")
    val installed = installOn(plugin, "configure")
    if ((mode == "auto" || mode == "studio") && studioLowLatency) ensurePack()
    log(
      "init", decided,
      "mode=$mode requested=${GxNsNative.engineName(requested)} reason=$decidedReason agc=${if (agcOn) "ownAfterNs" else agcOrderName} " +
        "musicBypass=$musicBypassEnabled headsetNs=${if (preferHeadset) "preferHeadset" else "keepOurs"} installed=$installed",
      t0,
    )
    return mapOf(
      "ok" to true, "installed" to installed, "engine" to GxNsNative.engineName(decided),
      "reason" to decidedReason, "route" to route, "rate" to procRate,
    )
  }

  /**
   * Adds the processor to [plugin]'s APM (idempotent, per controller). Called at
   * configure and in handleStartLocalRecording, before the record thread
   * starts (the adapter forwards initialize() only to processors present then;
   * process() does not depend on it: rate = numFrames * 100).
   */
  @Synchronized
  fun installOn(plugin: FlutterWebRTCPlugin?, where: String): Boolean {
    if (handle == 0L) return false
    val c = try {
      plugin?.audioProcessingController
    } catch (t: Throwable) {
      null
    } ?: return controller != null
    if (controller === c) return true
    try {
      controller?.capturePostProcessing?.removeProcessor(this)
      c.capturePostProcessing.addProcessor(this)
      controller = c
      lastNumFrames = -1
      log("install", decided, "where=$where controller=${System.identityHashCode(c)}")
      return true
    } catch (t: Throwable) {
      Log.w(TAG, "[GravixNS] install failed where=$where: $t")
      return false
    }
  }

  /** Studio seam: attach a `gx_ns_external_engine*` (0 = detach). Phase 3 wires the ORT DFN3 engine here. */
  @Synchronized
  fun attachExternalEngine(enginePtr: Long): Int {
    val h = handle
    if (h == 0L) return -1
    val rc = GxNsNative.nativeAttachExternal(h, enginePtr)
    log("pack", decided, "external=${if (enginePtr == 0L) "detached" else "attached"} rc=$rc")
    return rc
  }

  /** GxAudioSwitchManager.onRoutesChanged (main thread). */
  fun onRoutes(snapshot: Map<String, Any?>) {
    val next = GxNsRoute.of(snapshot["current"] as? String, (snapshot["mode"] as? Number)?.toInt())
    onRoute(next, snapshot["reason"] as? String ?: "routes")
  }

  /** Chatroom model: SCO engaged / released (main thread). */
  fun onChatroom(engaged: Boolean) {
    if (engaged) onRoute("bt-sco", "chatroom")
  }

  @Synchronized
  private fun onRoute(next: String, why: String) {
    val prev = route
    if (next == prev) return
    route = next
    val h = handle
    if (h == 0L) return
    // soft reset: fade to dry, reset the engine state, fade back (~40 ms)
    GxNsNative.nativeRequestReset(h)
    lastNumFrames = -1 // re-check the shape and rate at the next frame
    applyDecision("route")
    log("routeReset", decided, "from=$prev why=$why narrowband=${GxNsRoute.isNarrowband(next)}")
    emit("routeReset", mapOf("from" to prev))
  }

  /** MusicMixerEngine session start / end (any thread). */
  fun onMusic(active: Boolean) {
    if (musicActive == active) return
    musicActive = active
    val now = SystemClock.elapsedRealtime()
    val h = handle
    val bypass = musicBypassEnabled && active
    if (h != 0L && musicBypassEnabled) GxNsNative.nativeSetBypass(h, active)
    if (h == 0L) return
    val detail = if (active) {
      musicSinceMs = now
      "on enabled=$musicBypassEnabled"
    } else {
      "off ms=${now - musicSinceMs}"
    }
    log("musicBypass", decided, detail)
    emit("musicBypass", mapOf("musicBypass" to bypass))
  }

  @Synchronized
  private fun applyDecision(why: String) {
    val h = handle
    if (h == 0L) return
    val d = GxNsFallback.decide(
      requested, requestReason, watchdogTripped, thermalHot, batterySaver, preferHeadset, route,
      thermalFallback, saverFallback, studioSlow, studioSuppress,
    )
    val changed = d.engine != decided || d.reason != decidedReason
    val from = decided
    decided = d.engine
    decidedReason = d.reason
    if (d.engine == GxNsNative.ENGINE_DFN3) ensureStudioAttached() else detachStudio()
    GxNsNative.nativeSetEngine(h, d.engine)
    if (changed && why != "configure") {
      log("switch", d.engine, "from=${GxNsNative.engineName(from)} to=${GxNsNative.engineName(d.engine)} reason=${d.reason}")
      emit("switch", mapOf("from" to GxNsNative.engineName(from), "to" to GxNsNative.engineName(d.engine)))
    }
  }

  // ============================== studio engine ==============================

  /** Loads (background) and attaches the DFN3 engine of [studioModel]; gx_ns plays RNNoise until it is in. */
  private fun ensureStudioAttached() {
    val h = handle
    val ctx = appContext ?: return
    val want = studioModel
    val cur = studioEngine
    if (cur != null && cur.model == want) {
      if (!studioAttached) {
        val rc = GxNsNative.nativeAttachExternal(h, cur.ptr)
        studioAttached = rc == 0
        log("pack", decided, "attach model=${want.id} rc=$rc reused=true")
      }
      return
    }
    if (studioLoading) return
    studioLoading = true
    studioExec.execute {
      val t0 = SystemClock.elapsedRealtime()
      try {
        val e = GxNsStudio.create(ctx, want)
        if (e == null) {
          log("pack", decided, "load model=${want.id} ok=false reason=${GxNsStudio.loadError ?: "load_failed"}", t0)
          return@execute
        }
        synchronized(this) {
          val old = studioEngine
          if (old != null && studioAttached) GxNsNative.nativeAttachExternal(handle, 0L)
          studioAttached = false
          if (old != null) retire(old)
          studioEngine = e
          if (decided == GxNsNative.ENGINE_DFN3 && handle != 0L) {
            val rc = GxNsNative.nativeAttachExternal(handle, e.ptr)
            studioAttached = rc == 0
            log("pack", decided, "src=${if (want === GxNsStudio.STD) "bundled" else "pack"} model=${want.id} sha=ok attach rc=$rc latency=${want.latency}", t0)
          }
        }
      } finally {
        studioLoading = false
      }
    }
  }

  /** Detached engines stay loaded for reuse (no +latency on the other engines while detached). */
  private fun detachStudio() {
    if (!studioAttached) return
    GxNsNative.nativeAttachExternal(handle, 0L)
    studioAttached = false
    log("pack", decided, "detach model=${studioEngine?.model?.id}")
  }

  /**
   * Frees an engine once gx_ns cannot reference it any more: right away when no
   * capture block is inside gx_ns (the detach is already visible to the next
   * one), else once that block has returned. Called on [studioExec].
   */
  private fun retire(e: GxNsStudio.Engine) {
    val s0 = inFlight.snapshot()
    if (handle == 0L || GxNsInFlight.idle(s0)) {
      GxNsStudio.destroy(e)
      return
    }
    studioExec.execute {
      val deadline = SystemClock.elapsedRealtime() + 2000
      while (!inFlight.advancedSince(s0) && SystemClock.elapsedRealtime() < deadline) {
        try { Thread.sleep(5) } catch (_: InterruptedException) { break }
      }
      if (inFlight.advancedSince(s0)) GxNsStudio.destroy(e) // else leak rather than race
    }
  }

  /** The LL pack in the background (never blocks a join). */
  private fun ensurePack() {
    val ctx = appContext ?: return
    if (!GxNsStudio.available(ctx)) return
    val src = studioSource
    val dl = studioDownload
    val url = studioPackUrl
    studioExec.execute {
      val t0 = SystemClock.elapsedRealtime()
      val r = try { GxNsPack.ensure(ctx, src, dl, url) } catch (t: Throwable) { "error: $t" }
      log("pack", decided, "ll=$r src=$src download=$dl play=${GxNsPack.isPlayInstall(ctx)}", t0)
    }
  }

  /**
   * nsBenchmark: LL first when the app opted in (studioLowLatency) and its pack is
   * present (chosen if p95 < budget and the output is sane), else standard. Background thread; [reply] on the caller's handler.
   */
  fun benchmark(context: Context?, budgetUs: Int, reply: (Map<String, Any?>) -> Unit) {
    val ctx = (context ?: appContext)?.applicationContext
    if (ctx == null || !GxNsStudio.available(ctx)) {
      reply(mapOf("ok" to false, "reason" to (GxNsStudio.loadError ?: "studio_unavailable")))
      return
    }
    studioExec.execute {
      val runs = ArrayList<Map<String, Any?>>()
      var chosen: Map<String, Any?>? = null
      if (studioLowLatency && GxNsPack.llFile(ctx) != null) {
        val ll = GxNsStudio.benchmark(ctx, GxNsStudio.LL)
        runs.add(ll)
        if (ll["ok"] == true && ll["outputOk"] == true && ((ll["p95Us"] as? Int) ?: Int.MAX_VALUE) < budgetUs) chosen = ll
      }
      if (chosen == null) {
        val std = GxNsStudio.benchmark(ctx, GxNsStudio.STD)
        runs.add(std)
        chosen = std
      }
      val c = chosen
      if (c["ok"] == true) studioModel = if (c["model"] == "ll") GxNsStudio.LL else GxNsStudio.STD
      for (r in runs) {
        log("bench", decided, "model=${r["model"]} ok=${r["ok"]} p50=${r["p50Us"]} p95=${r["p95Us"]} max=${r["maxUs"]} " +
          "outputOk=${r["outputOk"]} parity=${r["paritySnrDb"]} inDb=${r["inDb"]} outDb=${r["outDb"]} " +
          "quietInDb=${r["quietInDb"]} quietOutDb=${r["quietOutDb"]} ms=${r["ms"]} reason=${r["reason"]}")
      }
      reply(HashMap(c).apply { put("runs", runs.size) })
    }
  }

  /** nsStats: the last stats + status (any thread). */
  fun stats(): Map<String, Any?>? {
    val h = handle
    if (h == 0L) return null
    val s = IntArray(10)
    val st = IntArray(11)
    GxNsNative.nativeStats(h, s)
    GxNsNative.nativeStatus(h, st)
    return mapOf(
      "frames" to s[0], "p50Us" to s[1], "p95Us" to s[2], "p99Us" to s[3], "maxUs" to s[4], "over" to s[5],
      "underflows" to s[7], "switches" to s[9],
      "eng" to GxNsNative.engineName(st[1]), "requested" to GxNsNative.engineName(st[0]),
      "reason" to if (st[3] != 0) GxNsNative.nativeReasonName(st[3]) else decidedReason,
      "route" to route, "rate" to st[4], "latencySamples" to st[5], "agcGainDb" to st[6] / 100.0,
      "preGainDb" to st[7] / 100.0, "agcAppliedDb" to st[9] / 100.0, "preGainAppliedDb" to st[8] / 100.0,
      "pauseAttDb" to st[10] / 100.0,
      "musicBypass" to (musicActive && musicBypassEnabled), "installed" to (controller != null),
      "shapeReject" to shapeReject,
      "studioModel" to studioEngine?.model?.id, "studioAttached" to studioAttached,
    )
  }

  // ============================== device facts ==============================

  fun deviceFacts(context: Context?): Map<String, Any?> {
    val am = context?.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
    val mem = ActivityManager.MemoryInfo().also { am?.getMemoryInfo(it) }
    return mapOf(
      "model" to Build.MODEL,
      "manufacturer" to Build.MANUFACTURER,
      "soc" to (if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else null),
      "osVersion" to Build.VERSION.RELEASE,
      "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
      "ramMb" to (if (mem.totalMem > 0) (mem.totalMem / (1024L * 1024L)).toInt() else null),
      "isLowRamDevice" to am?.isLowRamDevice,
      "mediaPerformanceClass" to (if (Build.VERSION.SDK_INT >= 31) Build.VERSION.MEDIA_PERFORMANCE_CLASS else 0),
      "cpuMaxFreqMhz" to cpuMaxFreqMhz(),
      "osBuild" to Build.FINGERPRINT,
    ) + studioFacts(context)
  }

  private fun studioFacts(context: Context?): Map<String, Any?> {
    val ctx = context ?: return mapOf("studioAvailable" to false)
    val ok = GxNsStudio.available(ctx)
    val best = if (ok) GxNsStudio.bestModel(ctx) else null
    return mapOf(
      "studioAvailable" to ok,
      "studioReason" to (if (ok) null else GxNsStudio.loadError),
      "studioModel" to best?.id,
      "studioSha" to best?.sha256,
      "studioRuntime" to GxNsStudio.RUNTIME,
    )
  }

  private fun cpuMaxFreqMhz(): Int? = try {
    (File("/sys/devices/system/cpu").listFiles() ?: emptyArray())
      .filter { it.name.matches(Regex("cpu\\d+")) }
      .mapNotNull { File(it, "cpufreq/cpuinfo_max_freq").takeIf { f -> f.canRead() }?.readText()?.trim()?.toLongOrNull() }
      .maxOrNull()?.let { (it / 1000L).toInt() }
  } catch (_: Throwable) {
    null
  }

  // ============================== power watch ==============================

  private fun watchPower() {
    val ctx = appContext ?: return
    val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
    batterySaver = pm.isPowerSaveMode
    try {
      val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
      val r = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
          val on = pm.isPowerSaveMode
          if (on != batterySaver) {
            batterySaver = on
            log("power", decided, "batterySaver=$on")
            applyDecision("battery_saver")
          }
        }
      }
      if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
      else ctx.registerReceiver(r, filter)
    } catch (t: Throwable) {
      Log.w(TAG, "[GravixNS] battery saver watch failed: $t")
    }
    if (Build.VERSION.SDK_INT >= 29) {
      try {
        thermalHot = pm.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE
        pm.addThermalStatusListener(ctx.mainExecutor) { status ->
          val hot = status >= PowerManager.THERMAL_STATUS_MODERATE
          if (hot != thermalHot) {
            thermalHot = hot
            log("power", decided, "thermalStatus=$status hot=$hot")
            applyDecision("thermal")
          }
        }
      } catch (t: Throwable) {
        Log.w(TAG, "[GravixNS] thermal watch failed: $t")
      }
    }
  }

  // ============================== ticker (logs, events) ==============================

  private fun startTicker() {
    if (ticker != null) return
    val t = HandlerThread("GravixNS").apply { start() }
    val h = Handler(t.looper)
    ticker = h
    h.postDelayed(object : Runnable {
      override fun run() {
        try {
          onTick()
        } catch (e: Throwable) {
          Log.w(TAG, "[GravixNS] ticker: $e")
        }
        h.postDelayed(this, 1000)
      }
    }, 1000)
  }

  private fun onTick() {
    val h = handle
    if (h == 0L) return
    tick++
    val seq = shapeSeq
    if (seq != shapeSeqLogged) {
      shapeSeqLogged = seq
      // the APM hook's frame shape (plan [P]: Phase 0 measured here)
      log(
        "init", decided,
        "bands=$lastBands frames=$lastNumFrames cap=$lastCap direct=$lastDirect initRate=$initRate initCh=$initChannels " +
          "tid=$audioTid process=${if (shapeReject == null) "yes" else "no reason=$shapeReject"} " +
          "webrtc=${try { stateReader?.invoke() } catch (t: Throwable) { "unreadable" }}",
      )
      val rej = shapeReject
      // passthrough: say so (eng=off), the resolved engine is not running
      if (rej != null) emit("init", mapOf("shapeReject" to rej, "eng" to "off", "reason" to "shape_$rej"))
      else emit("init", mapOf("shapeReject" to null))
    }
    if (watchdogTripped && !watchdogLogged) {
      watchdogLogged = true
      if (requested == GxNsNative.ENGINE_DFN3) {
        applyDecision("watchdog")
      } else {
        log("watchdog", decided, "over=${watchdogConsecutive}x>${watchdogNs / 1000}us kept (nothing lighter)")
      }
    }
    GxNsNative.nativeStatus(h, statusBuf)
    val active = statusBuf[1]
    val reasonName = if (statusBuf[3] != 0) GxNsNative.nativeReasonName(statusBuf[3]) else decidedReason
    if (reasonName == "studio_slow" && !studioSlow && requested == GxNsNative.ENGINE_DFN3) {
      // gx_ns already plays RNNoise (crossfade); record why and detach the studio engine
      studioSlow = true
      GxNsNative.nativeStats(h, statsBuf)
      log(
        "watchdog", GxNsNative.ENGINE_RNNOISE,
        "studio_slow p95=${statsBuf[10]}us>budget=${studioP95BudgetUs}us window=${studioP95WindowMs}ms model=${studioEngine?.model?.id} -> rnnoise",
      )
      applyDecision("studio_slow")
    }
    if (reasonName == "studio_suppress" && !studioSuppress && requested == GxNsNative.ENGINE_DFN3) {
      // gx_ns already plays RNNoise: the studio output speech collapsed vs its input for 2 s
      studioSuppress = true
      log("watchdog", GxNsNative.ENGINE_RNNOISE, "studio_suppress model=${studioEngine?.model?.id} -> rnnoise")
      applyDecision("studio_suppress")
    }
    if (statusBuf[2] == 0 && (active != lastActive || reasonName != lastReasonName)) {
      if (lastActive >= 0) {
        log("active", active, "from=${GxNsNative.engineName(lastActive)} reason=$reasonName")
      }
      lastActive = active
      lastReasonName = reasonName
    }
    if (tick % SUMMARY_EVERY_S == 0) summary(h)
  }

  private fun summary(h: Long) {
    GxNsNative.nativeStats(h, statsBuf)
    if (statsBuf[0] == 0) return
    val cpu = processCpuPercent()
    val detail = "p50=${statsBuf[1]} p95=${statsBuf[2]} p99=${statsBuf[3]} max=${statsBuf[4]} over=${statsBuf[5]}" +
      (if (cpu != null) " cpu=${String.format(java.util.Locale.US, "%.1f", cpu)}" else "") +
      " frames=${statsBuf[0]} underflows=${statsBuf[7]} switches=${statsBuf[9]} errors=$processErrors" +
      " music=${musicActive && musicBypassEnabled} agcDb=${statusBuf[6] / 100.0} preDb=${statusBuf[7] / 100.0}" +
      " agcAppliedDb=${statusBuf[9] / 100.0} preAppliedDb=${statusBuf[8] / 100.0} pauseAttDb=${statusBuf[10] / 100.0}"
    log("summary", lastActive.coerceAtLeast(0), detail)
    emit(
      "summary",
      mapOf(
        "p50Us" to statsBuf[1], "p95Us" to statsBuf[2], "p99Us" to statsBuf[3], "maxUs" to statsBuf[4],
        "over" to statsBuf[5], "cpu" to cpu,
      ),
    )
    GxNsNative.nativeResetStats(h)
  }

  /** Whole-process CPU % of one core since the last call (/proc/self/stat utime+stime). */
  private fun processCpuPercent(): Double? = try {
    val f = File("/proc/self/stat").readText()
    val rest = f.substring(f.lastIndexOf(')') + 2).split(' ')
    val ticks = rest[11].toLong() + rest[12].toLong() // fields 14, 15
    val now = SystemClock.elapsedRealtime()
    val prev = cpuTicks0
    val prevWall = cpuWall0
    cpuTicks0 = ticks
    cpuWall0 = now
    if (prev < 0 || now <= prevWall) null else (ticks - prev) * 10.0 * 100.0 / (now - prevWall) // 100 Hz clock
  } catch (_: Throwable) {
    null
  }

  // ============================== logging ==============================

  private fun log(step: String, eng: Int, detail: String?, t0: Long? = null) {
    val elapsed = t0?.let { SystemClock.elapsedRealtime() - it }
    Log.i(TAG, gxNsLine(step, GxNsNative.engineName(eng), route, procRate, elapsed, detail))
  }

  private fun emit(step: String, extra: Map<String, Any?>) {
    val sink = eventSink ?: return
    val m = HashMap<String, Any?>()
    m["step"] = step
    m["eng"] = GxNsNative.engineName(decided)
    m["reason"] = decidedReason
    m["route"] = route
    m["rate"] = procRate
    m.putAll(extra)
    try {
      sink(m)
    } catch (_: Throwable) {
    }
  }
}

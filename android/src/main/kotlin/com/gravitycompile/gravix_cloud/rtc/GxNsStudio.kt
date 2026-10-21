package com.gravitycompile.gravix_cloud.rtc

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * Studio engine (DeepFilterNet3) on the bundled minimal ONNX Runtime
 * (libgxns_dfn.so + libgxort.so = ORT with a Gravix-private soname, arm64-v8a only).
 *
 * The studio files ship as arm64-v8a "native libraries" so other ABIs carry
 * none of them: libgxns_dfn3_std.so (the .ort model), libgxns_dfn3_bench.so
 * (2 s WAV clip), libgxns_dfn3_ref.so (reference output, int16). Read from the
 * native library dir when extracted, else straight from the (split) APK, where
 * they are stored uncompressed. An app drops them with `gravixNsStudio=false`
 * (gradle.properties) or turns studio off at runtime with the manifest
 * meta-data `com.gravitycompile.gravix_ns.studio` = false.
 *
 * Models:
 * - standard (bundled): libgxns_dfn3_std.so, 30 ms latency.
 * - low latency (downloaded, [GxNsPack]): dfn3_ll_int8.ort, 10 ms latency,
 *   used when present, verified and its benchmark passes.
 * The SHA-256 of every model is compiled in here (release manifest 2026-10-21).
 */
internal object GxNsStudio {
  private const val TAG = "GravixNS"
  const val RUNTIME = "ort-1.31.0"

  data class Model(val id: String, val file: String, val sha256: String, val bytes: Long, val latency: Int)

  val STD = Model("std", "dfn3_std_int8.ort", "0e4c4f4fc2c5f564528419957267f017fb3d0fc8f1bc33765d06dca67230e14d", 2988880L, 1440)
  val LL = Model("ll", "dfn3_ll_int8.ort", "581535e7e600034b52f3621e873939e972f1851e9babec34e882a11f6f1e9348", 11099368L, 480)

  private const val STD_LIB = "libgxns_dfn3_std.so"
  private const val BENCH_CLIP = "libgxns_dfn3_bench.so"
  private const val BENCH_REF_STD = "libgxns_dfn3_ref.so"
  private const val META_STUDIO = "com.gravitycompile.gravix_ns.studio"

  @Volatile var loadError: String? = null
    private set

  private val loaded: Boolean by lazy {
    if (Build.SUPPORTED_ABIS.firstOrNull() != "arm64-v8a") {
      loadError = "abi_${Build.SUPPORTED_ABIS.firstOrNull()}"
      false
    } else {
      try {
        System.loadLibrary("gxort")
        System.loadLibrary("gxns_dfn")
        true
      } catch (t: Throwable) {
        loadError = "runtime_missing: ${t.javaClass.simpleName}"
        false
      }
    }
  }

  /** The runtime loads, the app did not turn studio off, and the bundled standard model is in the APK. */
  fun available(ctx: Context): Boolean = loaded && manifestAllows(ctx) && libFileSize(ctx, STD_LIB) == STD.bytes

  /** The best model on this device now: LL when its verified pack is present, else standard. */
  fun bestModel(ctx: Context): Model = if (GxNsPack.llFile(ctx) != null) LL else STD

  private fun manifestAllows(ctx: Context): Boolean = try {
    @Suppress("DEPRECATION")
    val ai = ctx.packageManager.getApplicationInfo(ctx.packageName, android.content.pm.PackageManager.GET_META_DATA)
    val v = ai.metaData?.get(META_STUDIO)
    if (v == null) true else v.toString().toBoolean().also { if (!it) loadError = "studio_disabled_manifest" }
  } catch (_: Throwable) {
    true
  }

  /** APKs holding this app's native libs: base + splits (an AAB installs lib/ in a config split). */
  private fun apks(ctx: Context): List<String> {
    val ai = ctx.applicationInfo
    return listOfNotNull(ai.sourceDir) + (ai.splitSourceDirs?.toList() ?: emptyList())
  }

  private fun extracted(ctx: Context, name: String): File? =
    File(ctx.applicationInfo.nativeLibraryDir ?: return null, name).takeIf { it.isFile }

  private fun libFileSize(ctx: Context, name: String): Long {
    extracted(ctx, name)?.let { return it.length() }
    for (apk in apks(ctx)) {
      try {
        java.util.zip.ZipFile(apk).use { z -> z.getEntry("lib/arm64-v8a/$name")?.let { return it.size } }
      } catch (_: Throwable) {
      }
    }
    return -1L
  }

  private fun libBytes(ctx: Context, name: String): ByteArray {
    extracted(ctx, name)?.let { return it.readBytes() }
    for (apk in apks(ctx)) {
      val bytes = java.util.zip.ZipFile(apk).use { z ->
        z.getEntry("lib/arm64-v8a/$name")?.let { e -> z.getInputStream(e).use { it.readBytes() } }
      }
      if (bytes != null) return bytes
    }
    throw java.io.FileNotFoundException(name)
  }

  private fun readAll(ctx: Context, m: Model): ByteBuffer? {
    val bytes = if (m === STD) {
      libBytes(ctx, STD_LIB)
    } else {
      GxNsPack.llFile(ctx)?.readBytes() ?: return null
    }
    return ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).apply { put(bytes); flip() }
  }

  /** A loaded engine: `ptr` = gx_ns_external_engine*, `model` its model. Background thread (loads ~100s of ms). */
  class Engine(val ptr: Long, val model: Model)

  fun create(ctx: Context, m: Model): Engine? {
    if (!loaded) return null
    val buf = try {
      readAll(ctx, m)
    } catch (t: Throwable) {
      Log.w(TAG, "[GravixNS] dfn3 model ${m.id} unreadable: $t")
      null
    } ?: return null
    val ptr = nativeCreate(buf, m.latency)
    return if (ptr == 0L) null else Engine(ptr, m)
  }

  fun destroy(e: Engine) = nativeDestroy(e.ptr)

  /**
   * First-run benchmark (plan §4): 20 warm-up + 200 timed frames of the 2 s
   * clip on a separate engine, here (a background thread). outputOk = finite
   * output, level within bounds and (standard) parity with the reference loop.
   */
  fun benchmark(ctx: Context, m: Model): Map<String, Any?> {
    val t0 = System.nanoTime()
    val e = create(ctx, m) ?: return mapOf("ok" to false, "reason" to (loadError ?: "load_failed"), "model" to m.id)
    try {
      val clip = wavPcm16(libBytes(ctx, BENCH_CLIP))
      val ref = if (m === STD) pcm16(libBytes(ctx, BENCH_REF_STD)) else null
      val out = IntArray(6)
      val rc = nativeBenchmark(e.ptr, clip, ref, 20, 200, out)
      if (rc != 0) return mapOf("ok" to false, "reason" to "bench_rc_$rc", "model" to m.id)
      val inDb = out[3] / 100.0
      val outDb = out[4] / 100.0
      val snr = if (out[5] == -99900) null else out[5] / 100.0
      // Quiet-mic check (device run 2026-10-21: DFN3 erased a quiet iPhone mic): the clip at
      // -45 dBFS speech, through the core's pre-gain, must keep its speech (out >= in - 6 dB).
      val quiet = quietClip(clip)
      val q = IntArray(6)
      val qrc = nativeBenchmark(e.ptr, quiet, null, 0, clip.size / 480, q)
      val quietInDb = q[3] / 100.0
      val quietOutDb = q[4] / 100.0
      val quietOk = qrc == 0 && quietOutDb >= quietInDb - 6.0
      // a corrupt / wrong-scale model: silent, exploding, (std) far from the reference, or erasing quiet speech
      val outputOk = outDb > inDb - 30.0 && outDb < inDb + 6.0 && (snr == null || snr >= 25.0) && quietOk
      return mapOf(
        "ok" to true, "model" to m.id, "sha256" to m.sha256, "runtime" to RUNTIME,
        "p50Us" to out[0], "p95Us" to out[1], "maxUs" to out[2],
        "inDb" to inDb, "outDb" to outDb, "paritySnrDb" to snr, "outputOk" to outputOk,
        "quietInDb" to quietInDb, "quietOutDb" to quietOutDb,
        "ms" to (System.nanoTime() - t0) / 1_000_000,
      )
    } finally {
      destroy(e)
    }
  }

  /** [clip] scaled to -45 dBFS RMS, then lifted by the core's pre-gain for that level. */
  internal fun quietClip(clip: ShortArray): ShortArray {
    var acc = 0.0
    for (v in clip) acc += v.toDouble() * v
    val rmsDb = 10.0 * Math.log10(acc / maxOf(1, clip.size) / (32768.0 * 32768.0) + 1e-20)
    val gainDb = (QUIET_DBFS - rmsDb) + GxNsNative.nativePregainForLevel(QUIET_DBFS.toFloat())
    val g = Math.pow(10.0, gainDb / 20.0)
    return ShortArray(clip.size) { i -> (clip[i] * g).coerceIn(-32768.0, 32767.0).toInt().toShort() }
  }

  private const val QUIET_DBFS = -45.0

  private fun pcm16(b: ByteArray): ShortArray {
    val s = ShortArray(b.size / 2)
    ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(s)
    return s
  }

  /** The "data" chunk of a 16-bit PCM WAV. */
  private fun wavPcm16(b: ByteArray): ShortArray {
    var i = 12
    val bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
    while (i + 8 <= b.size) {
      val id = String(b, i, 4, Charsets.US_ASCII)
      val len = bb.getInt(i + 4)
      if (id == "data") return pcm16(b.copyOfRange(i + 8, minOf(b.size, i + 8 + len)))
      i += 8 + len + (len and 1)
    }
    return ShortArray(0)
  }

  @JvmStatic private external fun nativeCreate(model: ByteBuffer, latency: Int): Long
  @JvmStatic private external fun nativeDestroy(h: Long)
  @JvmStatic private external fun nativeBenchmark(h: Long, clip: ShortArray, ref: ShortArray?, warm: Int, frames: Int, out: IntArray): Int
}

/**
 * The low-latency DFN3 pack (plan Phase 3 delivery): Play asset pack on Play
 * installs, our CDN otherwise (a Play app never downloads code; this is a model
 * file, still Play-only by the owner's spec). SHA-256 verified before use;
 * cached in the app's files dir.
 */
internal object GxNsPack {
  private const val TAG = "GravixNS"
  const val PLAY_PACK = "gravix_ns_ll"
  private const val DIR = "gravix_ns"

  @Volatile private var verified: File? = null
  @Volatile private var fetching = false

  /** The verified LL model file, or null. Cheap after the first verification. */
  fun llFile(ctx: Context): File? {
    verified?.let { if (it.length() == GxNsStudio.LL.bytes) return it }
    val cached = File(File(ctx.filesDir, DIR), "${GxNsStudio.LL.sha256}.ort")
    if (cached.length() == GxNsStudio.LL.bytes) {
      verified = cached // verified when it was written (atomic rename after the SHA check)
      return cached
    }
    val play = playPackFile(ctx)
    if (play != null && play.length() == GxNsStudio.LL.bytes && sha256(play) == GxNsStudio.LL.sha256) {
      verified = play
      return play
    }
    return null
  }

  /** The installer is Google Play. */
  fun isPlayInstall(ctx: Context): Boolean = try {
    val installer = if (Build.VERSION.SDK_INT >= 30) {
      ctx.packageManager.getInstallSourceInfo(ctx.packageName).installingPackageName
    } else {
      @Suppress("DEPRECATION")
      ctx.packageManager.getInstallerPackageName(ctx.packageName)
    }
    installer == "com.android.vending"
  } catch (_: Throwable) {
    false
  }

  /**
   * Fetches the pack if allowed (background thread; never blocks a join).
   * [source]: auto | playAssetPack | cdn | app; [download]: never | unmeteredIdle | any;
   * [baseUrl]: the CDN folder holding dfn3_ll_int8.ort (null = no CDN).
   * Returns a reason string for the log.
   */
  fun ensure(ctx: Context, source: String, download: String, baseUrl: String?): String {
    if (llFile(ctx) != null) return "present"
    if (download == "never") return "download_never"
    if (fetching) return "in_progress"
    val play = isPlayInstall(ctx)
    val useCdn = when (source) {
      "cdn" -> !play
      "auto" -> !play
      else -> false
    }
    val usePlay = source == "playAssetPack" || (source == "auto" && play)
    if (download == "unmeteredIdle" && metered(ctx)) return "metered"
    fetching = true
    try {
      if (usePlay) return requestPlayPack(ctx)
      if (useCdn) {
        if (baseUrl.isNullOrEmpty()) return "no_cdn_url"
        return downloadCdn(ctx, baseUrl.trimEnd('/') + "/" + GxNsStudio.LL.file)
      }
      return if (play) "play_install_no_cdn" else "source_$source"
    } finally {
      fetching = false
    }
  }

  private fun metered(ctx: Context): Boolean = try {
    (ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered
  } catch (_: Throwable) {
    true
  }

  private fun downloadCdn(ctx: Context, url: String): String {
    val dir = File(ctx.filesDir, DIR).apply { mkdirs() }
    val part = File(dir, "${GxNsStudio.LL.sha256}.part")
    val dst = File(dir, "${GxNsStudio.LL.sha256}.ort")
    val t0 = System.nanoTime()
    if (!gxNsPackUrlOk(url)) return "insecure_url"
    var c: HttpURLConnection? = null
    return try {
      c = URL(url).openConnection() as HttpURLConnection
      c.connectTimeout = 10_000
      c.readTimeout = 20_000
      c.instanceFollowRedirects = true
      if (c.responseCode != 200) return "http_${c.responseCode}"
      if (!gxNsPackUrlOk(c.url.toString())) return "insecure_redirect"
      val n = c.inputStream.use { inp -> part.outputStream().use { gxNsCopyBounded(inp, it, GxNsStudio.LL.bytes) } }
      if (n < 0) {
        part.delete()
        return "too_large"
      }
      val sha = sha256(part)
      if (part.length() != GxNsStudio.LL.bytes || sha != GxNsStudio.LL.sha256) {
        part.delete()
        return "sha_mismatch"
      }
      if (!part.renameTo(dst)) return "rename_failed"
      verified = dst
      Log.i(TAG, "[GravixNS] pack src=cdn sha=ok bytes=${dst.length()} ms=${(System.nanoTime() - t0) / 1_000_000}")
      "downloaded"
    } catch (t: Throwable) {
      part.delete()
      "download_failed: ${t.javaClass.simpleName}"
    } finally {
      c?.disconnect()
    }
  }

  // Play Asset Delivery by reflection (the app adds the pack + the
  // com.google.android.play:asset-delivery dependency; the plugin cannot).
  private fun playManager(ctx: Context): Any? = try {
    Class.forName("com.google.android.play.core.assetpacks.AssetPackManagerFactory")
      .getMethod("getInstance", Context::class.java).invoke(null, ctx)
  } catch (_: Throwable) {
    null
  }

  private fun playPackFile(ctx: Context): File? = try {
    val m = playManager(ctx) ?: return null
    val loc = m.javaClass.getMethod("getPackLocation", String::class.java).invoke(m, PLAY_PACK) ?: return null
    val path = loc.javaClass.getMethod("assetsPath").invoke(loc) as? String ?: return null
    File(path, GxNsStudio.LL.file).takeIf { it.exists() }
  } catch (_: Throwable) {
    null
  }

  private fun requestPlayPack(ctx: Context): String = try {
    val m = playManager(ctx) ?: return "play_no_asset_delivery"
    m.javaClass.getMethod("fetch", List::class.java).invoke(m, listOf(PLAY_PACK))
    "play_fetch_requested"
  } catch (t: Throwable) {
    "play_fetch_failed: ${t.javaClass.simpleName}"
  }

  fun sha256(f: File): String {
    val md = MessageDigest.getInstance("SHA-256")
    FileInputStream(f).use { inp ->
      val buf = ByteArray(64 * 1024)
      while (true) {
        val n = inp.read(buf)
        if (n <= 0) break
        md.update(buf, 0, n)
      }
    }
    return md.digest().joinToString("") { "%02x".format(it) }
  }
}

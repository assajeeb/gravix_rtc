package com.gravitycompile.gravix_cloud.music

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.gravitycompile.gravix_cloud.GravixFastConnectChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.webrtc.audio.JavaAudioDeviceModule
import java.lang.reflect.Field
import java.util.concurrent.Executors

/**
 * Channel: `com.gravitycompile.gravix_rtc/music` (gravix_rtc 0.4.10+).
 *
 * gravix_rtc <= 0.4.9 registered `gravity.music_mixer`, the channel name of the
 * apps' own audio kits. Plugins register alphabetically and the last
 * setMethodCallHandler wins, so gravix_rtc silently took every call of an app's
 * kit (field 2026-10-05: room music fell back to the server bot in two apps).
 * The SDK never registers that name again.
 *
 * Reflection chain:
 *   FlutterWebRTCPlugin
 *     -> private field methodCallHandler   (MethodCallHandlerImpl)
 *     -> private field audioDeviceModule   (JavaAudioDeviceModule)
 *     -> field audioInput                  (org.webrtc.audio.WebRtcAudioRecord)
 *     -> private final field audioBufferCallback  <- MusicMixerEngine
 * flutter_webrtc never sets that callback itself. If something else holds it
 * (an app's own mixer installed first), it is CHAINED (called first), not
 * refused. The install is re-checked on every start: a re-created audio
 * device module gets the callback again.
 *
 * Methods (Dart -> native):
 *   install                                   -> Bool
 *   start {source, contentUri, loop, monitor, musicVolume, micVolume,
 *          ducking, duckLevel, holdOnMute, pauseOnInterruption}
 *                                             -> {durationMs}
 *          errors: NOT_INSTALLED, CAPTURE_NOT_READY, OPEN_FAILED
 *   pause / resume / stop                     -> null
 *   seek {positionMs}  (alias seekTo)         -> null
 *   setMusicVolume {volume} (alias setVolume {gain}) -> null
 *   setMicVolume {volume} / setDucking {on, level} / setLoop {on}
 *   configure {holdOnMute, pauseOnInterruption}
 *   isActive                                  -> Bool
 *   getState -> {active, paused, interrupted, positionMs, durationMs,
 *                captureReady, captureLive, captureSampleRate, captureChannels,
 *                installed}
 * Native -> Dart: onCompleted, onError {code, message},
 *   onInterruption {active, reason, resumed}
 *
 * Control calls run on one worker thread (start opens the file and the codec;
 * stop waits for the <= 60 ms fade), results are posted to the main thread.
 */
class MusicMixerPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "GxMusicPlugin"
        const val CHANNEL = "com.gravitycompile.gravix_rtc/music"
        // Apps that build their own engine may set it from configureFlutterEngine().
        @JvmStatic var flutterEngine: FlutterEngine? = null

        /**
         * Set by the first `install` call (GravixRoomMusic attach,
         * GravixRoomService connect): from then on every microphone capture
         * start installs the hook BEFORE WebRTC spawns its record thread
         * (GravixClientPlugin.handleStartLocalRecording), so the hook never
         * depends on a running thread seeing a write to a final field.
         */
        @Volatile @JvmStatic var autoInstall = false

        /** Installs on [adm]'s recorder when [autoInstall]; never throws. */
        @JvmStatic
        fun installIfWanted(adm: JavaAudioDeviceModule?) {
            if (!autoInstall || adm == null) return
            try { installOn(adm.audioInput) } catch (e: Throwable) { Log.w(TAG, "early install failed: $e") }
        }

        @JvmStatic
        @Synchronized
        fun installOn(input: Any?): Boolean {
            if (input == null) return false
            val f = input.javaClass.getDeclaredField("audioBufferCallback").apply { isAccessible = true }
            val existing = f.get(input)
            if (existing === MusicMixerEngine) return true
            if (existing is JavaAudioDeviceModule.AudioBufferCallback) {
                Log.w(TAG, "audioBufferCallback held by ${existing.javaClass.name}: chaining it")
                MusicMixerEngine.downstream = existing
            } else {
                MusicMixerEngine.downstream = null
            }
            f.set(input, MusicMixerEngine)
            Log.i(TAG, "mixer callback installed on ${input.javaClass.name}")
            return true
        }
    }

    private var channel: MethodChannel? = null
    // This is the package's one registered Android plugin class, so it also owns
    // the lifetime of the fast-connect channel (join-timeline logging et al.).
    private var fastConnect: GravixFastConnectChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "GxMusicControl") }
    private var bindingEngine: FlutterEngine? = null
    /** The instance on the Activity's (UI) engine owns the shared native mixer. */
    private var owner = false

    private val listener = object : MusicMixerEngine.Listener {
        override fun onCompleted() = emit("onCompleted", null)
        override fun onError(code: String, message: String) =
            emit("onError", mapOf("code" to code, "message" to message))
        override fun onInterruption(active: Boolean, reason: String, resumed: Boolean) =
            emit("onInterruption", mapOf("active" to active, "reason" to reason, "resumed" to resumed))
    }

    private fun emit(method: String, args: Any?) {
        mainHandler.post { channel?.invokeMethod(method, args) }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        @Suppress("DEPRECATION")
        bindingEngine = binding.flutterEngine
        MusicMixerEngine.appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
        fastConnect = GravixFastConnectChannel(binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (owner) {
            // the UI engine is going away: no music without its room
            worker.execute {
                MusicMixerEngine.stop()
                MusicMixerEngine.captureMuted = false
            }
            MusicMixerEngine.listener = null
            owner = false
        }
        worker.shutdown()
        channel?.setMethodCallHandler(null)
        channel = null
        fastConnect?.dispose()
        fastConnect = null
        bindingEngine = null
    }

    // Auto-registration attaches this plugin to EVERY engine, including headless
    // background ones (FCM, foreground task) that have no room. Only the engine
    // attached to the Activity owns the shared native mixer.
    private fun claimOwnership(binding: ActivityPluginBinding) {
        owner = true
        MusicMixerEngine.listener = listener
        flutterEngine = bindingEngine ?: flutterEngine ?: resolveEngine(binding.activity)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = claimOwnership(binding)
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = claimOwnership(binding)
    override fun onDetachedFromActivityForConfigChanges() = Unit
    override fun onDetachedFromActivity() = Unit

    /** FlutterActivity.getFlutterEngine() is protected; read it reflectively. */
    private fun resolveEngine(activity: android.app.Activity): FlutterEngine? {
        if (activity !is FlutterActivity) return null
        return try {
            val getter = FlutterActivity::class.java.getDeclaredMethod("getFlutterEngine")
            getter.isAccessible = true
            getter.invoke(activity) as? FlutterEngine
        } catch (e: Exception) {
            Log.w(TAG, "could not resolve FlutterEngine from activity", e)
            null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = Reply(result, mainHandler)
        try {
            worker.execute { handle(call, reply) }
        } catch (e: Exception) {
            reply.error("MIXER_ERROR", "music worker unavailable: ${e.message}")
        }
    }

    private fun handle(call: MethodCall, r: Reply) {
        val e = MusicMixerEngine
        try {
            when (call.method) {
                "install" -> r.success(installCallback())
                "configure" -> { applyConfig(call); r.success(null) }
                "start" -> {
                    val source = call.argument<String>("source") ?: call.argument<String>("path")
                    if (source.isNullOrEmpty()) { r.error("OPEN_FAILED", "no source"); return }
                    if (!installCallback()) {
                        r.error("NOT_INSTALLED", "the capture hook could not be installed (is a room connected?)")
                        return
                    }
                    applyConfig(call)
                    e.kernel.musicGain = num(call, "musicVolume") ?: num(call, "gain") ?: 1f
                    e.kernel.micGain = num(call, "micVolume") ?: 1f
                    call.argument<Boolean>("ducking")?.let { e.kernel.ducking = it }
                    num(call, "duckLevel")?.let { e.kernel.duckLevel = it }
                    val dur = e.start(
                        source,
                        call.argument<Boolean>("contentUri") ?: source.startsWith("content://"),
                        call.argument<Boolean>("loop") ?: false,
                        call.argument<Boolean>("monitor") ?: true,
                    )
                    // legacy callers (GravixMusicController) expect a Bool
                    r.success(if (call.argument<String>("source") == null) true else mapOf("durationMs" to dur))
                }
                "pause" -> { e.pause(); r.success(null) }
                "resume" -> { e.resume(); r.success(null) }
                "stop" -> { e.stop(); r.success(null) }
                "seek", "seekTo" -> {
                    e.seekTo((call.argument<Number>("positionMs") ?: 0).toLong()); r.success(null)
                }
                "setMusicVolume", "setVolume" -> {
                    e.kernel.musicGain = num(call, "volume") ?: num(call, "gain") ?: 1f; r.success(null)
                }
                "setMicVolume" -> { e.kernel.micGain = num(call, "volume") ?: 1f; r.success(null) }
                "setDucking" -> {
                    e.kernel.ducking = call.argument<Boolean>("on") ?: false
                    num(call, "level")?.let { e.kernel.duckLevel = it }
                    r.success(null)
                }
                "setLoop" -> { e.setLoop(call.argument<Boolean>("on") ?: false); r.success(null) }
                "isActive" -> r.success(e.isActive())
                "getState" -> r.success(mapOf(
                    "active" to e.isActive(),
                    "paused" to e.isPaused(),
                    "interrupted" to e.interruptedReason(),
                    "positionMs" to e.positionMs(),
                    "durationMs" to e.durationMs(),
                    "captureReady" to e.captureSeen,
                    "captureLive" to e.captureLive(),
                    "captureSampleRate" to e.captureSampleRate,
                    "captureChannels" to e.captureChannels,
                    "installed" to isInstalled(),
                ))
                else -> r.notImplemented()
            }
        } catch (ex: MusicMixerEngine.StartException) {
            r.error(ex.code, ex.message ?: ex.code)
        } catch (ex: Exception) {
            Log.e(TAG, "${call.method} failed", ex)
            r.error("MIXER_ERROR", ex.message ?: ex.javaClass.simpleName)
        }
    }

    private fun applyConfig(call: MethodCall) {
        call.argument<Boolean>("holdOnMute")?.let { MusicMixerEngine.holdOnMute = it }
        call.argument<Boolean>("pauseOnInterruption")?.let { MusicMixerEngine.pauseOnInterruption = it }
    }

    private fun num(call: MethodCall, key: String): Float? = call.argument<Number>(key)?.toFloat()

    // ---- reflection install ----

    private fun audioInput(): Any? {
        // flutter_webrtc's own singleton first (works for any engine), then the
        // engine's plugin registry
        FlutterWebRTCPlugin.sharedSingleton?.audioDeviceModule?.let { return it.audioInput }
        val engine = flutterEngine ?: bindingEngine
            ?: return null.also { Log.e(TAG, "flutterEngine not set") }
        val webrtcPlugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin
            ?: return null.also { Log.e(TAG, "FlutterWebRTCPlugin not found") }
        val handler = getField(webrtcPlugin, "methodCallHandler")
            ?: return null.also { Log.e(TAG, "methodCallHandler not found") }
        val adm = getField(handler, "audioDeviceModule") as? JavaAudioDeviceModule
            ?: return null.also { Log.w(TAG, "audioDeviceModule null (no room yet)") }
        return getField(adm, "audioInput")
            ?: null.also { Log.e(TAG, "audioInput not found") }
    }

    private fun isInstalled(): Boolean = try {
        val input = audioInput()
        input != null && callbackField(input).get(input) === MusicMixerEngine
    } catch (_: Exception) { false }

    private fun installCallback(): Boolean {
        autoInstall = true
        return try {
            installOn(audioInput())
        } catch (e: Exception) {
            Log.e(TAG, "install failed", e)
            false
        }
    }

    private fun callbackField(input: Any): Field =
        input.javaClass.getDeclaredField("audioBufferCallback").apply { isAccessible = true }

    private fun getField(target: Any, name: String): Any? {
        var cls: Class<*>? = target.javaClass
        while (cls != null) {
            try {
                val f: Field = cls.getDeclaredField(name)
                f.isAccessible = true
                return f.get(target)
            } catch (_: NoSuchFieldException) {
                cls = cls.superclass
            }
        }
        return null
    }

    /** Posts a MethodChannel.Result back to the main thread exactly once. */
    private class Reply(private val result: MethodChannel.Result, private val main: Handler) {
        private var done = false
        fun success(v: Any?) = post { result.success(v) }
        fun error(code: String, msg: String) = post { result.error(code, msg, null) }
        fun notImplemented() = post { result.notImplemented() }
        private fun post(block: () -> Unit) {
            synchronized(this) { if (done) return; done = true }
            main.post(block)
        }
    }
}

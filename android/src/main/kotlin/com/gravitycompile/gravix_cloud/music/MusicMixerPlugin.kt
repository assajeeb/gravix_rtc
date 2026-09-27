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

/**
 * Channel: 'gravity.music_mixer'
 *
 * Reflection chain (same style as BeautyFilterPlugin's track attach):
 *   FlutterWebRTCPlugin
 *     -> private field methodCallHandler   (MethodCallHandlerImpl)
 *     -> private field audioDeviceModule   (JavaAudioDeviceModule)
 *     -> public final field audioInput     (org.webrtc.audio.WebRtcAudioRecord)
 *     -> private final field audioBufferCallback  <- set MusicMixerEngine
 *
 * All verified against flutter_webrtc 1.6.0 (FlutterWebRTCPlugin.java:44,
 * MethodCallHandlerImpl.java:131) + io.github.webrtc-sdk:android
 * 144.7559.09 (JavaAudioDeviceModule#audioInput, WebRtcAudioRecord
 * #audioBufferCallback). flutter_webrtc never sets this callback itself, so
 * the field is null until we claim it.
 *
 * IMPORTANT: install() should run BEFORE the mic starts recording (right
 * after Room.connect, before setMicrophoneEnabled(true)). The field is
 * `final`, and while the capture loop re-reads it every 10ms frame, ART is
 * free to hoist final-field loads — installing before the capture thread
 * spawns removes any doubt. The Dart wrapper cycles the mic if needed.
 *
 * Engine resolution: the plugin auto-discovers the FlutterEngine from the
 * attached FlutterActivity (standard embedding). Apps that override
 * configureFlutterEngine() may instead set MusicMixerPlugin.flutterEngine
 * explicitly, like BeautyFilterPlugin.
 *
 * Methods:
 *   install                     -> Bool
 *   start {path,gain,monitor}   -> Bool
 *   pause / resume / stop       -> null
 *   setVolume {gain}            -> null
 *   seekTo {positionMs}         -> null
 *   isActive                    -> Bool
 *   getState                    -> {active,paused,positionMs,durationMs}
 *   onCompleted (native->dart)  when a track finishes on its own
 */
class MusicMixerPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "MusicMixerPlugin"
        // Set from MainActivity.configureFlutterEngine, like BeautyFilterPlugin
        @JvmStatic var flutterEngine: FlutterEngine? = null
    }

    private var channel: MethodChannel? = null
    // This is the package's one registered Android plugin class, so it also owns
    // the lifetime of the fast-connect channel (join-timeline logging et al.).
    private var fastConnect: GravixFastConnectChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var installed = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "gravity.music_mixer")
        channel?.setMethodCallHandler(this)
        fastConnect = GravixFastConnectChannel(binding.binaryMessenger)
        MusicMixerEngine.onCompleted = {
            mainHandler.post { channel?.invokeMethod("onCompleted", null) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        MusicMixerEngine.stop()
        MusicMixerEngine.onCompleted = null
        channel?.setMethodCallHandler(null)
        channel = null
        fastConnect?.dispose()
        fastConnect = null
    }

    // ---- ActivityAware: discover the engine so the reflection install can
    //      reach the FlutterWebRTCPlugin instance without app changes ----
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        if (flutterEngine == null) {
            flutterEngine = resolveEngine(binding.activity)
        }
    }

    override fun onDetachedFromActivity() = Unit

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() = Unit

    /**
     * FlutterActivity.getFlutterEngine() is protected; read it via reflection
     * (same style as the track/audio installs) so standard FlutterActivity apps
     * work without touching MainActivity.
     */
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
        try {
            when (call.method) {
                "install" -> result.success(installCallback())
                "start" -> {
                    val path = call.argument<String>("path")!!
                    val gain = (call.argument<Number>("gain") ?: 1.0).toFloat()
                    val monitor = call.argument<Boolean>("monitor") ?: true
                    if (!installed && !installCallback()) {
                        result.error("NOT_INSTALLED",
                            "mixer callback could not be installed", null)
                        return
                    }
                    result.success(MusicMixerEngine.start(path, gain, monitor))
                }
                "pause" -> { MusicMixerEngine.pause(); result.success(null) }
                "resume" -> { MusicMixerEngine.resume(); result.success(null) }
                "stop" -> { MusicMixerEngine.stop(); result.success(null) }
                "setVolume" -> {
                    MusicMixerEngine.setGain(
                        (call.argument<Number>("gain") ?: 1.0).toFloat())
                    result.success(null)
                }
                "seekTo" -> {
                    val ms = (call.argument<Number>("positionMs") ?: 0).toLong()
                    MusicMixerEngine.seekTo(ms)
                    result.success(null)
                }
                "isActive" -> result.success(MusicMixerEngine.isActive())
                "getState" -> result.success(mapOf(
                    "active" to MusicMixerEngine.isActive(),
                    "paused" to MusicMixerEngine.isPaused(),
                    "positionMs" to MusicMixerEngine.positionMs(),
                    "durationMs" to MusicMixerEngine.durationMs(),
                ))
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "${call.method} failed", e)
            result.error("MIXER_ERROR", e.message, null)
        }
    }

    // ---- reflection install ----

    @Synchronized
    private fun installCallback(): Boolean {
        if (installed) return true
        try {
            val engine = flutterEngine
                ?: return false.also { Log.e(TAG, "flutterEngine not set") }
            val webrtcPlugin = engine.plugins.get(FlutterWebRTCPlugin::class.java)
                    as? FlutterWebRTCPlugin
                ?: return false.also { Log.e(TAG, "FlutterWebRTCPlugin not found") }

            val handler = getField(webrtcPlugin, "methodCallHandler")
                ?: return false.also { Log.e(TAG, "methodCallHandler not found") }
            val adm = getField(handler, "audioDeviceModule") as? JavaAudioDeviceModule
                ?: return false.also {
                    Log.e(TAG, "audioDeviceModule null — join a room first")
                }
            val audioInput = getField(adm, "audioInput")
                ?: return false.also { Log.e(TAG, "audioInput not found") }

            val f = audioInput.javaClass.getDeclaredField("audioBufferCallback")
            f.isAccessible = true
            val existing = f.get(audioInput)
            if (existing != null && existing !== MusicMixerEngine) {
                Log.w(TAG, "audioBufferCallback already occupied by $existing")
                return false
            }
            f.set(audioInput, MusicMixerEngine)
            installed = true
            Log.i(TAG, "mixer callback installed on ${audioInput.javaClass.name}")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "install failed", e)
            return false
        }
    }

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
}
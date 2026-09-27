package com.gravitycompile.gravix_cloud

import android.util.Log
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Channel: 'gravix.cloud/fast_connect'
 *
 * The small native side of the fast-connect work. It lives in its own class (the
 * package's registered plugin, MusicMixerPlugin, creates it) so that the music
 * mixer stays about music.
 *
 *   log {tag, line} -> null
 *       One logcat line under a FIXED tag. Dart's print() always lands under the
 *       tag `flutter`, mixed with everything else the engine says; the join
 *       timeline has to be greppable out of a production app's logcat by a
 *       script, in a RELEASE build,
 *       without parsing that. Log.i is not stripped from release builds.
 *       The caller decides what is in the line; nothing is added here.
 *
 *   startCallAudio -> Bool     (candidate "earlyCallAudio")
 *   stopCallAudio  -> null
 *       flutter_webrtc activates Android call audio (audio focus,
 *       MODE_IN_COMMUNICATION, output route: Twilio AudioSwitch.activate()) the
 *       moment the FIRST remote audio track is added - and it does so with
 *       postAtFrontOfQueue on the MAIN looper, which is Flutter's platform
 *       thread. Measured on a 2201117TG: ~190 ms during which no platform-channel
 *       reply and no event reaches Dart, in the middle of the subscriber
 *       negotiation the first audio is waiting for. The only other thing that
 *       triggers the activation is opening the microphone, which a listener must
 *       not do. startCallAudio calls the SAME public entry point,
 *       AudioSwitchManager.instance.start(), with no capture, so the app can pay
 *       for it at connect() start, in parallel with WebSocket + ICE + DTLS. When
 *       the audio track then arrives, flutter_webrtc's own start() finds the
 *       switch active and does nothing.
 *       No reflection: `instance` and `start()`/`stop()` are public, and this
 *       module already compiles against flutter_webrtc (compileOnly) for the
 *       music mixer. Returns false when flutter_webrtc has not attached yet.
 *       flutter_webrtc itself calls stop() when the last peer connection is
 *       disposed; stopCallAudio is for a join that failed before one existed.
 */
class GravixFastConnectChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "gravix.cloud/fast_connect").also {
        it.setMethodCallHandler(this)
    }

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "log" -> {
                Log.i(call.argument<String>("tag") ?: "GRAVIX", call.argument<String>("line") ?: "")
                result.success(null)
            }
            "startCallAudio" -> {
                val manager = AudioSwitchManager.instance
                if (manager == null) {
                    result.success(false)
                } else {
                    manager.start()
                    result.success(true)
                }
            }
            "stopCallAudio" -> {
                AudioSwitchManager.instance?.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

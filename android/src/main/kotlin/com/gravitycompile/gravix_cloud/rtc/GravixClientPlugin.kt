/*
 * Copyright 2024 LiveKit, Inc.
 * Modifications Copyright 2024-2026 Gravity Compile
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.gravitycompile.gravix_cloud.rtc

import com.gravitycompile.gravix_cloud.music.MusicMixerEngine
import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack
import io.flutter.plugin.common.BinaryMessenger
import org.webrtc.AudioTrack
import org.webrtc.audio.AudioProcessingComponentOptions
import org.webrtc.audio.AudioProcessingComponentState
import org.webrtc.audio.AudioProcessingImplementation
import org.webrtc.audio.AudioProcessingMode
import org.webrtc.audio.AudioProcessingOptions
import org.webrtc.audio.AudioProcessingOptionsResult
import org.webrtc.audio.AudioProcessingState
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** GravixClientPlugin */
class GravixClientPlugin : FlutterPlugin, MethodCallHandler {
  private var audioProcessors = mutableMapOf<String, AudioProcessors>()
  // Read on every use, and from OUR engine: flutter_webrtc sets the singleton in
  // its own constructor, so a headless engine started later (a foreground
  // task, an FCM handler) replaces it with an instance that has no local
  // tracks and no audio device module (field 2026-10-06, EnginePluginLookup).
  // Plugin registration order is not something this class relies on either.
  private val flutterWebRTCPlugin: FlutterWebRTCPlugin?
    get() = EnginePluginLookup.resolve(
      { flutterEngine?.plugins?.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin },
      { FlutterWebRTCPlugin.sharedSingleton },
    )
  private var flutterEngine: FlutterEngine? = null
  private var binaryMessenger: BinaryMessenger? = null
  private var applicationContext: Context? = null
  private var audioSwitchManager: GxAudioSwitchManager? = null
  private var audioDeviceModuleExecutor: ExecutorService? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  // True once an Activity attached to this plugin's engine; kept until the
  // engine detaches (onDetachedFromActivity runs before onDetachedFromEngine).
  // Only that engine may start or stop the call service: a headless engine
  // (foreground task, FCM handler) detaching must not end the user's call.
  @Volatile
  private var isMainEngine = false

  private val callServiceListener = object : GravixCallService.Listener {
    override fun onLeaveRequested() {
      mainHandler.post { invokeOnChannel("callServiceLeaveRequested") }
    }

    override fun onStopped() {
      mainHandler.post { invokeOnChannel("callServiceStopped") }
    }
  }

  private fun invokeOnChannel(method: String) {
    try {
      if (::channel.isInitialized) channel.invokeMethod(method, null)
    } catch (t: Throwable) {
      Log.w(TAG, "$method delivery failed", t)
    }
  }

  /** From GravixCloudPlugin's ActivityAware forwarding. */
  fun onAttachedToActivity() {
    isMainEngine = true
  }

  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel: MethodChannel

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    // Gravix owns the platform audio session, so disable flutter_webrtc's own
    // native audio management. Set at registration, before any audio op.
    AudioSwitchManager.setAudioSessionManagementEnabled(false)
    @Suppress("DEPRECATION")
    flutterEngine = flutterPluginBinding.flutterEngine
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "gravix_client")
    channel.setMethodCallHandler(this)
    binaryMessenger = flutterPluginBinding.binaryMessenger
    applicationContext = flutterPluginBinding.applicationContext
    audioSwitchManager = GxAudioSwitchManager(flutterPluginBinding.applicationContext)
    audioDeviceModuleExecutor?.shutdown()
    audioDeviceModuleExecutor = Executors.newSingleThreadExecutor()
  }

  @SuppressLint("SuspiciousIndentation")
  private fun handleStartVisualizer(@NonNull call: MethodCall, @NonNull result: Result) {
    val trackId = call.argument<String>("trackId")
    val visualizerId = call.argument<String>("visualizerId")
    if (trackId == null || visualizerId == null) {
      result.error("INVALID_ARGUMENT", "trackId and visualizerId is required", null)
      return
    }

    val barCount = call.argument<Int>("barCount") ?: 7
    val isCentered = call.argument<Boolean>("isCentered") ?: true
    var smoothTransition = call.argument<Boolean>("smoothTransition") ?: true

    val processors = getAudioProcessors(trackId)
    if (processors == null) {
      result.error("INVALID_ARGUMENT", "track not found", null)
      return
    }

    // Check if visualizer already exists
    if (processors.visualizers[visualizerId] != null) {
      result.success(null)
      return
    }

    val visualizer = Visualizer(
      barCount = barCount,
      isCentered = isCentered,
      smoothTransition = smoothTransition,
      audioTrack = processors.track,
      binaryMessenger = binaryMessenger!!,
      visualizerId = visualizerId
    )

    processors.visualizers[visualizerId] = visualizer
    result.success(null)
  }

  private fun handleStopVisualizer(@NonNull call: MethodCall, @NonNull result: Result) {
    val trackId = call.argument<String>("trackId")
    val visualizerId = call.argument<String>("visualizerId")
    if (trackId == null || visualizerId == null) {
      result.error("INVALID_ARGUMENT", "trackId and visualizerId is required", null)
      return
    }

    // Find and remove visualizer from all processors
    for (processors in audioProcessors.values) {
      processors.visualizers[visualizerId]?.let { visualizer ->
        visualizer.stop()
        processors.visualizers.remove(visualizerId)
      }
    }

    result.success(null)
  }

  /**
   * Get or create AudioProcessors for a given trackId
   */
  private fun getAudioProcessors(trackId: String): AudioProcessors? {
    // Return existing if found
    audioProcessors[trackId]?.let { return it }

    // Create new AudioProcessors for this track
    var audioTrack: GxAudioTrack? = null

    val localTrack = flutterWebRTCPlugin?.getLocalTrack(trackId)
    if (localTrack != null) {
      audioTrack = GxLocalAudioTrack(localTrack as LocalAudioTrack)
    } else {
      val remoteTrack = flutterWebRTCPlugin?.getRemoteTrack(trackId)
      if (remoteTrack != null) {
        audioTrack = GxRemoteAudioTrack(remoteTrack as AudioTrack)
      }
    }

    return audioTrack?.let { track ->
      val processors = AudioProcessors(track)
      audioProcessors[trackId] = processors
      processors
    }
  }

  /**
   * Handle startAudioRenderer method call
   */
  private fun handleStartAudioRenderer(@NonNull call: MethodCall, @NonNull result: Result) {
    val trackId = call.argument<String>("trackId")
    val rendererId = call.argument<String>("rendererId")
    val formatMap = call.argument<Map<String, Any?>>("format")

    if (trackId == null) {
      result.error("INVALID_ARGUMENT", "trackId is required", null)
      return
    }

    if (rendererId == null) {
      result.error("INVALID_ARGUMENT", "rendererId is required", null)
      return
    }

    if (formatMap == null) {
      result.error("INVALID_ARGUMENT", "format is required", null)
      return
    }

    val format = RendererAudioFormat.fromMap(formatMap)
    if (format == null) {
      result.error("INVALID_ARGUMENT", "Failed to parse format", null)
      return
    }

    val processors = getAudioProcessors(trackId)
    if (processors == null) {
      result.error("INVALID_ARGUMENT", "No such track", null)
      return
    }

    // Check if renderer already exists
    if (processors.renderers[rendererId] != null) {
      result.success(true)
      return
    }

    try {
      val renderer = AudioRenderer(
        processors.track,
        binaryMessenger!!,
        rendererId,
        format,
      )

      processors.renderers[rendererId] = renderer
      result.success(true)
    } catch (e: Exception) {
      result.error("RENDERER_ERROR", "Failed to create audio renderer: ${e.message}", null)
    }
  }

  /**
   * Handle stopAudioRenderer method call
   */
  private fun handleStopAudioRenderer(@NonNull call: MethodCall, @NonNull result: Result) {
    val rendererId = call.argument<String>("rendererId")

    if (rendererId == null) {
      result.error("INVALID_ARGUMENT", "rendererId is required", null)
      return
    }

    // Find and remove renderer from all processors
    for (processors in audioProcessors.values) {
      processors.renderers[rendererId]?.let { renderer ->
        renderer.detach()
        processors.renderers.remove(rendererId)
      }
    }

    result.success(true)
  }

  private fun handleSetAudioProcessingOptions(call: MethodCall, result: Result) {
    val trackId = call.argument<String>("trackId")
    if (trackId == null) {
      result.error("INVALID_ARGUMENT", "trackId is required", null)
      return
    }

    val mediaTrack = (flutterWebRTCPlugin?.getLocalTrack(trackId) as? LocalAudioTrack)?.track
    if (mediaTrack !is AudioTrack) {
      result.error("INVALID_ARGUMENT", "track is not a local audio track", null)
      return
    }

    val options = audioProcessingOptions(call)
    val processingResult = mediaTrack.setAudioProcessingOptions(options)
    result.success(
      mapOf(
        "result" to processingResult.isSuccess,
        "code" to audioProcessingResultCodeString(processingResult.code),
        "message" to processingResult.message,
      ),
    )
  }

  private fun handleStartLocalRecording(call: MethodCall, result: Result) {
    val audioDeviceModule = flutterWebRTCPlugin?.audioDeviceModule
    if (audioDeviceModule == null) {
      result.error("rejectedPlatformUnavailable", "audio device module is unavailable", null)
      return
    }

    // room music: the mixer hook goes in before the record thread starts
    com.gravitycompile.gravix_cloud.music.MusicMixerPlugin.installIfWanted(audioDeviceModule)
    val executor = audioDeviceModuleExecutorOrError(result, "rejectedPlatformUnavailable") ?: return
    val options = audioProcessingOptions(call)
    try {
      executor.execute {
        try {
          // prewarmRecording applies Android platform AP and prepares recording
          // without setting the client-start flag. WebRTC exposes this as void,
          // so only thrown failures can be surfaced here.
          audioDeviceModule.prewarmRecording(options)
          mainHandler.post {
            result.success(null)
          }
        } catch (error: Throwable) {
          // Pre-warming is best effort. prewarmRecording() applies the platform
          // audio processing options before it prepares the recorder, so the
          // options are in effect even when preparing fails, and WebRTC opens
          // the recorder again on the real start path and reports its own
          // init/start errors there. Surfacing this as applyFailed instead
          // aborts startCapture() and fails the publish outright on devices
          // that cannot open an AudioRecord yet (microphone held by another
          // app, vendor capture restrictions) — an audio processing failure
          // the requested options never caused.
          Log.w(TAG, "Failed to prewarm local recording, continuing without it", error)
          mainHandler.post {
            result.success(null)
          }
        }
      }
    } catch (error: RejectedExecutionException) {
      result.error("rejectedPlatformUnavailable", "audio device module executor is unavailable", null)
    }
  }

  // Microphone mute inside the audio device module, recorder left running
  // (field 2026-09-30): disabling the mic track makes the engine stop the
  // AudioRecord and re-create it on unmute, and re-opening a VOICE_COMMUNICATION
  // input under a live call re-routes the voice path on OEM HALs, interrupting
  // the playout of the other participants. WebRtcAudioRecord zeroes the buffer
  // right after AudioRecord.read(), before the mixer callback and the native
  // delivery. Room music (0.4.10): the mixer still mixes onto the zeroed voice
  // (a voice-only mute) unless MusicMixerEngine.holdOnMute, which holds it.
  // Returns true only when the module exists; Dart falls back to disabling the
  // track otherwise.
  private fun handleSetMicrophoneMute(call: MethodCall, result: Result) {
    val audioDeviceModule = flutterWebRTCPlugin?.audioDeviceModule
    if (audioDeviceModule == null) {
      result.success(false)
      return
    }
    val mute = call.argument<Boolean>("mute") ?: false
    try {
      // flag first on mute, last on unmute: no window where a held mixer runs
      if (mute) MusicMixerEngine.captureMuted = true
      audioDeviceModule.setMicrophoneMute(mute)
      if (!mute) MusicMixerEngine.captureMuted = false
      result.success(true)
    } catch (error: Throwable) {
      Log.w(TAG, "setMicrophoneMute($mute) failed", error)
      result.error("setMicrophoneMute", error.message, null)
    }
  }

  private fun handleStopLocalRecording(result: Result) {
    val audioDeviceModule = flutterWebRTCPlugin?.audioDeviceModule
    if (audioDeviceModule == null) {
      result.error("stopLocalRecording", "audio device module is unavailable", null)
      return
    }

    val executor = audioDeviceModuleExecutorOrError(result, "stopLocalRecording") ?: return
    try {
      executor.execute {
        try {
          audioDeviceModule.requestStopRecording()
          mainHandler.post {
            result.success(null)
          }
        } catch (error: Throwable) {
          mainHandler.post {
            result.error("stopLocalRecording", error.message, null)
          }
        }
      }
    } catch (error: RejectedExecutionException) {
      result.error("stopLocalRecording", "audio device module executor is unavailable", null)
    }
  }

  private fun audioDeviceModuleExecutorOrError(result: Result, code: String): ExecutorService? {
    val executor = audioDeviceModuleExecutor
    if (executor == null || executor.isShutdown) {
      result.error(code, "audio device module executor is unavailable", null)
      return null
    }
    return executor
  }

  private fun audioProcessingOptions(call: MethodCall): AudioProcessingOptions =
    AudioProcessingOptions(
      AudioProcessingComponentOptions(
        call.argument<Boolean>("echoCancellation") ?: true,
        audioProcessingMode(call.argument<String>("echoCancellationMode")),
      ),
      AudioProcessingComponentOptions(
        call.argument<Boolean>("noiseSuppression") ?: true,
        audioProcessingMode(call.argument<String>("noiseSuppressionMode")),
      ),
      AudioProcessingComponentOptions(
        call.argument<Boolean>("autoGainControl") ?: true,
        audioProcessingMode(call.argument<String>("autoGainControlMode")),
      ),
      AudioProcessingComponentOptions(
        call.argument<Boolean>("highPassFilter") ?: false,
        audioProcessingMode(call.argument<String>("highPassFilterMode")),
      ),
    )

  private fun audioProcessingMode(value: String?): AudioProcessingMode = when (value) {
    "platform" -> AudioProcessingMode.PLATFORM
    "software" -> AudioProcessingMode.SOFTWARE
    else -> AudioProcessingMode.AUTOMATIC
  }

  private fun audioProcessingResultCodeString(code: AudioProcessingOptionsResult.Code): String = when (code) {
    AudioProcessingOptionsResult.Code.APPLIED -> "applied"
    AudioProcessingOptionsResult.Code.STORED -> "stored"
    AudioProcessingOptionsResult.Code.REJECTED_REMOTE_TRACK -> "unknown"
    AudioProcessingOptionsResult.Code.REJECTED_INVALID_COMBINATION -> "rejectedInvalidCombination"
    AudioProcessingOptionsResult.Code.REJECTED_PLATFORM_UNAVAILABLE -> "rejectedPlatformUnavailable"
    AudioProcessingOptionsResult.Code.APPLY_FAILED -> "applyFailed"
  }

  private fun handleGetAudioProcessingState(result: Result) {
    val factory = flutterWebRTCPlugin?.getPeerConnectionFactory()
    if (factory == null) {
      result.success(null)
      return
    }
    result.success(audioProcessingStateToMap(factory.audioProcessingState))
  }

  private fun audioProcessingModeString(mode: AudioProcessingMode): String = when (mode) {
    AudioProcessingMode.PLATFORM -> "platform"
    AudioProcessingMode.SOFTWARE -> "software"
    AudioProcessingMode.AUTOMATIC -> "auto"
  }

  private fun audioProcessingImplementationString(implementation: AudioProcessingImplementation): String =
    when (implementation) {
      AudioProcessingImplementation.UNKNOWN -> "unknown"
      AudioProcessingImplementation.DISABLED -> "disabled"
      AudioProcessingImplementation.SOFTWARE -> "software"
      AudioProcessingImplementation.PLATFORM -> "platform"
      AudioProcessingImplementation.SOFTWARE_AND_PLATFORM -> "softwareAndPlatform"
    }

  private fun requestedToMap(requested: AudioProcessingComponentOptions?): Map<String, Any?>? =
    requested?.let {
      mapOf(
        "enabled" to it.isEnabled,
        "mode" to audioProcessingModeString(it.mode),
      )
    }

  private fun componentToMap(state: AudioProcessingComponentState): Map<String, Any?> = mapOf(
    "requested" to requestedToMap(state.requested),
    "isSoftwareResolved" to state.isSoftwareResolved,
    "isSoftwareActive" to state.isSoftwareActive,
    "isPlatformAvailable" to state.isPlatformAvailable,
    "isPlatformResolved" to state.isPlatformResolved,
    "isPlatformActive" to state.isPlatformActive,
    "effective" to audioProcessingImplementationString(state.effective),
  )

  private fun audioProcessingStateToMap(state: AudioProcessingState): Map<String, Any?> = mapOf(
    "hasAudioProcessingModule" to state.hasAudioProcessingModule,
    "echoCancellation" to componentToMap(state.echoCancellation),
    "noiseSuppression" to componentToMap(state.noiseSuppression),
    "autoGainControl" to componentToMap(state.autoGainControl),
    "highPassFilter" to componentToMap(state.highPassFilter),
  )

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "startVisualizer" -> {
        handleStartVisualizer(call, result)
      }

      "stopVisualizer" -> {
        handleStopVisualizer(call, result)
      }

      "startAudioRenderer" -> {
        handleStartAudioRenderer(call, result)
      }

      "stopAudioRenderer" -> {
        handleStopAudioRenderer(call, result)
      }

      "setAudioProcessingOptions" -> {
        handleSetAudioProcessingOptions(call, result)
      }

      "startLocalRecording" -> {
        handleStartLocalRecording(call, result)
      }

      "stopLocalRecording" -> {
        handleStopLocalRecording(result)
      }

      "setMicrophoneMute" -> {
        handleSetMicrophoneMute(call, result)
      }

      "getAudioProcessingState" -> {
        handleGetAudioProcessingState(result)
      }

      "configureAndroidAudioSession" -> {
        @Suppress("UNCHECKED_CAST")
        val configuration = call.arguments as? Map<String, Any?> ?: emptyMap()
        audioSwitchManager?.configure(configuration)
        audioSwitchManager?.start()
        result.success(null)
      }

      "stopAndroidAudioSession" -> {
        audioSwitchManager?.stop()
        result.success(null)
      }

      "setAndroidSpeakerphoneOn" -> {
        val enable = call.argument<Boolean>("enable") ?: false
        val force = call.argument<Boolean>("force") ?: false
        audioSwitchManager?.setSpeakerphoneOn(enable, force)
        result.success(null)
      }

      "osVersionString" -> {
        result.success(Build.VERSION.RELEASE)
      }

      // MediaProjection foreground service (see ScreenCaptureService). Must be
      // started AFTER flutter_webrtc's requestCapturePermission() and BEFORE
      // getDisplayMedia(): Android 14 rejects getMediaProjection() without a
      // running mediaProjection-typed foreground service, and rejects that
      // service type before the user has consented.
      "startScreenCaptureService" -> {
        val context = applicationContext
        if (context == null) {
          result.error("screenCaptureServiceFailed", "plugin is not attached", null)
          return
        }
        ScreenCaptureService.start(
          context,
          title = call.argument<String>("notificationTitle"),
          text = call.argument<String>("notificationText"),
        ) { error ->
          mainHandler.post {
            if (error == null) {
              result.success(true)
            } else {
              result.error("screenCaptureServiceFailed", error, null)
            }
          }
        }
      }

      // Call foreground service (GravixCallService): disabled by default, the
      // Dart side calls these only when the app enabled it.
      "startCallService" -> {
        val context = applicationContext
        if (context == null || !isMainEngine) {
          result.error("callServiceFailed", if (context == null) "plugin is not attached" else "not the activity engine", null)
          return
        }
        GravixCallService.listener = callServiceListener
        val config = GravixCallService.Config(
          title = call.argument<String>("notificationTitle"),
          text = call.argument<String>("notificationText"),
          showLeaveAction = call.argument<Boolean>("showLeaveAction") ?: false,
          leaveLabel = call.argument<String>("leaveActionLabel"),
          micWanted = call.argument<Boolean>("microphone") ?: false,
          cameraWanted = call.argument<Boolean>("camera") ?: false,
        )
        GravixCallService.start(context, config) { outcome ->
          mainHandler.post {
            if (outcome.error == null) {
              result.success(callServiceReply(outcome))
            } else {
              result.error("callServiceFailed", outcome.error, null)
            }
          }
        }
      }

      "updateCallService" -> {
        if (!isMainEngine) {
          result.error("callServiceFailed", "not the activity engine", null)
          return
        }
        val outcome = GravixCallService.update(call.argument<Boolean>("microphone"), call.argument<Boolean>("camera"))
        result.success(callServiceReply(outcome))
      }

      "stopCallService" -> {
        if (isMainEngine) applicationContext?.let { GravixCallService.stop(it) }
        result.success(null)
      }

      "stopScreenCaptureService" -> {
        applicationContext?.let { ScreenCaptureService.stop(it) }
        result.success(null)
      }

      // Apple-only methods (configureNativeAudio, setAppleAudioSession*,
      // deactivateAppleAudioSession, setAppleAudioOutput, setMicrophoneMuteMode,
      // getMicrophoneMuteMode, setEngineAvailability, broadcastRequest*) have no
      // Android equivalent. The Dart side gates them by platform; answering
      // notImplemented here is the honest reply if something calls them anyway.
      else -> {
        result.notImplemented()
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    flutterEngine = null

    audioSwitchManager?.dispose()
    audioSwitchManager = null

    audioDeviceModuleExecutor?.shutdown()
    audioDeviceModuleExecutor = null

    applicationContext?.let { ScreenCaptureService.stop(it) }
    if (isMainEngine) {
      // the UI engine is going away: the call it started ends with it
      applicationContext?.let { GravixCallService.stop(it) }
      if (GravixCallService.listener === callServiceListener) GravixCallService.listener = null
    }
    isMainEngine = false
    applicationContext = null

    // Cleanup all processors
    audioProcessors.values.forEach { it.cleanup() }
    audioProcessors.clear()
  }

  private fun callServiceReply(outcome: GravixCallService.Outcome): Map<String, Any?> = mapOf(
    "types" to outcome.types,
    "typeNames" to CallServiceTypes.names(outcome.types),
    "error" to outcome.error,
  )

  companion object {
    private const val TAG = "GravixClientPlugin"
  }
}

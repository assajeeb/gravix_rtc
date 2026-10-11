/*
 * Copyright 2026 LiveKit, Inc.
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

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import com.twilio.audioswitch.AbstractAudioSwitch
import com.twilio.audioswitch.AudioDevice
import com.twilio.audioswitch.AudioSwitch
import com.twilio.audioswitch.CommDeviceAudioSwitch
import com.twilio.audioswitch.LegacyAudioSwitch

/**
 * Manages the Android platform audio session (audio mode, audio focus, and
 * output routing) for the Gravix Flutter SDK, built on top of [AudioSwitch].
 *
 * This is the SDK's own port of the audio-handling best practices from the
 * upstream Android RTC SDK (`AudioSwitchHandler`) and flutter_webrtc
 * (`AudioSwitchManager`), so the Flutter SDK can own the platform audio session
 * directly instead of delegating to flutter_webrtc's native audio management.
 *
 * [AudioSwitch] is not thread-safe, so every interaction with it runs on a
 * single dedicated [HandlerThread].
 */
internal class GxAudioSwitchManager(private val context: Context) {
  // AudioSwitch is not threadsafe, so confine all access to a single long-lived
  // thread. The AudioSwitch instance is recreated per active session, while
  // queued lifecycle work stays serialized on this thread.
  private val thread = HandlerThread("GravixAudioSwitchThread").also { it.start() }
  private val handler = Handler(thread.looper)

  private var audioSwitch: AbstractAudioSwitch? = null
  private var isActive = false

  // Configuration. Defaults mirror a communication/VoIP session and match the
  // AudioSwitchHandler defaults in the upstream Android RTC SDK.
  private var manageAudioFocus = true
  private var audioMode = AudioManager.MODE_IN_COMMUNICATION
  private var focusMode = AudioManager.AUDIOFOCUS_GAIN
  private var audioStreamType = AudioManager.STREAM_VOICE_CALL
  private var audioAttributeUsageType = AudioAttributes.USAGE_VOICE_COMMUNICATION
  private var audioAttributeContentType = AudioAttributes.CONTENT_TYPE_SPEECH
  private var forceHandleAudioRouting = false

  private var speakerOutputPreferred = true
  private var speakerOutputForced = false

  // 0.4.15 (field report 2026-10-10, 7d): an explicit route from
  // GravixAudioDevice.setAudioRoute / setEnableSpeakerphone, as a route name
  // (AudioRoutePolicy). Null = the speaker preference above decides. Wins over
  // setSpeakerphoneOn until cleared, so the v2 routing ladder (which re-applies
  // the speaker preference) does not undo a user's choice.
  private var explicitRoute: String? = null

  // 0.4.15 (7b): the Bluetooth chatroom model. [audioMode] stays what the app
  // configured; the session runs in [effectiveAudioMode].
  private var chatroomEnabled = false
  private var chatroomMicActive = false
  private var bluetoothHeadsetAvailable = false
  @Volatile
  private var chatroomEngaged = false

  private val mainHandler = Handler(Looper.getMainLooper())
  private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

  /** Session audio-focus changes (any thread). The mic monitor listens. */
  @Volatile
  var onFocusChange: ((Int) -> Unit)? = null

  /** Route list/current changes, main thread. */
  @Volatile
  var onRoutesChanged: ((Map<String, Any?>) -> Unit)? = null

  /**
   * The chatroom model moved the microphone to the headset (true) or back
   * (false), main thread. The plugin points WebRTC's recorder at it.
   */
  @Volatile
  var onChatroomRoute: ((Boolean) -> Unit)? = null

  /**
   * Apply an audio session configuration. Unspecified keys keep their current
   * value. When the session is already active, changes that only take effect at
   * activate() time trigger a deactivate and activate cycle so they apply live.
   */
  @Synchronized
  fun configure(configuration: Map<String, Any?>) {
    val previous = sessionConfigSnapshot()
    (configuration["manageAudioFocus"] as? Boolean)?.let { manageAudioFocus = it }
    audioModeForName(configuration["androidAudioMode"] as? String)?.let { audioMode = it }
    focusModeForName(configuration["androidAudioFocusMode"] as? String)?.let { focusMode = it }
    streamTypeForName(configuration["androidAudioStreamType"] as? String)?.let { audioStreamType = it }
    usageTypeForName(configuration["androidAudioAttributesUsageType"] as? String)?.let { audioAttributeUsageType = it }
    contentTypeForName(configuration["androidAudioAttributesContentType"] as? String)?.let { audioAttributeContentType = it }
    (configuration["forceHandleAudioRouting"] as? Boolean)?.let { forceHandleAudioRouting = it }
    val sessionConfig = sessionConfigSnapshot()
    val sessionConfigChanged = sessionConfig != previous
    val speakerRouting = speakerRoutingSnapshot()

    handler.post {
      val switch = audioSwitch ?: return@post
      applyConfiguration(switch, sessionConfig)
      // AudioSwitch applies the audio mode, focus, and attributes at activate()
      // time, so a live reconfiguration (e.g. communication to media) needs a
      // deactivate and activate cycle to take effect on an already active
      // session. Reassert speaker routing afterward.
      if (isActive && sessionConfigChanged) {
        switch.deactivate()
        switch.activate()
        applySpeakerRouting(switch, speakerRouting)
        if (chatroomEngaged) selectBluetooth(switch)
      }
    }
  }

  // Snapshot of the AudioSwitch properties applied only at activate() time, used
  // to detect when a live session needs a deactivate and activate cycle to pick
  // up a configuration change.
  private fun sessionConfigSnapshot() = SessionConfig(
    manageAudioFocus = manageAudioFocus,
    audioMode = effectiveAudioMode(),
    focusMode = focusMode,
    audioStreamType = audioStreamType,
    audioAttributeUsageType = audioAttributeUsageType,
    audioAttributeContentType = audioAttributeContentType,
    forceHandleAudioRouting = forceHandleAudioRouting,
  )

  /** Create (if needed) and activate the audio session: acquire focus, set mode and routing. */
  @Synchronized
  fun start() {
    val sessionConfig = sessionConfigSnapshot()
    val speakerRouting = speakerRoutingSnapshot()
    handler.post {
      val switch = audioSwitch ?: createSwitch(sessionConfig, speakerRouting).also { audioSwitch = it }
      if (!isActive) {
        switch.activate()
        applySpeakerRouting(switch, speakerRouting)
        isActive = true
        // a headset connected before the session existed
        applyChatroom("session start")
        emitRoutes("sessionStart")
        registerOutputDeviceCallback()
      }
    }
  }

  /** Deactivate and tear down the audio session: release focus and restore the previous mode. */
  @Synchronized
  fun stop() {
    handler.post {
      unregisterOutputDeviceCallback()
      audioSwitch?.stop()
      audioSwitch = null
      isActive = false
      if (chatroomEngaged) {
        chatroomEngaged = false
        onChatroomRoute?.let { notify -> mainHandler.post { notify(false) } }
      }
    }
  }

  /** Final cleanup when the plugin detaches. The manager must not be used after this. */
  @Synchronized
  fun dispose() {
    handler.post {
      unregisterOutputDeviceCallback()
      audioSwitch?.stop()
      audioSwitch = null
      isActive = false
      thread.quitSafely()
    }
  }

  /**
   * Prefer routing to/from the speaker, letting a connected headset keep priority
   * unless [force] is true.
   */
  @Synchronized
  fun setSpeakerphoneOn(enable: Boolean, force: Boolean) {
    speakerOutputPreferred = enable
    speakerOutputForced = enable && force
    val speakerRouting = speakerRoutingSnapshot()
    handler.post {
      val switch = audioSwitch ?: return@post
      applySpeakerRouting(switch, speakerRouting)
      emitRoutes("speakerPreference")
    }
  }

  private fun createSwitch(
    sessionConfig: SessionConfig,
    speakerRouting: SpeakerRouting,
  ): AbstractAudioSwitch {
    // Room music pauses on a transient focus loss (and resumes on regain); the
    // mic monitor reports it (0.4.15: a VoIP call takes the focus first).
    val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
      com.gravitycompile.gravix_cloud.music.MusicMixerEngine.onAudioFocusChange(change)
      onFocusChange?.invoke(change)
    }
    // API-aware switch selection, matching the upstream Android RTC SDK's
    // AudioSwitchHandler: CommDeviceAudioSwitch uses the modern
    // AudioManager.setCommunicationDevice routing on API 31+.
    val switch = when {
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
        CommDeviceAudioSwitch(context, false, focusListener, speakerRouting.preferredDeviceList)

      Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
        AudioSwitch(context, false, focusListener, speakerRouting.preferredDeviceList)

      else ->
        LegacyAudioSwitch(context, false, focusListener, speakerRouting.preferredDeviceList)
    }
    applyConfiguration(switch, sessionConfig)
    // 0.4.15: the device list was discarded here; it drives the route-changed
    // event (7d) and the chatroom model's headset connect/disconnect (7b).
    // The device scanners deliver it on the MAIN looper; every switch call
    // stays on this manager's thread, so the work is posted there.
    switch.start { devices, _ ->
      val bt = devices.any { it is AudioDevice.BluetoothHeadset }
      handler.post { onDevicesChanged(bt) }
    }
    return switch
  }

  /** Handler thread. */
  private fun onDevicesChanged(bt: Boolean) {
    val changed = synchronized(this) {
      val was = bluetoothHeadsetAvailable
      bluetoothHeadsetAvailable = bt
      was != bt
    }
    if (changed) applyChatroom("bluetooth ${if (bt) "connected" else "disconnected"}")
    emitRoutes(if (changed) (if (bt) "deviceAdded" else "deviceRemoved") else "devicesChanged")
  }

  private fun applyConfiguration(switch: AbstractAudioSwitch, sessionConfig: SessionConfig) {
    switch.manageAudioFocus = sessionConfig.manageAudioFocus
    switch.audioMode = sessionConfig.audioMode
    switch.focusMode = sessionConfig.focusMode
    switch.audioStreamType = sessionConfig.audioStreamType
    switch.audioAttributeUsageType = sessionConfig.audioAttributeUsageType
    switch.audioAttributeContentType = sessionConfig.audioAttributeContentType
    switch.forceHandleAudioRouting = sessionConfig.forceHandleAudioRouting
  }

  private fun applySpeakerRouting(switch: AbstractAudioSwitch, speakerRouting: SpeakerRouting) {
    // AudioSwitch treats selectDevice(null) as "select no device"; it does not
    // recompute the best route from the preferred-device list. Keep routing
    // automatic here so normal preference and forced-speaker priority both
    // follow device hot-plug changes without leaving a sticky selected device.
    switch.setPreferredDeviceList(speakerRouting.preferredDeviceList)
  }

  private fun speakerRoutingSnapshot() = SpeakerRouting(
    preferredDeviceList = AudioRoutePolicy.explicitOrder(explicitRoute)?.map(::deviceClassOf)
      ?: preferredDeviceList(
        speakerOutputPreferred = speakerOutputPreferred,
        speakerOutputForced = speakerOutputForced,
      ),
  )

  private fun deviceClassOf(route: String): Class<out AudioDevice> = when (route) {
    AudioRoutePolicy.SPEAKER -> AudioDevice.Speakerphone::class.java
    AudioRoutePolicy.EARPIECE -> AudioDevice.Earpiece::class.java
    AudioRoutePolicy.BLUETOOTH -> AudioDevice.BluetoothHeadset::class.java
    else -> AudioDevice.WiredHeadset::class.java
  }

  private fun routeOf(device: AudioDevice?): String? = when (device) {
    is AudioDevice.Speakerphone -> AudioRoutePolicy.SPEAKER
    is AudioDevice.Earpiece -> AudioRoutePolicy.EARPIECE
    is AudioDevice.BluetoothHeadset -> AudioRoutePolicy.BLUETOOTH
    is AudioDevice.WiredHeadset -> AudioRoutePolicy.WIRED
    else -> null
  }

  /** The session's AudioAttributes usage (the keep-alive player plays as the room does). */
  @Synchronized
  fun audioUsage(): Int = audioAttributeUsageType

  @Synchronized
  private fun effectiveAudioMode(): Int =
    AudioRoutePolicy.chatroomMode(chatroomEnabled, chatroomMicActive, bluetoothHeadsetAvailable, audioMode)

  // ── 0.4.15 public operations ───────────────────────────────────────────────

  /**
   * After a phone/VoIP call (7c): the call reprogrammed the audio mode and the
   * route (telephony sets IN_CALL, then NORMAL), so put the session back:
   * deactivate + activate + routing, as a live reconfiguration does.
   */
  fun reassert() {
    val sessionConfig = sessionConfigSnapshot()
    val speakerRouting = speakerRoutingSnapshot()
    handler.post {
      val switch = audioSwitch ?: return@post
      if (!isActive) return@post
      Log.i(TAG, "re-asserting the audio session after an interruption")
      applyConfiguration(switch, sessionConfig)
      switch.deactivate()
      switch.activate()
      applySpeakerRouting(switch, speakerRouting)
      if (chatroomEngaged) selectBluetooth(switch)
      emitRoutes("reasserted")
    }
  }

  /** The Bluetooth chatroom model (7b), from Dart. */
  fun setChatroom(enabled: Boolean, micActive: Boolean) {
    synchronized(this) {
      chatroomEnabled = enabled
      chatroomMicActive = micActive
    }
    handler.post { applyChatroom("mic ${if (micActive) "on" else "off"}, chatroom ${if (enabled) "on" else "off"}") }
  }

  /** Handler thread. Moves the session in/out of communication mode when the decision changed. */
  private fun applyChatroom(why: String) {
    val switch = audioSwitch ?: return
    val mode = effectiveAudioMode()
    val engage = mode != audioMode
    if (engage == chatroomEngaged && switch.audioMode == mode) return
    Log.i(TAG, "chatroom: ${if (engage) "communication mode + Bluetooth microphone" else "back to the configured mode"} ($why)")
    chatroomEngaged = engage
    applyConfiguration(switch, sessionConfigSnapshot())
    if (isActive) {
      switch.deactivate()
      switch.activate()
    }
    if (engage) {
      // In MODE_NORMAL AudioSwitch never selected a device, so activate()
      // has nothing to route: name the headset (setCommunicationDevice on
      // API 31+, SCO before). The selection ends with the headset.
      selectBluetooth(switch)
    } else {
      // only clears the user selection: routing is off in MODE_NORMAL
      switch.selectDevice(null)
    }
    applySpeakerRouting(switch, speakerRoutingSnapshot())
    // SCO takes ~0.5-1.5 s to come up; point WebRTC's recorder at it after
    // that, and again later for slow headsets (the same late rung the v2
    // route manager uses).
    val notify = onChatroomRoute
    if (notify != null) {
      // a later flip (engage -> disengage within the settle time) must not be
      // overtaken by a stale "point at the headset"
      mainHandler.removeCallbacksAndMessages(CHATROOM_TOKEN)
      val tell = Runnable { if (chatroomEngaged == engage) notify(engage) }
      mainHandler.postAtTime(tell, CHATROOM_TOKEN, android.os.SystemClock.uptimeMillis() + SCO_SETTLE_MS)
      mainHandler.postAtTime(tell, CHATROOM_TOKEN, android.os.SystemClock.uptimeMillis() + SCO_SETTLE_MS * 2)
    }
    emitRoutes(if (engage) "chatroomBluetooth" else "chatroomMedia")
  }

  private fun selectBluetooth(switch: AbstractAudioSwitch) {
    switch.availableAudioDevices.firstOrNull { it is AudioDevice.BluetoothHeadset }?.let { switch.selectDevice(it) }
  }

  /** Explicit route (7d) or null to clear. Replies on the main thread with `{applied, reason?, current}`. */
  fun selectRoute(route: String?, reply: (Map<String, Any?>) -> Unit) {
    if (route != null && AudioRoutePolicy.explicitOrder(route) == null) {
      reply(mapOf("applied" to false, "reason" to "unknownRoute"))
      return
    }
    synchronized(this) { explicitRoute = route }
    val speakerRouting = speakerRoutingSnapshot()
    handler.post {
      val switch = audioSwitch
      val answer: Map<String, Any?> = when {
        switch == null -> mapOf("applied" to (route == null), "reason" to "noSession")
        !routingHandled(switch) -> {
          // MODE_NORMAL: Android routes media itself; nothing to select, but
          // the route already in use counts as applied (D3, 2026-10-10)
          // the reported route, never one outside the available list
          val current = routesSnapshot("selected")["current"] as? String
          val applied = AudioRoutePolicy.selectionApplied(route, current, routingHandled = false)
          mapOf("applied" to applied, "current" to current, "reason" to if (applied) null else "mediaMode")
        }
        else -> {
          applySpeakerRouting(switch, speakerRouting)
          val current = routeOf(switch.selectedAudioDevice)
          // applied = the asked-for route is the one in use (a missing headset
          // falls back to the next route, which is NOT "applied")
          val applied = AudioRoutePolicy.selectionApplied(route, current, routingHandled = true)
          mapOf(
            "applied" to applied,
            "current" to current,
            "reason" to if (applied) null else "routeIs:$current",
          )
        }
      }
      emitRoutes("selected")
      mainHandler.post { reply(answer) }
    }
  }

  /** `{routes, current, explicit, mode}`, replied on the main thread. */
  fun routes(reply: (Map<String, Any?>) -> Unit) {
    handler.post {
      val answer = routesSnapshot("")
      mainHandler.post { reply(answer) }
    }
  }

  private fun routingHandled(switch: AbstractAudioSwitch): Boolean {
    val mode = switch.audioMode
    return switch.forceHandleAudioRouting || mode == AudioManager.MODE_IN_COMMUNICATION || mode == AudioManager.MODE_IN_CALL
  }

  /** Handler thread. */
  private fun routesSnapshot(reason: String): Map<String, Any?> {
    val switch = audioSwitch
    val outputs = outputTypes()
    val handled = switch != null && isActive && routingHandled(switch)
    val available = LinkedHashSet<String>()
    if (handled) {
      switch!!.availableAudioDevices.mapNotNullTo(available, ::routeOf)
    } else {
      // media mode: the earpiece is not reachable for media playback
      outputs.mapNotNullTo(available, AudioRoutePolicy::routeOfDeviceType)
      available.remove(AudioRoutePolicy.EARPIECE)
      available.remove(AudioRoutePolicy.UNKNOWN)
    }
    val raw = if (handled) {
      routeOf(switch!!.selectedAudioDevice) ?: AudioRoutePolicy.UNKNOWN
    } else {
      mediaRoute(outputs)
    }
    val availableList = available.toList()
    val fallback = if (handled) availableList.firstOrNull() ?: AudioRoutePolicy.UNKNOWN else AudioRoutePolicy.mediaRouteOf(outputs)
    val current = AudioRoutePolicy.consistentCurrent(raw, availableList, fallback)
    if (current != raw) {
      // the platform routing has not settled (a headset just left): report a
      // consistent route now and read again shortly
      scheduleSettleRecheck(reason)
    } else {
      settleRechecks = 0
    }
    return mapOf(
      "routes" to availableList,
      "current" to current,
      "explicit" to synchronized(this) { explicitRoute },
      "mode" to (switch?.audioMode ?: effectiveAudioMode()),
      "reason" to reason,
    )
  }

  private fun outputTypes(): List<Int> = try {
    audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type }
  } catch (_: Throwable) {
    emptyList()
  }

  private fun mediaRoute(outputs: List<Int>): String {
    if (Build.VERSION.SDK_INT >= 33) {
      try {
        val attrs = AudioAttributes.Builder().setUsage(audioAttributeUsageType).build()
        val first: AudioDeviceInfo? = audioManager.getAudioDevicesForAttributes(attrs).firstOrNull()
        AudioRoutePolicy.routeOfDeviceType(first?.type ?: -1)?.let { return it }
      } catch (_: Throwable) {
      }
    }
    return AudioRoutePolicy.mediaRouteOf(outputs)
  }

  private val routeTracker = RouteChangeTracker()

  /** Handler thread. Emits only real changes (the reason is not a change). */
  private fun emitRoutes(reason: String) {
    val listener = onRoutesChanged ?: return
    val snap = routesSnapshot(reason)
    if (!routeTracker.offer(snap)) return
    mainHandler.post { listener(snap) }
  }

  // Media mode (2026-10-10 interruption-sim run): an A2DP-only headset or
  // wired headphones change where media plays without touching AudioSwitch's
  // communication-device list, so the platform's output-device callback is the
  // trigger there. Registered on this manager's thread while the session runs.
  private val outputDeviceCallback = object : AudioDeviceCallback() {
    override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = onOutputDevicesChanged("deviceAdded")

    override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) =
      onOutputDevicesChanged("deviceRemoved")
  }
  private var outputDeviceCallbackRegistered = false
  private val mediaRecheckToken = Any()

  /** Handler thread (the callback is registered with [handler]). */
  private fun onOutputDevicesChanged(reason: String) {
    val switch = audioSwitch ?: return
    if (!routeTracker.acceptsOutputDeviceChange(routingHandled(switch))) return
    emitRoutes(reason)
    handler.removeCallbacksAndMessages(mediaRecheckToken)
    for (delay in RouteChangeTracker.LATE_RECHECKS_MS) {
      handler.postAtTime({ emitRoutes("$reason(late)") }, mediaRecheckToken, android.os.SystemClock.uptimeMillis() + delay)
    }
  }

  private var settleRechecks = 0

  /** Handler thread. Bounded: at most a few re-reads while the routing settles. */
  private fun scheduleSettleRecheck(reason: String) {
    if (settleRechecks >= MAX_SETTLE_RECHECKS) return
    settleRechecks++
    val base = reason.removeSuffix("(settled)")
    handler.postAtTime(
      { emitRoutes("$base(settled)") },
      mediaRecheckToken,
      android.os.SystemClock.uptimeMillis() + RouteChangeTracker.LATE_RECHECKS_MS.first(),
    )
  }

  /** Handler thread. */
  private fun registerOutputDeviceCallback() {
    if (outputDeviceCallbackRegistered) return
    try {
      audioManager.registerAudioDeviceCallback(outputDeviceCallback, handler)
      outputDeviceCallbackRegistered = true
    } catch (t: Throwable) {
      Log.w(TAG, "output device callback unavailable", t)
    }
  }

  /** Handler thread. */
  private fun unregisterOutputDeviceCallback() {
    handler.removeCallbacksAndMessages(mediaRecheckToken)
    if (!outputDeviceCallbackRegistered) return
    outputDeviceCallbackRegistered = false
    try {
      audioManager.unregisterAudioDeviceCallback(outputDeviceCallback)
    } catch (_: Throwable) {
    }
  }

  private fun preferredDeviceList(
    speakerOutputPreferred: Boolean,
    speakerOutputForced: Boolean,
  ): List<Class<out AudioDevice>> =
    when {
      speakerOutputForced -> listOf(
        AudioDevice.Speakerphone::class.java,
        AudioDevice.BluetoothHeadset::class.java,
        AudioDevice.WiredHeadset::class.java,
        AudioDevice.Earpiece::class.java,
      )

      speakerOutputPreferred -> listOf(
        AudioDevice.BluetoothHeadset::class.java,
        AudioDevice.WiredHeadset::class.java,
        AudioDevice.Speakerphone::class.java,
        AudioDevice.Earpiece::class.java,
      )

      else -> listOf(
        AudioDevice.BluetoothHeadset::class.java,
        AudioDevice.WiredHeadset::class.java,
        AudioDevice.Earpiece::class.java,
        AudioDevice.Speakerphone::class.java,
      )
    }

  private data class SessionConfig(
    val manageAudioFocus: Boolean,
    val audioMode: Int,
    val focusMode: Int,
    val audioStreamType: Int,
    val audioAttributeUsageType: Int,
    val audioAttributeContentType: Int,
    val forceHandleAudioRouting: Boolean,
  )

  private data class SpeakerRouting(
    val preferredDeviceList: List<Class<out AudioDevice>>,
  )

  companion object {
    private const val TAG = "GxAudioSwitchManager"
    private const val SCO_SETTLE_MS = 1200L
    private val CHATROOM_TOKEN = Any()
    private const val MAX_SETTLE_RECHECKS = 4
  }
}

// Map the Flutter-side enum names (see android_audio_session_adapter.dart) to
// Android framework constants. Ported from flutter_webrtc's AudioUtils.

private fun audioModeForName(name: String?): Int? = when (name) {
  null -> null
  "normal" -> AudioManager.MODE_NORMAL
  "callScreening" -> AudioManager.MODE_CALL_SCREENING
  "inCall" -> AudioManager.MODE_IN_CALL
  "inCommunication" -> AudioManager.MODE_IN_COMMUNICATION
  "ringtone" -> AudioManager.MODE_RINGTONE
  else -> null
}

private fun focusModeForName(name: String?): Int? = when (name) {
  null -> null
  "gain" -> AudioManager.AUDIOFOCUS_GAIN
  "gainTransient" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
  "gainTransientExclusive" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
  "gainTransientMayDuck" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
  else -> null
}

private fun streamTypeForName(name: String?): Int? = when (name) {
  null -> null
  "accessibility" -> AudioManager.STREAM_ACCESSIBILITY
  "alarm" -> AudioManager.STREAM_ALARM
  "dtmf" -> AudioManager.STREAM_DTMF
  "music" -> AudioManager.STREAM_MUSIC
  "notification" -> AudioManager.STREAM_NOTIFICATION
  "ring" -> AudioManager.STREAM_RING
  "system" -> AudioManager.STREAM_SYSTEM
  "voiceCall" -> AudioManager.STREAM_VOICE_CALL
  else -> null
}

private fun usageTypeForName(name: String?): Int? = when (name) {
  null -> null
  "alarm" -> AudioAttributes.USAGE_ALARM
  "assistanceAccessibility" -> AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY
  "assistanceNavigationGuidance" -> AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
  "assistanceSonification" -> AudioAttributes.USAGE_ASSISTANCE_SONIFICATION
  "assistant" -> AudioAttributes.USAGE_ASSISTANT
  "game" -> AudioAttributes.USAGE_GAME
  "media" -> AudioAttributes.USAGE_MEDIA
  "notification" -> AudioAttributes.USAGE_NOTIFICATION
  "notificationEvent" -> AudioAttributes.USAGE_NOTIFICATION_EVENT
  "notificationRingtone" -> AudioAttributes.USAGE_NOTIFICATION_RINGTONE
  "unknown" -> AudioAttributes.USAGE_UNKNOWN
  "voiceCommunication" -> AudioAttributes.USAGE_VOICE_COMMUNICATION
  "voiceCommunicationSignalling" -> AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING
  else -> null
}

private fun contentTypeForName(name: String?): Int? = when (name) {
  null -> null
  "movie" -> AudioAttributes.CONTENT_TYPE_MOVIE
  "music" -> AudioAttributes.CONTENT_TYPE_MUSIC
  "sonification" -> AudioAttributes.CONTENT_TYPE_SONIFICATION
  "speech" -> AudioAttributes.CONTENT_TYPE_SPEECH
  "unknown" -> AudioAttributes.CONTENT_TYPE_UNKNOWN
  else -> null
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

/**
 * Pure decisions behind the microphone/route work of 0.4.15 (field report
 * 2026-10-10, items 7b/7c/7d). Framework constants are literals so the JVM
 * unit tests need no Android stubs (same reason as [CallServiceTypes]).
 */
internal object AudioRoutePolicy {
  // route names shared with Dart (GravixAudioRoute)
  const val SPEAKER = "speaker"
  const val EARPIECE = "earpiece"
  const val WIRED = "wiredHeadset"
  const val BLUETOOTH = "bluetooth"
  const val USB = "usb"
  const val UNKNOWN = "unknown"

  /** Dart's setEnableSpeakerphone(false): automatic, but earpiece over loudspeaker. */
  const val SPEAKER_OFF = "speakerOff"

  // AudioManager.MODE_*
  const val MODE_NORMAL = 0
  const val MODE_RINGTONE = 1
  const val MODE_IN_CALL = 2
  const val MODE_IN_COMMUNICATION = 3
  const val MODE_CALL_SCREENING = 4

  // AudioManager.AUDIOFOCUS_*
  const val FOCUS_GAIN = 1
  const val FOCUS_LOSS = -1
  const val FOCUS_LOSS_TRANSIENT = -2
  const val FOCUS_LOSS_TRANSIENT_CAN_DUCK = -3

  /** AudioDeviceInfo.TYPE_* -> route name; null for inputs and internal devices. */
  fun routeOfDeviceType(type: Int): String? = when (type) {
    2, 24 -> SPEAKER // BUILTIN_SPEAKER, BUILTIN_SPEAKER_SAFE
    1 -> EARPIECE // BUILTIN_EARPIECE
    3, 4 -> WIRED // WIRED_HEADSET, WIRED_HEADPHONES
    7, 8, 23, 26, 27, 30 -> BLUETOOTH // SCO, A2DP, HEARING_AID, BLE_HEADSET, BLE_SPEAKER, BLE_BROADCAST
    11, 12, 22 -> USB // USB_DEVICE, USB_ACCESSORY, USB_HEADSET
    5, 6, 9, 10, 13, 19, 29, 31 -> UNKNOWN // line, HDMI, dock, aux
    else -> null
  }

  fun focusName(change: Int): String = when (change) {
    FOCUS_GAIN, 2, 3, 4 -> "gain"
    FOCUS_LOSS -> "loss"
    FOCUS_LOSS_TRANSIENT -> "lossTransient"
    FOCUS_LOSS_TRANSIENT_CAN_DUCK -> "lossTransientCanDuck"
    else -> "unknown"
  }

  /**
   * A cellular call holds the audio mode (RINGTONE is only ringing: the
   * microphone is not taken yet).
   */
  fun isPhoneCallMode(mode: Int): Boolean = mode == MODE_IN_CALL || mode == MODE_CALL_SCREENING

  /**
   * The Bluetooth "chatroom" model (7b): the session mode to run in.
   *
   * Only a media-mode app (base MODE_NORMAL) is switched, only while the
   * option is on, the local microphone is published and unmuted, and a
   * Bluetooth headset with a microphone (HFP/SCO, a communication device) is
   * connected. Everything else keeps the configured mode.
   */
  fun chatroomMode(enabled: Boolean, micActive: Boolean, bluetoothHeadset: Boolean, baseMode: Int): Int =
    if (enabled && micActive && bluetoothHeadset && baseMode == MODE_NORMAL) MODE_IN_COMMUNICATION else baseMode

  /**
   * Preferred-route order for an explicit selection (7d), most wanted first.
   * Null = no explicit selection (the speaker preference decides). A route that
   * goes away falls to the next one, so a Bluetooth selection ends with the
   * headset instead of sticking.
   */
  fun explicitOrder(route: String?): List<String>? = when (route) {
    null -> null
    SPEAKER -> listOf(SPEAKER, BLUETOOTH, WIRED, EARPIECE)
    EARPIECE -> listOf(EARPIECE, BLUETOOTH, WIRED, SPEAKER)
    WIRED, USB -> listOf(WIRED, BLUETOOTH, SPEAKER, EARPIECE)
    BLUETOOTH -> listOf(BLUETOOTH, WIRED, SPEAKER, EARPIECE)
    SPEAKER_OFF -> listOf(BLUETOOTH, WIRED, EARPIECE, SPEAKER)
    else -> null
  }

  /**
   * Whether a [route] selection counts as applied, given the route now in use
   * ([current]) and whether the session routes at all ([routingHandled]: false
   * in MODE_NORMAL, where Android routes media itself).
   */
  fun selectionApplied(route: String?, current: String?, routingHandled: Boolean): Boolean {
    if (route == null) return true
    if (!routingHandled) {
      // MODE_NORMAL: nothing is selected, but asking for the route media
      // already plays on is a no-op success (device run D3, 2026-10-10);
      // speakerphone off holds while a headset carries the media
      return if (route == SPEAKER_OFF) current == BLUETOOTH || current == WIRED || current == USB else current == route
    }
    // speakerphone off holds only when the session is on a route other than
    // the loudspeaker (2026-10-11, route API nit: it answered applied=true even
    // when no earpiece or headset existed and the speaker stayed in use)
    if (route == SPEAKER_OFF) return current != null && current != SPEAKER && current != UNKNOWN
    val asked = if (route == USB) WIRED else route
    return current == asked
  }

  /**
   * The current route to report: never one outside [available]. Phone run
   * 2026-10-10 (Infinix, SpaceBuds): on a headset disconnect the media routing
   * still answered "earpiece" for 0.9 s while only the speaker was available.
   * An answer outside the list falls back to [fallback] (the output-device
   * heuristic) when that is available, else the first available route; unknown
   * stays unknown.
   */
  fun consistentCurrent(current: String, available: List<String>, fallback: String): String = when {
    current == UNKNOWN || current in available -> current
    fallback in available -> fallback
    else -> available.firstOrNull() ?: UNKNOWN
  }

  /**
   * Where media plays in MODE_NORMAL when the platform cannot say (below API
   * 33): Android sends media to the most recently connected external output;
   * this approximates it with a fixed priority over the connected outputs.
   */
  fun mediaRouteOf(outputTypes: Collection<Int>): String {
    val routes = outputTypes.mapNotNull(::routeOfDeviceType).toSet()
    return when {
      // A2DP (8) / LE (26, 27) carry media; an SCO-only (7) headset does not in MODE_NORMAL
      outputTypes.any { it == 8 || it == 26 || it == 27 || it == 23 } -> BLUETOOTH
      WIRED in routes -> WIRED
      USB in routes -> USB
      else -> SPEAKER
    }
  }
}

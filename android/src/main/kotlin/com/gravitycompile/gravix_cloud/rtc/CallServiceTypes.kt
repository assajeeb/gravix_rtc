// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

/**
 * Which foreground-service types [GravixCallService] asks for. Pure, so it can
 * be unit-tested without an Android runtime (`sdkInt` is a parameter because
 * `Build.VERSION.SDK_INT` is 0 under the JVM stubs).
 *
 *  - `mediaPlayback` always (API 29+): a listener with no microphone still has
 *    to keep receiving and playing the room.
 *  - `microphone` (API 30+) only when RECORD_AUDIO is granted AND the caller
 *    says the mic is (or may be) published. Android 14 throws a
 *    SecurityException for a microphone-typed service without the permission;
 *    without the type, Android 11+ silences the capture ~5 s after the app
 *    leaves the screen ("App op 27 missing, silencing record", field
 *    2026-10-05).
 *  - `camera` (API 30+) only when asked for and CAMERA is granted.
 *
 * Below API 29 a service has no type (0): `startForeground(id, notification)`.
 * On API 29 only `mediaPlayback` exists, and the background-capture limit the
 * microphone type lifts only arrived with API 30.
 */
internal object CallServiceTypes {
  // ServiceInfo.FOREGROUND_SERVICE_TYPE_* (literal so the JVM tests need no SDK stubs)
  const val MEDIA_PLAYBACK = 0x02
  const val CAMERA = 0x40
  const val MICROPHONE = 0x80

  fun compute(
    sdkInt: Int,
    micWanted: Boolean,
    micGranted: Boolean,
    cameraWanted: Boolean,
    cameraGranted: Boolean,
  ): Int {
    if (sdkInt < 29) return 0
    var types = MEDIA_PLAYBACK
    if (sdkInt >= 30) {
      if (micWanted && micGranted) types = types or MICROPHONE
      if (cameraWanted && cameraGranted) types = types or CAMERA
    }
    return types
  }

  fun names(types: Int): List<String> {
    val out = mutableListOf<String>()
    if (types and MICROPHONE != 0) out.add("microphone")
    if (types and MEDIA_PLAYBACK != 0) out.add("mediaPlayback")
    if (types and CAMERA != 0) out.add("camera")
    return out
  }
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

/**
 * The capture source singer mode records from (GravixSingerCaptureSource in
 * Dart). WebRTC builds its recorder with VOICE_COMMUNICATION, the call path:
 * on most phones the HAL runs its own echo canceller, noise suppressor and
 * AGC there whatever the app asks (they pull held and high notes down).
 * [GxCaptureSwitcher] re-opens the recorder with the source below; the audio
 * device module is not rebuilt.
 *
 * - "mic": MIC (1), the default: what Agora's GAME_STREAMING / wired-headset
 *   chat room and ZEGO's KTV mode record from.
 * - "voiceRecognition": VOICE_RECOGNITION (6); the CDD requires noise
 *   reduction and AGC off on it.
 * - "unprocessed": UNPROCESSED (9) where the phone says it supports it
 *   (AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED, API 24+), else
 *   VOICE_RECOGNITION. Flat and raw; quiet on some built-in mics.
 * - "keep" / anything else: no change (null).
 *
 * The constants are MediaRecorder.AudioSource's, as plain ints so the JVM
 * unit tests need no Android framework.
 */
internal object GxSingerSource {
  const val MIC = 1
  const val VOICE_RECOGNITION = 6
  const val VOICE_COMMUNICATION = 7
  const val UNPROCESSED = 9

  fun resolve(name: String?, sdkInt: Int, unprocessedSupported: Boolean): Int? = when (name) {
    "mic" -> MIC
    "voiceRecognition" -> VOICE_RECOGNITION
    "unprocessed" -> if (sdkInt >= 24 && unprocessedSupported) UNPROCESSED else VOICE_RECOGNITION
    else -> null
  }
}

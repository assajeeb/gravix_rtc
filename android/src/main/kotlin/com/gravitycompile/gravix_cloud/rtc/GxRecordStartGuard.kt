// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import android.util.Log
import org.webrtc.audio.JavaAudioDeviceModule
import org.webrtc.audio.JavaAudioDeviceModule.AudioRecordErrorCallback
import org.webrtc.audio.JavaAudioDeviceModule.AudioRecordStartErrorCode
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Stops a refused microphone start from aborting the process (Play Console,
 * SIGABRT at jvm.cc:81 under AudioRecordJni::StartRecording; reproduced
 * 2026-11-02 on webrtc-sdk 150.7871.01).
 *
 * WebRtcAudioRecord.startRecording() sets nativeCalledStartRecording before it
 * opens the microphone and leaves it set when AudioRecord refuses to start. The
 * native side then has recording_ false, so its StopRecording does not reach
 * Java and nothing clears the flag. The engine's next StartRecording makes Java
 * throw "startRecording called twice without stopRecording", and native code
 * aborts on the pending exception. That next start can come from a mic toggle or
 * from the same negotiation, within milliseconds.
 *
 * WebRTC reports the refusal through its error callback before it returns false,
 * so clearing the flag there turns the next start into a normal retry on the same
 * AudioRecord. flutter_webrtc builds the module without an error callback, so the
 * private final field is set by reflection, as the other recorder hooks do.
 */
internal object GxRecordStartGuard {
  private const val TAG = "GxRecordStartGuard"

  /** Idempotent. A failure leaves WebRTC as it was and is only logged. */
  fun installOn(adm: JavaAudioDeviceModule?) {
    val input = try {
      adm?.javaClass?.getField("audioInput")?.get(adm)
    } catch (t: Throwable) {
      Log.w(TAG, "not installed: audio input unreadable: $t")
      null
    } ?: return
    try {
      val callbackField = field(input, "errorCallback")
      val current = callbackField.get(input) as AudioRecordErrorCallback?
      if (current is Callback) return
      val flag = field(input, "nativeCalledStartRecording").get(input) as AtomicBoolean
      callbackField.set(input, Callback(flag, current))
      Log.i(TAG, "installed (previous callback: ${current?.javaClass?.name})")
    } catch (t: Throwable) {
      Log.w(TAG, "not installed: $t")
    }
  }

  private fun field(input: Any, name: String) =
    input.javaClass.getDeclaredField(name).apply { isAccessible = true }

  /**
   * Runs inside startRecordingImpl with WebRTC's recorder locks held, on the
   * native call's stack: it must not block, and nothing may escape it, because
   * an exception here would reach native code and cause the same abort. The
   * parameters are nullable so Kotlin's generated null checks cannot throw.
   */
  private class Callback(
    private val nativeCalledStart: AtomicBoolean,
    private val previous: AudioRecordErrorCallback?,
  ) : AudioRecordErrorCallback {
    override fun onWebRtcAudioRecordStartError(code: AudioRecordStartErrorCode?, message: String?) {
      nativeCalledStart.set(false)
      Log.w(TAG, "microphone start refused ($code): $message; the next start retries")
      chain { it.onWebRtcAudioRecordStartError(code, message) }
    }

    override fun onWebRtcAudioRecordInitError(message: String?) {
      Log.w(TAG, "microphone init failed: $message")
      chain { it.onWebRtcAudioRecordInitError(message) }
    }

    override fun onWebRtcAudioRecordError(message: String?) {
      Log.w(TAG, "microphone error: $message")
      chain { it.onWebRtcAudioRecordError(message) }
    }

    private inline fun chain(call: (AudioRecordErrorCallback) -> Unit) {
      val next = previous ?: return
      try {
        call(next)
      } catch (t: Throwable) {
        Log.w(TAG, "previous error callback failed: $t")
      }
    }
  }
}

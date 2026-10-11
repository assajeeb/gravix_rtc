// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.webrtc.audio.JavaAudioDeviceModule
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Applies the other-app capture action Dart decides (owner report 2026-10-10:
 * YouTube / a game on the phone is heard by the room). Every action is undone
 * by [OtherAppAudioPolicy.Action.NONE], which puts the capture back exactly as
 * WebRTC built it.
 *
 * - PLATFORM_EFFECTS: android.media.audiofx AcousticEchoCanceler +
 *   NoiseSuppressor attached to WebRTC's running AudioRecord session. With the
 *   media profile (bypassVoiceProcessing) WebRTC never enables them itself:
 *   its builder says "no hardware AEC/NS", and `isAcousticEchoCancelerSupported`
 *   is a final field set from that. Whether the platform AEC hears other
 *   apps' output (its reference) is per phone: measured, not assumed.
 * - VOICE_COMMUNICATION: WebRTC's recorder re-opened with the
 *   VOICE_COMMUNICATION source (+ the effects above), the source a call app
 *   records from. libwebrtc fixes the source when the audio device module is
 *   built (`WebRtcAudioRecord.audioSource` is private final, read each time
 *   it opens an AudioRecord), so it is rewritten by reflection and the
 *   recorder restarted under WebRTC's own lock, the same sequence its
 *   stop/init/start paths run. A failed open falls back to the original source.
 * - MUTE: the engine's microphone mute, combined with the user's own mute
 *   ([OtherAppAudioPolicy.engineMute]) so neither undoes the other.
 *
 * All recorder work runs on [executor] (the plugin's audio device module
 * thread), never on the main thread.
 */
internal class GxCaptureSwitcher(
  private val adm: () -> JavaAudioDeviceModule?,
  private val executor: () -> ExecutorService?,
) {
  @Volatile
  var userMuted = false
    private set

  @Volatile
  private var autoMuted = false

  @Volatile
  private var action = OtherAppAudioPolicy.Action.NONE
  private var originalSource: Int? = null
  private var effectsSession = 0
  private val main = Handler(Looper.getMainLooper())
  private var aec: AcousticEchoCanceler? = null
  private var ns: NoiseSuppressor? = null

  private val muteLock = Any()

  /** The user's engine mute (setMicrophoneMute); returns the applied mute. */
  fun setUserMute(muted: Boolean): Boolean = synchronized(muteLock) {
    userMuted = muted
    val effective = OtherAppAudioPolicy.engineMute(userMuted, autoMuted)
    adm()?.setMicrophoneMute(effective)
    effective
  }

  // main thread (user) and the module thread (automatic) both write the one
  // engine flag: under one lock, so the last write always reflects both
  private fun setAutoMute(muted: Boolean) = synchronized(muteLock) {
    if (autoMuted == muted) return@synchronized
    autoMuted = muted
    adm()?.setMicrophoneMute(OtherAppAudioPolicy.engineMute(userMuted, autoMuted))
  }

  fun apply(next: OtherAppAudioPolicy.Action) {
    run { applyOnWorker(next, attempt = 0) }
  }

  /** Plugin detach: back to the original capture. */
  fun reset() {
    run { applyOnWorker(OtherAppAudioPolicy.Action.NONE, attempt = 0) }
  }

  private fun run(block: () -> Unit) {
    val ex = executor() ?: return
    try {
      ex.execute {
        try {
          block()
        } catch (t: Throwable) {
          Log.w(TAG, "capture action failed", t)
        }
      }
    } catch (_: RejectedExecutionException) {
      // plugin detaching
    }
  }

  private fun applyOnWorker(next: OtherAppAudioPolicy.Action, attempt: Int) {
    val prev = action
    action = next
    Log.i(TAG, "capture action $prev -> $next")
    val wantSource = next == OtherAppAudioPolicy.Action.VOICE_COMMUNICATION
    val wantEffects = next == OtherAppAudioPolicy.Action.PLATFORM_EFFECTS || wantSource
    val wantMute = next == OtherAppAudioPolicy.Action.MUTE

    setAutoMute(wantMute)
    if (!wantEffects) releaseEffects()
    val input = webRtcAudioRecord()
    if (input != null) {
      val original = originalSource ?: readSource(input)?.also { originalSource = it }
      if (original != null) {
        val target = if (wantSource) MediaRecorder.AudioSource.VOICE_COMMUNICATION else original
        if (readSource(input) != target) switchSource(input, target, original)
      }
    }
    if (wantEffects && !attachEffects(input) && attempt < 5) {
      // the recorder is not open yet (an unmute just started it): try again
      // later without holding the audio device module thread
      main.postDelayed({ run { if (action == next) applyOnWorker(next, attempt + 1) } }, 300)
    }
  }

  /**
   * WebRTC's recorder: `audioInput` is a public field of a package-private
   * class (WebRtcAudioRecord), so it is read by reflection (as the plugin does).
   */
  private fun webRtcAudioRecord(): Any? = try {
    val m = adm()
    m?.javaClass?.getField("audioInput")?.get(m)
  } catch (_: Throwable) {
    null
  }

  // ── platform effects ───────────────────────────────────────────────────

  private fun recorder(input: Any): AudioRecord? = try {
    input.javaClass.getDeclaredField("audioRecord").apply { isAccessible = true }.get(input) as? AudioRecord
  } catch (_: Throwable) {
    null
  }

  /** True when attached (or already attached) to the running recorder. */
  private fun attachEffects(input: Any?): Boolean {
    val session = input?.let { recorder(it)?.audioSessionId } ?: 0
    if (session <= 0) return false
    if (session == effectsSession && (aec != null || ns != null)) return true
    releaseEffects()
    effectsSession = session
    aec = if (AcousticEchoCanceler.isAvailable()) create { AcousticEchoCanceler.create(session) } else null
    ns = if (NoiseSuppressor.isAvailable()) create { NoiseSuppressor.create(session) } else null
    Log.i(TAG, "platform effects on session $session: aec=${describe(aec)} ns=${describe(ns)}")
    return true
  }

  private fun <T : AudioEffect> create(make: () -> T?): T? = try {
    make()?.also { it.enabled = true }
  } catch (t: Throwable) {
    Log.w(TAG, "platform effect unavailable: $t")
    null
  }

  private fun describe(e: AudioEffect?): String =
    if (e == null) "none" else try {
      "${e.descriptor.name}/${e.descriptor.implementor} enabled=${e.enabled}"
    } catch (_: Throwable) {
      "attached"
    }

  private fun releaseEffects() {
    if (aec == null && ns == null) return
    try { aec?.release() } catch (_: Throwable) {}
    try { ns?.release() } catch (_: Throwable) {}
    aec = null
    ns = null
    Log.i(TAG, "platform effects released (session $effectsSession)")
    effectsSession = 0
  }

  // ── capture source ─────────────────────────────────────────────────────

  private fun field(input: Any, name: String) =
    input.javaClass.getDeclaredField(name).apply { isAccessible = true }

  private fun readSource(input: Any): Int? = try {
    field(input, "audioSource").getInt(input)
  } catch (t: Throwable) {
    Log.w(TAG, "capture source unreadable: $t")
    null
  }

  private fun switchSource(input: Any, target: Int, original: Int) {
    val cls = input.javaClass
    val lock = field(input, "audioRecordStateLock").get(input) ?: return
    synchronized(lock) {
      val sourceField = field(input, "audioSource")
      val running = recorder(input) != null && field(input, "audioThread").get(input) != null
      sourceField.setInt(input, target)
      if (!running) {
        // not recording: the next start opens with the new source
        Log.i(TAG, "capture source -> $target (applies at the next start)")
        return
      }
      releaseEffects()
      val sampleRate = field(input, "sampleRate").getInt(input)
      val channels = field(input, "channelCount").getInt(input)
      val client = field(input, "clientCalledStartRecording").get(input) as AtomicBoolean
      val native = field(input, "nativeCalledStartRecording").get(input) as AtomicBoolean
      val c0 = client.get()
      val n0 = native.get()
      val t0 = System.nanoTime()
      // stopRecordingIfNeededImpl only stops when nobody asked for recording:
      // clear both flags for the call, restore them right after (we hold the
      // same lock WebRTC's own start/stop paths take).
      client.set(false)
      native.set(false)
      try {
        cls.getDeclaredMethod("stopRecordingIfNeededImpl").apply { isAccessible = true }.invoke(input)
      } finally {
        client.set(c0)
        native.set(n0)
      }
      val init = cls.getDeclaredMethod(
        "initRecordingImpl",
        Int::class.javaPrimitiveType,
        Int::class.javaPrimitiveType,
        Boolean::class.javaPrimitiveType,
      ).apply { isAccessible = true }
      val start = cls.getDeclaredMethod("startRecordingImpl").apply { isAccessible = true }
      // true = re-cache the new direct buffer's address in the native recorder
      var frames = init.invoke(input, sampleRate, channels, true) as Int
      var started = frames >= 0 && start.invoke(input) as Boolean
      if (!started && target != original) {
        Log.w(TAG, "capture source $target refused (init=$frames): back to $original")
        try {
          if (recorder(input) != null) {
            client.set(false)
            native.set(false)
            try {
              cls.getDeclaredMethod("stopRecordingIfNeededImpl").apply { isAccessible = true }.invoke(input)
            } finally {
              client.set(c0)
              native.set(n0)
            }
          }
        } catch (_: Throwable) {}
        sourceField.setInt(input, original)
        frames = init.invoke(input, sampleRate, channels, true) as Int
        started = frames >= 0 && start.invoke(input) as Boolean
      }
      val ms = (System.nanoTime() - t0) / 1_000_000
      Log.i(TAG, "capture source -> ${sourceField.getInt(input)} restarted=$started in ${ms} ms " +
        "(rate=$sampleRate ch=$channels session=${recorder(input)?.audioSessionId})")
    }
  }

  companion object {
    private const val TAG = "GxOtherAppAudio"
  }
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import android.content.Context
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executor

/**
 * Reports what the platform does to our microphone (0.4.15, field report
 * 2026-10-10, items 7a/7c): until now a capture Android silenced (a phone or
 * VoIP call, a missing microphone foreground-service type in the background)
 * left one log line at most.
 *
 * Event-driven, no polling: AudioRecordingCallback (start/stop/silenced),
 * the audio mode listener (API 31+; the mode is also read on every other
 * event), and the session's audio-focus changes forwarded by
 * [GxAudioSwitchManager]. Runs only between [start] and [stop] (Dart starts it
 * while a room exists). Every change goes to [emit] as one map, on the main
 * thread: `recording` (Boolean, absent when unknown), `silenced`, `focus`,
 * `phoneCall`, `mode`, `sdkInt`.
 *
 * Threading (2026-10-10, device run E: warm joins +250 ms): every AudioManager
 * call runs on this monitor's own thread, never on the main thread.
 * AudioService.getMode() waits on the same lock as setMode(), and a warm join
 * runs the previous session's setMode(NORMAL) and the new session's
 * setMode(IN_COMMUNICATION) on the audio-switch thread at exactly that moment:
 * a getMode() (or a listener registration) on the main thread blocked it for
 * 250-400 ms, and with it every platform-channel reply the join was awaiting
 * (audioSessionEnd -> wsConnectStart went from ~13 ms to 263-402 ms).
 *
 * [sessionId] returns the audio session id of WebRTC's AudioRecord (> 0), 0
 * when WebRTC has no AudioRecord (not recording), or -1 when it cannot be read;
 * with it our own recording is told apart from another app's.
 */
internal class GxMicMonitor(
  context: Context,
  private val sessionId: () -> Int,
  private val emit: (Map<String, Any?>) -> Unit,
) {
  private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  private val main = Handler(Looper.getMainLooper())
  private val thread = HandlerThread("GravixMicMonitor").also { it.start() }
  private val worker = Handler(thread.looper)
  private val workerExecutor = Executor { worker.post(it) }

  @Volatile
  private var running = false

  @Volatile
  private var focus = AudioRoutePolicy.FOCUS_GAIN
  private var last: Map<String, Any?>? = null

  private val recordingCallback: Any? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>?) {
          publish()
        }
      }
    } else {
      null
    }

  private val modeListener: Any? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      AudioManager.OnModeChangedListener { publish() }
    } else {
      null
    }

  /**
   * Starts listening. Returns at once (any thread); the first snapshot is
   * emitted from the monitor thread like every later one.
   */
  fun start() {
    worker.post {
      if (!running) {
        running = true
        // a monitor stopped during a transient loss must not restart "interrupted"
        focus = AudioRoutePolicy.FOCUS_GAIN
        try {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            audioManager.registerAudioRecordingCallback(recordingCallback as AudioManager.AudioRecordingCallback, worker)
          }
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.addOnModeChangedListener(workerExecutor, modeListener as AudioManager.OnModeChangedListener)
          }
        } catch (t: Throwable) {
          Log.w(TAG, "mic monitor registration failed", t)
        }
      }
      last = null
      publish()
    }
  }

  /** Returns at once; unregisters on the monitor thread. */
  fun stop() {
    worker.post { stopOnWorker() }
  }

  /** Plugin detach: stop and end the thread. */
  fun dispose() {
    worker.post {
      stopOnWorker()
      thread.quitSafely()
    }
  }

  private fun stopOnWorker() {
    if (!running) return
    running = false
    last = null
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
        audioManager.unregisterAudioRecordingCallback(recordingCallback as AudioManager.AudioRecordingCallback)
      }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        audioManager.removeOnModeChangedListener(modeListener as AudioManager.OnModeChangedListener)
      }
    } catch (t: Throwable) {
      Log.w(TAG, "mic monitor unregistration failed", t)
    }
  }

  /** From the session's audio-focus listener (any thread). */
  fun onFocusChange(change: Int) {
    focus = change
    worker.post { publish() }
  }

  /** Re-reads and emits when something changed. Monitor thread only. */
  private fun publish() {
    if (!running) return
    val snap = snapshot()
    if (snap == last) return
    last = snap
    Log.i(TAG, "mic signals $snap")
    main.post { emit(snap) }
  }

  private fun snapshot(): Map<String, Any?> {
    val mode = try {
      audioManager.mode
    } catch (_: Throwable) {
      AudioRoutePolicy.MODE_NORMAL
    }
    val out = HashMap<String, Any?>()
    out["sdkInt"] = Build.VERSION.SDK_INT
    out["mode"] = mode
    out["phoneCall"] = AudioRoutePolicy.isPhoneCallMode(mode)
    out["focus"] = AudioRoutePolicy.focusName(focus)
    out["silenced"] = false
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      val configs = try {
        audioManager.activeRecordingConfigurations
      } catch (_: Throwable) {
        emptyList<AudioRecordingConfiguration>()
      }
      val own = sessionId()
      if (own > 0) {
        val mine = configs.firstOrNull { it.clientAudioSessionId == own }
        out["recording"] = mine != null
        out["silenced"] = mine != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && mine.isClientSilenced
      } else if (own == 0) {
        out["recording"] = false
      } else {
        // the id is unreadable: "recording" stays unknown; a silenced capture
        // is still a silenced capture.
        out["silenced"] = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && configs.any { it.isClientSilenced }
      }
    }
    return out
  }

  companion object {
    private const val TAG = "GxMicMonitor"
  }
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Watches other apps' playback during a room (owner report 2026-10-10: YouTube
 * or a game on the phone is heard by the room through a MIC-source capture,
 * whose software echo canceller only knows WebRTC's own playout).
 *
 * Event-driven: AudioManager.AudioPlaybackCallback (API 26+, no permission, no
 * audio content), registered and evaluated on this watcher's own thread, never
 * on the main thread (the 2026-10-10 join regression was a main-thread
 * AudioManager call). Runs only between [start] and [stop]; off = never
 * created. Emits `playing` (debounced, see [OtherAppAudioPolicy.Debouncer]) and
 * `players` to [emit] on the main thread, only on a change of `playing`.
 *
 * [ownPlayers] returns the attributes of our own started players, read on
 * this thread: WebRTC's playout track while it plays and the SDK's silent
 * keep-alive (merge 2026-10-11). In the media profile both are USAGE_MEDIA
 * players, like YouTube, and the public configurations carry no uid.
 */
internal class GxOtherAppAudioMonitor(
  context: Context,
  private val ownPlayers: () -> List<OtherAppAudioPolicy.Player>,
  private val emit: (Map<String, Any?>) -> Unit,
  private val onChange: (Boolean) -> Unit = {},
) {
  private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  private val main = Handler(Looper.getMainLooper())
  private val thread = HandlerThread("GravixOtherAppAudio").also { it.start() }
  private val worker = Handler(thread.looper)
  private val debouncer = OtherAppAudioPolicy.Debouncer(ON_DELAY_MS, OFF_DELAY_MS)
  private var running = false
  private var lastPlayers = 0
  private val recheck = Runnable { evaluate(null) }

  private val callback: Any? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>?) {
          evaluate(configs)
        }
      }
    } else {
      null
    }

  @Volatile
  var playing = false
    private set

  fun start() {
    worker.post {
      if (running || callback == null) return@post
      running = true
      try {
        audioManager.registerAudioPlaybackCallback(callback as AudioManager.AudioPlaybackCallback, worker)
      } catch (t: Throwable) {
        Log.w(TAG, "playback callback registration failed", t)
      }
      evaluate(null)
    }
  }

  fun stop() {
    worker.post { stopOnWorker() }
  }

  fun dispose() {
    worker.post {
      stopOnWorker()
      thread.quitSafely()
    }
  }

  private fun stopOnWorker() {
    if (!running) return
    running = false
    worker.removeCallbacks(recheck)
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        audioManager.unregisterAudioPlaybackCallback(callback as AudioManager.AudioPlaybackCallback)
      }
    } catch (t: Throwable) {
      Log.w(TAG, "playback callback unregistration failed", t)
    }
    debouncer.reset()
    if (playing) {
      playing = false
      main.post { onChange(false) }
    }
  }

  /** Watcher thread. [given] = the callback's list, or null to read it. */
  private fun evaluate(given: List<AudioPlaybackConfiguration>?) {
    if (!running || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val configs = given ?: try {
      audioManager.activePlaybackConfigurations
    } catch (_: Throwable) {
      emptyList<AudioPlaybackConfiguration>()
    }
    val players = configs.map { toPlayer(it) }
    val own = try {
      ownPlayers()
    } catch (_: Throwable) {
      emptyList()
    }
    val foreign = OtherAppAudioPolicy.foreignPlayers(players, own)
    // uptimeMillis: the same clock as Handler.postAtTime below
    val now = SystemClock.uptimeMillis()
    val before = debouncer.state
    val state = debouncer.update(foreign > 0, now)
    worker.removeCallbacks(recheck)
    debouncer.nextCheckAt()?.let { worker.postAtTime(recheck, it + 1) }
    if (foreign != lastPlayers) {
      lastPlayers = foreign
      Log.i(TAG, "players=${players.size} foreign=$foreign own=${own.size} " +
        players.joinToString(prefix = "[", postfix = "]") { "u${it.usage}/c${it.contentType}/spk=${it.onSpeaker}" })
    }
    if (state != before) {
      playing = state
      Log.i(TAG, "other app audio ${if (state) "PLAYING" else "STOPPED"} (foreign players=$foreign)")
      val event = mapOf<String, Any?>("playing" to state, "players" to foreign)
      main.post {
        onChange(state)
        emit(event)
      }
    }
  }

  private fun toPlayer(c: AudioPlaybackConfiguration): OtherAppAudioPolicy.Player {
    val attrs: AudioAttributes = c.audioAttributes
    val onSpeaker: Boolean? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      try {
        // deprecated on API 36 for getAudioDeviceInfos(); the single device is enough here
        @Suppress("DEPRECATION")
        c.audioDeviceInfo?.let { isAcoustic(it.type) }
      } catch (_: Throwable) {
        null
      }
    } else {
      null
    }
    return OtherAppAudioPolicy.Player(attrs.usage, attrs.contentType, onSpeaker)
  }

  private fun isAcoustic(type: Int): Boolean = type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER ||
    type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE ||
    (Build.VERSION.SDK_INT >= 30 && type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE)

  companion object {
    private const val TAG = "GxOtherAppAudio"
    const val ON_DELAY_MS = 1000L
    const val OFF_DELAY_MS = 2000L
  }
}

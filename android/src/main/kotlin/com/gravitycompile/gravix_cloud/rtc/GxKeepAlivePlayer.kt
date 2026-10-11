// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Silent playback while the app is backgrounded in a room with no real
 * playout (GravixAudioDeviceOptions.backgroundKeepAlive, opt-in, 0.4.15).
 *
 * Why (device run 2026-10-10, Infinix Android 15): the Transsion "Hiber" app
 * freezer froze a silent background listener ~3.6 s after Home despite the
 * call foreground service, force-released its wake lock and destroyed its
 * sockets; the app dropped from the room ~45 s later. Hiber refuses to freeze
 * an app with active audio ("importantcase is : audio_in"). This keeps one
 * player active: 8 kHz mono zeros, no audio focus request, no routing call.
 *
 * Everything that talks to audioserver runs on the player's own thread (never
 * the main thread: see GxMicMonitor). [usage] is the session's configured
 * AudioAttributes usage; [webRtcPlaying] says whether WebRTC's own player
 * already runs (then nothing is started).
 */
internal class GxKeepAlivePlayer(
  private val usage: () -> Int,
  private val webRtcPlaying: () -> Boolean,
) {
  @Volatile
  private var running = false
  private var thread: Thread? = null

  // Started keep-alive tracks as the other-app watcher sees them (added before
  // play, removed after release). A list, not a flag: a quick off/on can
  // overlap the old track's release with the new track's start.
  private val started = CopyOnWriteArrayList<OtherAppAudioPolicy.Player>()

  /**
   * Our keep-alive players that are started now (any thread). Merge
   * 2026-10-11: the other-app watcher must not count our own keep-alive as
   * another app's audio (it then muted the user with muteMicInBackground).
   */
  fun ownPlayers(): List<OtherAppAudioPolicy.Player> = started.toList()

  /** Main thread. */
  @Synchronized
  fun setActive(active: Boolean) {
    if (active == running) return
    running = active
    if (active) {
      thread = Thread(::run, "GravixKeepAlive").also { it.start() }
    } else {
      thread?.interrupt()
      thread = null
    }
  }

  private fun run() {
    if (webRtcPlaying()) {
      Log.i(TAG, "keep-alive not started: WebRTC playout already runs")
      return
    }
    var track: AudioTrack? = null
    var added: OtherAppAudioPolicy.Player? = null
    try {
      val me = OtherAppAudioPolicy.keepAlivePlayer(usage())
      // ours before the track exists: a built AudioTrack already shows up in
      // the playback configurations
      started.add(me)
      added = me
      val min = AudioTrack.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
      val bytes = maxOf(min, SAMPLE_RATE / 5 * 2) // >= 200 ms
      track = AudioTrack.Builder()
        .setAudioAttributes(AudioAttributes.Builder().setUsage(me.usage).setContentType(me.contentType).build())
        .setAudioFormat(
          AudioFormat.Builder()
            .setSampleRate(SAMPLE_RATE)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build(),
        )
        .setBufferSizeInBytes(bytes)
        .setTransferMode(AudioTrack.MODE_STREAM)
        .build()
      val zeros = ByteArray(SAMPLE_RATE / 50 * 2) // 20 ms
      track.play()
      Log.i(TAG, "keep-alive playing (usage ${me.usage})")
      // write() blocks once the buffer is full: paced by the device, ~50 wakeups/s of a few bytes
      while (running && !Thread.currentThread().isInterrupted) {
        if (track.write(zeros, 0, zeros.size) < 0) break
      }
    } catch (t: Throwable) {
      Log.w(TAG, "keep-alive player failed", t)
    } finally {
      try {
        track?.pause()
        track?.flush()
        track?.stop()
      } catch (_: Throwable) {
      }
      track?.release()
      // after release: a configuration still listing it never reads as another app
      if (added != null) started.remove(added)
      Log.i(TAG, "keep-alive stopped")
    }
  }

  companion object {
    private const val TAG = "GxKeepAlive"
    private const val SAMPLE_RATE = 8000
  }
}

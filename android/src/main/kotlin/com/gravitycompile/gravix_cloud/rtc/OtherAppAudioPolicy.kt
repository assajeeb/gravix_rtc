// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

/**
 * Pure decisions of the other-app audio watcher (owner report 2026-10-10: "with
 * the mic on, YouTube or a game on the phone is heard by the room"). In the
 * media profile WebRTC captures from the MIC source and its software echo
 * canceller only knows what WebRTC itself plays, so another app's audio on the
 * loudspeaker goes to the room. No Android types here, so it is unit-tested on
 * the JVM.
 */
internal object OtherAppAudioPolicy {
  // android.media.AudioAttributes values (stable public constants)
  private const val USAGE_UNKNOWN = 0
  private const val USAGE_MEDIA = 1
  private const val USAGE_ASSISTANCE_NAVIGATION_GUIDANCE = 12
  private const val USAGE_GAME = 14
  private const val USAGE_ASSISTANT = 16

  /**
   * Usages that carry sustained audible content from another app. Calls
   * (voice communication), ringtones, alarms, notifications and UI sounds are
   * left out: they are short, or the SDK's own call handling covers them.
   * USAGE_UNKNOWN is in because many games never set a usage.
   */
  private val audible = setOf(USAGE_UNKNOWN, USAGE_MEDIA, USAGE_ASSISTANCE_NAVIGATION_GUIDANCE, USAGE_GAME, USAGE_ASSISTANT)

  /**
   * One started player from AudioManager's playback configurations. The public
   * API gives no uid (configurations are anonymised for apps), only the
   * attributes and, on API 31+, the output device. [onSpeaker] false = routed
   * to a headset (not an acoustic leak); null = unknown (counted).
   */
  data class Player(val usage: Int, val contentType: Int, val onSpeaker: Boolean?)

  /**
   * How many started players are NOT the room's own playout and can be heard
   * by the microphone. [ownPlayout] = the attributes of WebRTC's running
   * playout track, or null when it is not playing; exactly one player with
   * those attributes is ours (another app with identical attributes still
   * counts).
   */
  fun foreignPlayers(players: List<Player>, ownPlayout: Player?): Int = foreignPlayers(players, listOfNotNull(ownPlayout))

  /**
   * Same, with every player of our own process that is running now: WebRTC's
   * playout and the SDK's keep-alive ([keepAlivePlayer]). Each entry is one
   * player of ours: it removes exactly one started player with the same usage
   * and content type (another app with identical attributes still counts).
   */
  fun foreignPlayers(players: List<Player>, own: List<Player>): Int {
    val ownLeft = own.toMutableList()
    var count = 0
    for (p in players) {
      val mine = ownLeft.indexOfFirst { it.usage == p.usage && it.contentType == p.contentType }
      if (mine >= 0) {
        ownLeft.removeAt(mine)
        continue
      }
      if (p.usage !in audible) continue
      if (p.onSpeaker == false) continue
      count++
    }
    return count
  }

  // android.media.AudioAttributes.CONTENT_TYPE_UNKNOWN
  private const val CONTENT_TYPE_UNKNOWN = 0

  /**
   * The SDK's silent keep-alive player (GxKeepAlivePlayer,
   * backgroundKeepAlive) with the session's [usage]; the keep-alive builds its
   * AudioAttributes from this, so both always agree.
   *
   * Why (merge 2026-10-11): in the media profile it is a USAGE_MEDIA player
   * that starts exactly when WebRTC's playout is not running (backgrounded,
   * no remote audio), so with only the playout excluded the other-app watcher
   * counted it as another app and muteMicInBackground muted the user. The
   * public playback configurations carry no uid or session id (they are
   * anonymised for apps), so it is told apart like the playout: by attributes.
   */
  fun keepAlivePlayer(usage: Int): Player = Player(usage, CONTENT_TYPE_UNKNOWN, true)

  /**
   * Reports "playing" after [onDelayMs] of continuous presence and "stopped"
   * after [offDelayMs] of continuous absence: a 300 ms game blip or a gap
   * between two videos must not toggle the capture (each toggle of the
   * VOICE_COMMUNICATION action restarts the recorder). Times are injected.
   */
  class Debouncer(private val onDelayMs: Long, private val offDelayMs: Long) {
    var state = false
      private set
    private var pendingSince: Long? = null

    /** Feeds the raw observation at [nowMs]; returns the debounced state. */
    fun update(raw: Boolean, nowMs: Long): Boolean {
      if (raw == state) {
        pendingSince = null
        return state
      }
      val since = pendingSince ?: nowMs.also { pendingSince = it }
      val delay = if (raw) onDelayMs else offDelayMs
      if (nowMs - since >= delay) {
        state = raw
        pendingSince = null
      }
      return state
    }

    /** Back to "stopped" with nothing pending (the watcher stopped). */
    fun reset() {
      state = false
      pendingSince = null
    }

    /** When a re-check is due (the pending change matures), or null. */
    fun nextCheckAt(): Long? = pendingSince?.let { it + if (state) offDelayMs else onDelayMs }
  }

  /** The capture action Dart asks for (GravixOtherAppCaptureAction.wire). */
  enum class Action {
    NONE,
    PLATFORM_EFFECTS,
    VOICE_COMMUNICATION,
    MUTE;

    companion object {
      fun parse(wire: String?): Action = when (wire) {
        "platformEffects" -> PLATFORM_EFFECTS
        "voiceCommunication" -> VOICE_COMMUNICATION
        "mute" -> MUTE
        else -> NONE
      }
    }
  }

  /**
   * The audio engine's microphone mute: the user's mute and the automatic
   * other-app mute are kept apart, so neither undoes the other.
   */
  fun engineMute(userMuted: Boolean, autoMuted: Boolean): Boolean = userMuted || autoMuted
}

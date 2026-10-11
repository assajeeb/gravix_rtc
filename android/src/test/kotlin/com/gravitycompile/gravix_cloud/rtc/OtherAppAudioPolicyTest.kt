package com.gravitycompile.gravix_cloud.rtc

import com.gravitycompile.gravix_cloud.rtc.OtherAppAudioPolicy.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Other-app audio (owner report 2026-10-10): YouTube / a game on the loudspeaker
// reaches the room through a MIC-source capture whose AEC3 reference is only
// WebRTC's own playout. Detection from the public playback configurations
// (no uid there: our own player is told apart by its attributes).
class OtherAppAudioPolicyTest {
  private val media = 1 // USAGE_MEDIA
  private val voiceComm = 2 // USAGE_VOICE_COMMUNICATION
  private val notification = 5
  private val sonification = 13
  private val game = 14
  private val unknownContent = 0
  private val music = 2
  private val movie = 3

  private fun p(usage: Int, content: Int = unknownContent, onSpeaker: Boolean? = true) = Player(usage, content, onSpeaker)

  @Test
  fun noPlayersNothing() {
    assertEquals(0, OtherAppAudioPolicy.foreignPlayers(emptyList(), null))
  }

  @Test
  fun youtubeAndAGameCount() {
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(p(media, movie)), null))
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(p(game)), null))
    // a game that leaves the usage unset
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(p(0)), null))
  }

  @Test
  fun ourOwnMediaPlayoutIsNotForeign() {
    val own = p(media, unknownContent)
    // media profile: our room playout is USAGE_MEDIA / CONTENT_TYPE_UNKNOWN
    assertEquals(0, OtherAppAudioPolicy.foreignPlayers(listOf(p(media, unknownContent)), own))
    // YouTube on top of it
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(p(media, unknownContent), p(media, movie)), own))
    // another app with exactly our attributes: two matching players, only one is ours
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(p(media, unknownContent), p(media, unknownContent)), own))
  }

  @Test
  fun ownPlayoutNotRunningRemovesNothing() {
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(p(media, music)), p(media, unknownContent)))
  }

  // Merge 2026-10-11 (backgroundKeepAlive + otherAppAudio): the SDK's silent
  // keep-alive is a USAGE_MEDIA / CONTENT_TYPE_UNKNOWN player in the media
  // profile and starts exactly when WebRTC's playout is not running, so with
  // only the playout excluded it read as "another app plays" in the background
  // (muteMicInBackground then muted the user). The public configurations carry
  // no uid or session id, so it is excluded like the playout: by attributes.
  @Test
  fun keepAlivePlayerIsOurs() {
    val keepAlive = OtherAppAudioPolicy.keepAlivePlayer(media)
    // without it in the own list: the false "another app" of the merged head
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(keepAlive), null))
    // backgrounded, no remote audio: only the keep-alive plays
    assertEquals(0, OtherAppAudioPolicy.foreignPlayers(listOf(keepAlive), listOf(keepAlive)))
    // YouTube on top of it still counts
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(keepAlive, p(media, movie)), listOf(keepAlive)))
    // a game with the keep-alive's attributes still counts: only one such player is ours
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(keepAlive, p(media, unknownContent)), listOf(keepAlive)))
  }

  @Test
  fun keepAliveAndWebRtcPlayoutTogether() {
    // both can run for a moment (a remote track subscribed while the keep-alive stops)
    val keepAlive = OtherAppAudioPolicy.keepAlivePlayer(media)
    val playout = p(media, unknownContent)
    assertEquals(0, OtherAppAudioPolicy.foreignPlayers(listOf(playout, keepAlive), listOf(playout, keepAlive)))
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(playout, keepAlive, p(game)), listOf(playout, keepAlive)))
    // an own entry whose player already stopped hides nothing else
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(p(media, music)), listOf(playout, keepAlive)))
  }

  @Test
  fun keepAliveInTheCommunicationProfileNeverCounts() {
    assertEquals(0, OtherAppAudioPolicy.foreignPlayers(listOf(OtherAppAudioPolicy.keepAlivePlayer(voiceComm)), emptyList()))
  }

  @Test
  fun callsNotificationsAndUiSoundsDoNotCount() {
    // communication profile: our playout is voice communication anyway
    assertEquals(0, OtherAppAudioPolicy.foreignPlayers(listOf(p(voiceComm), p(notification), p(sonification)), null))
  }

  @Test
  fun headsetRoutedPlaybackIsNotAnAcousticLeak() {
    assertEquals(0, OtherAppAudioPolicy.foreignPlayers(listOf(p(media, movie, onSpeaker = false)), null))
    // device unknown (API < 33): counted
    assertEquals(1, OtherAppAudioPolicy.foreignPlayers(listOf(p(media, movie, onSpeaker = null)), null))
  }

  @Test
  fun debounceOnNeedsContinuousPresence() {
    val d = OtherAppAudioPolicy.Debouncer(onDelayMs = 1000, offDelayMs = 2000)
    assertFalse(d.update(true, 0))
    assertEquals(1000L, d.nextCheckAt())
    // a 300 ms game blip: never reported
    assertFalse(d.update(false, 300))
    assertNull(d.nextCheckAt())
    assertFalse(d.update(true, 400))
    assertFalse(d.update(true, 1300))
    assertTrue(d.update(true, 1400))
    assertNull(d.nextCheckAt())
  }

  @Test
  fun debounceOffWaitsForAbsence() {
    val d = OtherAppAudioPolicy.Debouncer(onDelayMs = 1000, offDelayMs = 2000)
    d.update(true, 0)
    assertTrue(d.update(true, 1000))
    // a track change in a playlist: the player stops for a moment
    assertTrue(d.update(false, 5000))
    assertEquals(7000L, d.nextCheckAt())
    assertTrue(d.update(true, 5500))
    assertNull(d.nextCheckAt())
    assertTrue(d.update(false, 6000))
    assertTrue(d.update(false, 7999))
    assertFalse(d.update(false, 8000))
  }

  @Test
  fun resetDropsStateAndPending() {
    val d = OtherAppAudioPolicy.Debouncer(onDelayMs = 1000, offDelayMs = 2000)
    d.update(true, 0)
    assertTrue(d.update(true, 1000))
    d.update(false, 1500)
    d.reset()
    assertFalse(d.state)
    assertNull(d.nextCheckAt())
    // starts over: a new presence needs the full on-delay again
    assertFalse(d.update(true, 1600))
    assertTrue(d.update(true, 2600))
  }

  @Test
  fun zeroDelaysFollowAtOnce() {
    val d = OtherAppAudioPolicy.Debouncer(onDelayMs = 0, offDelayMs = 0)
    assertTrue(d.update(true, 0))
    assertFalse(d.update(false, 1))
  }

  @Test
  fun actionNames() {
    assertEquals(OtherAppAudioPolicy.Action.NONE, OtherAppAudioPolicy.Action.parse(null))
    assertEquals(OtherAppAudioPolicy.Action.NONE, OtherAppAudioPolicy.Action.parse("bogus"))
    assertEquals(OtherAppAudioPolicy.Action.PLATFORM_EFFECTS, OtherAppAudioPolicy.Action.parse("platformEffects"))
    assertEquals(OtherAppAudioPolicy.Action.VOICE_COMMUNICATION, OtherAppAudioPolicy.Action.parse("voiceCommunication"))
    assertEquals(OtherAppAudioPolicy.Action.MUTE, OtherAppAudioPolicy.Action.parse("mute"))
  }

  @Test
  fun engineMuteCombinesUserAndAutoMute() {
    assertFalse(OtherAppAudioPolicy.engineMute(userMuted = false, autoMuted = false))
    assertTrue(OtherAppAudioPolicy.engineMute(userMuted = true, autoMuted = false))
    assertTrue(OtherAppAudioPolicy.engineMute(userMuted = false, autoMuted = true))
    assertTrue(OtherAppAudioPolicy.engineMute(userMuted = true, autoMuted = true))
  }
}

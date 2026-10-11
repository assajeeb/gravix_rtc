package com.gravitycompile.gravix_cloud.rtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// 2026-10-10, interruption-sim run (emulator API 36, virtual HFP+A2DP headset):
// in MEDIA mode an A2DP-only headset connecting or disconnecting moved the
// media playout but emitted NO route-changed event (the only trigger was
// AudioSwitch's communication-device list, which an A2DP-only change does not
// touch), so onAudioRouteChanged went stale (current=bluetooth on the speaker).
class RouteChangeTrackerTest {
  private fun snap(current: String, vararg routes: String, reason: String = "") =
    mapOf("routes" to routes.toList(), "current" to current, "explicit" to null, "mode" to 0, "reason" to reason)

  @Test
  fun mediaModeOutputDeviceChangesAreWatched() {
    val t = RouteChangeTracker()
    // media mode (AudioSwitch does not route): the output-device callback is the trigger
    assertTrue(t.acceptsOutputDeviceChange(routingHandled = false))
    // communication mode: unchanged, AudioSwitch's own listener drives it
    assertFalse(t.acceptsOutputDeviceChange(routingHandled = true))
  }

  @Test
  fun a2dpConnectAndDisconnectEmitOnceEach() {
    val t = RouteChangeTracker()
    assertTrue(t.offer(snap("speaker", "speaker", reason = "sessionStart")))
    // A2DP headset connects: media moves to it
    assertTrue(t.offer(snap("bluetooth", "speaker", "bluetooth", reason = "deviceAdded")))
    // the late re-checks see the same route: no duplicate event
    assertFalse(t.offer(snap("bluetooth", "speaker", "bluetooth", reason = "deviceAdded(late)")))
    // the headset goes away: back to the speaker
    assertTrue(t.offer(snap("speaker", "speaker", reason = "deviceRemoved")))
    // wired headphones
    assertTrue(t.offer(snap("wiredHeadset", "speaker", "wiredHeadset", reason = "deviceAdded")))
  }

  @Test
  fun reasonAloneIsNotAChange() {
    val t = RouteChangeTracker()
    assertTrue(t.offer(snap("speaker", "speaker", reason = "a")))
    assertFalse(t.offer(snap("speaker", "speaker", reason = "b")))
  }

  // Phone run 2026-10-10 (Infinix, SpaceBuds, IB_bt_chatroom_f_media C3): on
  // the headset disconnect the SDK reported current=earpiece for 0.9 s while
  // available=[speaker] (the media routing had not settled), then speaker.
  @Test
  fun aCurrentRouteOutsideTheAvailableListIsNeverReported() {
    // the routing still says earpiece, the only output is the speaker: report the speaker
    assertEquals("speaker", AudioRoutePolicy.consistentCurrent("earpiece", listOf("speaker"), fallback = "speaker"))
    // a fallback that is not available either: the first available route
    assertEquals("speaker", AudioRoutePolicy.consistentCurrent("earpiece", listOf("speaker"), fallback = "bluetooth"))
    // consistent answers pass through
    assertEquals("bluetooth", AudioRoutePolicy.consistentCurrent("bluetooth", listOf("speaker", "bluetooth"), "speaker"))
    // nothing available: unknown
    assertEquals("unknown", AudioRoutePolicy.consistentCurrent("earpiece", emptyList(), fallback = "speaker"))
    // the tracker refuses an inconsistent snapshot outright (defence in depth)
    val t = RouteChangeTracker()
    assertFalse(t.offer(snap("earpiece", "speaker", reason = "chatroomMedia")))
    assertTrue(t.offer(snap("speaker", "speaker", reason = "deviceRemoved(late)")))
  }

  @Test
  fun lateRechecksCatchTheRoutingLag() {
    // getDevicesForAttributes lags the device-added callback: re-read later
    assertEquals(listOf(500L, 1500L), RouteChangeTracker.LATE_RECHECKS_MS)
  }
}

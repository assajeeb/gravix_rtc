package com.gravitycompile.gravix_cloud.rtc

import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.BLUETOOTH
import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.EARPIECE
import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.MODE_IN_CALL
import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.MODE_IN_COMMUNICATION
import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.MODE_NORMAL
import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.MODE_RINGTONE
import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.SPEAKER
import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.USB
import com.gravitycompile.gravix_cloud.rtc.AudioRoutePolicy.WIRED
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// 0.4.15 (field report 2026-10-10, items 7b/7c/7d).
class AudioRoutePolicyTest {
  @Test
  fun chatroomSwitchesOnlyAMediaModeAppWithMicOnAndABluetoothHeadset() {
    assertEquals(MODE_IN_COMMUNICATION, AudioRoutePolicy.chatroomMode(true, true, true, MODE_NORMAL))
    // mic off / listener: media mode (A2DP)
    assertEquals(MODE_NORMAL, AudioRoutePolicy.chatroomMode(true, false, true, MODE_NORMAL))
    // no headset: the phone's own microphone in media mode, as before
    assertEquals(MODE_NORMAL, AudioRoutePolicy.chatroomMode(true, true, false, MODE_NORMAL))
    // option off: exactly the old behaviour
    assertEquals(MODE_NORMAL, AudioRoutePolicy.chatroomMode(false, true, true, MODE_NORMAL))
    // a communication-mode app already gets the headset microphone
    assertEquals(MODE_IN_COMMUNICATION, AudioRoutePolicy.chatroomMode(true, false, true, MODE_IN_COMMUNICATION))
  }

  @Test
  fun deviceTypes() {
    assertEquals(SPEAKER, AudioRoutePolicy.routeOfDeviceType(2))
    assertEquals(EARPIECE, AudioRoutePolicy.routeOfDeviceType(1))
    assertEquals(WIRED, AudioRoutePolicy.routeOfDeviceType(3))
    assertEquals(WIRED, AudioRoutePolicy.routeOfDeviceType(4))
    assertEquals(BLUETOOTH, AudioRoutePolicy.routeOfDeviceType(7))
    assertEquals(BLUETOOTH, AudioRoutePolicy.routeOfDeviceType(8))
    assertEquals(BLUETOOTH, AudioRoutePolicy.routeOfDeviceType(26))
    assertEquals(USB, AudioRoutePolicy.routeOfDeviceType(22))
    // built-in mic (an input), telephony, remote submix: not routes
    assertNull(AudioRoutePolicy.routeOfDeviceType(15))
    assertNull(AudioRoutePolicy.routeOfDeviceType(18))
    assertNull(AudioRoutePolicy.routeOfDeviceType(25))
  }

  @Test
  fun focusAndCallModes() {
    assertEquals("gain", AudioRoutePolicy.focusName(1))
    assertEquals("loss", AudioRoutePolicy.focusName(-1))
    assertEquals("lossTransient", AudioRoutePolicy.focusName(-2))
    assertEquals("lossTransientCanDuck", AudioRoutePolicy.focusName(-3))
    assertTrue(AudioRoutePolicy.isPhoneCallMode(MODE_IN_CALL))
    assertFalse(AudioRoutePolicy.isPhoneCallMode(MODE_RINGTONE))
    assertFalse(AudioRoutePolicy.isPhoneCallMode(MODE_IN_COMMUNICATION))
  }

  @Test
  fun explicitOrderPutsTheChoiceFirstAndFallsBack() {
    assertNull(AudioRoutePolicy.explicitOrder(null))
    assertEquals(SPEAKER, AudioRoutePolicy.explicitOrder(SPEAKER)!!.first())
    assertEquals(listOf(EARPIECE, BLUETOOTH, WIRED, SPEAKER), AudioRoutePolicy.explicitOrder(EARPIECE))
    // speakerphone off: headsets first, then the earpiece over the loudspeaker
    assertEquals(listOf(BLUETOOTH, WIRED, EARPIECE, SPEAKER), AudioRoutePolicy.explicitOrder("speakerOff"))
    assertNull(AudioRoutePolicy.explicitOrder("nonsense"))
  }

  // Device run D3 (media build, 2026-10-10): `select speaker applied=false
  // current=speaker available=[speaker]`. Asking for the route already in use
  // is a no-op success, in media mode too.
  @Test
  fun selectingTheCurrentRouteIsAppliedInMediaMode() {
    assertTrue(AudioRoutePolicy.selectionApplied(SPEAKER, SPEAKER, routingHandled = false))
    assertTrue(AudioRoutePolicy.selectionApplied(BLUETOOTH, BLUETOOTH, routingHandled = false))
    assertTrue(AudioRoutePolicy.selectionApplied(USB, USB, routingHandled = false))
    // a route Android does not use for media cannot be selected there
    assertFalse(AudioRoutePolicy.selectionApplied(EARPIECE, SPEAKER, routingHandled = false))
    assertFalse(AudioRoutePolicy.selectionApplied(BLUETOOTH, SPEAKER, routingHandled = false))
    // speakerphone off with a headset in use: already off the loudspeaker
    assertTrue(AudioRoutePolicy.selectionApplied("speakerOff", BLUETOOTH, routingHandled = false))
    assertFalse(AudioRoutePolicy.selectionApplied("speakerOff", SPEAKER, routingHandled = false))
    assertTrue(AudioRoutePolicy.selectionApplied(null, SPEAKER, routingHandled = false))
  }

  @Test
  fun selectionInCommunicationModeNeedsTheRouteInUse() {
    assertTrue(AudioRoutePolicy.selectionApplied(SPEAKER, SPEAKER, routingHandled = true))
    // a missing headset fell back to the speaker: not applied
    assertFalse(AudioRoutePolicy.selectionApplied(BLUETOOTH, SPEAKER, routingHandled = true))
    // AudioSwitch reports a USB headset as wired
    assertTrue(AudioRoutePolicy.selectionApplied(USB, WIRED, routingHandled = true))
    assertTrue(AudioRoutePolicy.selectionApplied("speakerOff", EARPIECE, routingHandled = true))
    assertTrue(AudioRoutePolicy.selectionApplied("speakerOff", BLUETOOTH, routingHandled = true))
    // 2026-10-11 (route API nit): no route but the loudspeaker (no earpiece, no
    // headset) or an unknown one: speakerphone is NOT off -- it was "applied"
    assertFalse(AudioRoutePolicy.selectionApplied("speakerOff", SPEAKER, routingHandled = true))
    assertFalse(AudioRoutePolicy.selectionApplied("speakerOff", AudioRoutePolicy.UNKNOWN, routingHandled = true))
    assertFalse(AudioRoutePolicy.selectionApplied("speakerOff", null, routingHandled = true))
  }

  @Test
  fun mediaRouteWithoutPlatformAnswer() {
    assertEquals(SPEAKER, AudioRoutePolicy.mediaRouteOf(listOf(1, 2)))
    assertEquals(BLUETOOTH, AudioRoutePolicy.mediaRouteOf(listOf(2, 7, 8)))
    // an SCO-only headset does not carry media in MODE_NORMAL
    assertEquals(SPEAKER, AudioRoutePolicy.mediaRouteOf(listOf(2, 7)))
    assertEquals(WIRED, AudioRoutePolicy.mediaRouteOf(listOf(2, 3)))
  }
}

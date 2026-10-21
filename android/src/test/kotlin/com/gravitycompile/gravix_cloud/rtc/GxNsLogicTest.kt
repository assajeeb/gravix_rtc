package com.gravitycompile.gravix_cloud.rtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GxNsLogicTest {
  @Test
  fun frameShape() {
    assertEquals(48000, GxNsFrameShape.rateOf(480))
    assertEquals(16000, GxNsFrameShape.rateOf(160))
    assertEquals(44100, GxNsFrameShape.rateOf(441))
    assertNull(GxNsFrameShape.rateOf(512))
    assertNull(GxNsFrameShape.reject(480, 1920, direct = true, channels = 1))
    assertNull(GxNsFrameShape.reject(480, 1920, direct = true, channels = 0)) // initialize() not seen
    assertEquals("buffer_not_direct", GxNsFrameShape.reject(480, 1920, direct = false, channels = 1))
    assertEquals("channels_2", GxNsFrameShape.reject(480, 3840, direct = true, channels = 2))
    assertEquals("rate_51200", GxNsFrameShape.reject(512, 2048, direct = true, channels = 1))
    assertEquals("layout_cap3840_frames480", GxNsFrameShape.reject(480, 3840, direct = true, channels = 1))
  }

  @Test
  fun routes() {
    assertEquals("speaker", GxNsRoute.of(AudioRoutePolicy.SPEAKER, 3))
    assertEquals("earpiece", GxNsRoute.of(AudioRoutePolicy.EARPIECE, 3))
    assertEquals("wired", GxNsRoute.of(AudioRoutePolicy.WIRED, 0))
    assertEquals("usb", GxNsRoute.of(AudioRoutePolicy.USB, 3))
    assertEquals("bt-sco", GxNsRoute.of(AudioRoutePolicy.BLUETOOTH, AudioRoutePolicy.MODE_IN_COMMUNICATION))
    assertEquals("bt-sco", GxNsRoute.of(AudioRoutePolicy.BLUETOOTH, AudioRoutePolicy.MODE_IN_CALL))
    assertEquals("bt-a2dp", GxNsRoute.of(AudioRoutePolicy.BLUETOOTH, AudioRoutePolicy.MODE_NORMAL))
    assertEquals("unknown", GxNsRoute.of(null, null))
    assertTrue(GxNsRoute.isNarrowband("bt-sco"))
    assertFalse(GxNsRoute.isNarrowband("bt-a2dp"))
    assertTrue(GxNsRoute.isBluetooth("bt-a2dp"))
  }

  @Test
  fun watchdogTripsOnceOnThreeConsecutive() {
    val w = GxNsWatchdog(8_000_000L, 3)
    assertFalse(w.onFrame(9_000_000L))
    assertFalse(w.onFrame(9_000_000L))
    assertFalse(w.onFrame(1_000_000L)) // run broken
    assertFalse(w.onFrame(9_000_000L))
    assertFalse(w.onFrame(9_000_000L))
    assertTrue(w.onFrame(9_000_000L))
    assertFalse(w.onFrame(9_000_000L)) // only once
    assertTrue(w.tripped)
    w.rearm()
    assertFalse(w.tripped)
  }

  @Test
  fun fallback() {
    val off = GxNsNative.ENGINE_OFF
    val rnn = GxNsNative.ENGINE_RNNOISE
    val dfn = GxNsNative.ENGINE_DFN3
    fun d(req: Int, wd: Boolean = false, hot: Boolean = false, saver: Boolean = false, prefer: Boolean = false,
          route: String = "speaker", thermalFb: Boolean = true, saverFb: Boolean = true, slow: Boolean = false,
          suppress: Boolean = false) =
      GxNsFallback.decide(req, "r", wd, hot, saver, prefer, route, thermalFb, saverFb, slow, suppress)
    assertEquals(GxNsFallback.Decision(off, "r"), d(off, wd = true, hot = true))
    assertEquals(GxNsFallback.Decision(rnn, "r"), d(rnn, wd = true, hot = true, saver = true))
    assertEquals(GxNsFallback.Decision(dfn, "r"), d(dfn))
    assertEquals(GxNsFallback.Decision(rnn, "watchdog_frame"), d(dfn, wd = true, hot = true))
    assertEquals(GxNsFallback.Decision(rnn, "thermal"), d(dfn, hot = true, saver = true))
    assertEquals(GxNsFallback.Decision(rnn, "battery_saver"), d(dfn, saver = true))
    assertEquals(GxNsFallback.Decision(rnn, "studio_slow"), d(dfn, slow = true, hot = true))
    assertEquals(GxNsFallback.Decision(rnn, "watchdog_frame"), d(dfn, wd = true, slow = true))
    assertEquals(GxNsFallback.Decision(rnn, "r"), d(rnn, slow = true))
    assertEquals(GxNsFallback.Decision(rnn, "studio_suppress"), d(dfn, suppress = true, hot = true))
    assertEquals(GxNsFallback.Decision(rnn, "studio_slow"), d(dfn, slow = true, suppress = true))
    assertEquals(GxNsFallback.Decision(rnn, "r"), d(rnn, suppress = true))
    assertEquals(GxNsFallback.Decision(dfn, "r"), d(dfn, hot = true, thermalFb = false))
    assertEquals(GxNsFallback.Decision(dfn, "r"), d(dfn, saver = true, saverFb = false))
    assertEquals(GxNsFallback.Decision(off, "headset_ns"), d(rnn, prefer = true, route = "bt-sco"))
    assertEquals(GxNsFallback.Decision(rnn, "r"), d(rnn, prefer = true, route = "speaker"))
    assertEquals(GxNsFallback.Decision(rnn, "r"), d(rnn, prefer = false, route = "bt-sco"))
  }

  @Test
  fun logLineMatchesTheSharedFormat() {
    assertEquals("[GravixNS] install eng=rnnoise route=speaker rate=48000", gxNsLine("install", "rnnoise", "speaker", 48000))
    assertEquals(
      "[GravixNS] switch eng=rnnoise route=wired rate=48000 +0ms from=dfn3 to=rnnoise reason=watchdog",
      gxNsLine("switch", "rnnoise", "wired", 48000, 0, "from=dfn3 to=rnnoise reason=watchdog"),
    )
    assertEquals("[GravixNS] routeReset eng=rnnoise route=bt-le rate=?", gxNsLine("routeReset", "rnnoise", "bt-le", 0))
  }

  @Test
  fun ownAgcOffWithEngineOff() {
    // review #1: off / kill switch never stacks our AGC on WebRTC's
    assertFalse(GxNsAgc.ownOn(GxNsNative.ENGINE_OFF, "ownAfterNs"))
    assertFalse(GxNsAgc.ownOn(GxNsNative.ENGINE_OFF, null))
    assertFalse(GxNsAgc.ownOn(GxNsNative.ENGINE_RNNOISE, "webrtcBeforeNs"))
    assertTrue(GxNsAgc.ownOn(GxNsNative.ENGINE_RNNOISE, "ownAfterNs"))
    assertTrue(GxNsAgc.ownOn(GxNsNative.ENGINE_DFN3, null))
  }

  @Test
  fun inFlightRetire() {
    val f = GxNsInFlight()
    assertTrue(GxNsInFlight.idle(f.snapshot())) // no block: free at once
    f.enter()
    val s0 = f.snapshot()
    assertFalse(GxNsInFlight.idle(s0)) // a block is running: defer
    assertFalse(f.advancedSince(s0))
    f.exit()
    assertTrue(f.advancedSince(s0))
    assertTrue(GxNsInFlight.idle(f.snapshot()))
  }

  @Test
  fun packDownloadBounded() {
    val out = java.io.ByteArrayOutputStream()
    assertEquals(10L, gxNsCopyBounded(java.io.ByteArrayInputStream(ByteArray(10)), out, 10))
    assertEquals(10, out.size())
    val big = java.io.ByteArrayInputStream(ByteArray(200_000))
    assertEquals(-1L, gxNsCopyBounded(big, java.io.ByteArrayOutputStream(), 100_000))
    assertTrue(big.available() >= 200_000 - 100_001 - 1) // stopped at the limit, did not drain the stream
    assertTrue(gxNsPackUrlOk("https://cdn.example/x.ort"))
    assertFalse(gxNsPackUrlOk("http://cdn.example/x.ort"))
    assertFalse(gxNsPackUrlOk("file:///sdcard/x.ort"))
  }
}

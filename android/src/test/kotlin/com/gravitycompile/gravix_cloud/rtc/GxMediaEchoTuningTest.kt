package com.gravitycompile.gravix_cloud.rtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2026-10-10 ECHO: the media-profile echo experiments change WebRTC's audio
 * device module by reflection before the first room (the fields are private,
 * `audioSource` even final, and the module is built inside flutter_webrtc).
 * The fakes mirror the field names and kinds of the webrtc-sdk 150 classes.
 */
class GxMediaEchoTuningTest {
  // WebRtcAudioRecord: `private final int audioSource` set in the constructor,
  // `private volatile AudioRecord audioRecord` (null until capture starts).
  private class FakeRecord(source: Int) {
    private val audioSource: Int = source
    @Volatile private var audioRecord: Any? = null
    fun source() = audioSource
    fun startCapture() { audioRecord = Any() }
  }

  // WebRtcAudioTrack: `private boolean useLowLatency`, `private AudioTrack audioTrack`.
  private class FakeTrack(lowLatency: Boolean) {
    private var useLowLatency: Boolean = lowLatency
    private var audioTrack: Any? = null
    fun lowLatency() = useLowLatency
    fun startPlayout() { audioTrack = Any() }
  }

  // JavaAudioDeviceModule: public final fields audioInput / audioOutput.
  private class FakeAdm(@JvmField val audioInput: Any?, @JvmField val audioOutput: Any?)

  private val noTrials: (String) -> Unit = { throw AssertionError("field trials must not be touched") }

  @Test
  fun fieldTrialStringsAreCheckedLikeLibwebrtc() {
    assertTrue(GxMediaEchoTuning.fieldTrialsValid(""))
    assertTrue(GxMediaEchoTuning.fieldTrialsValid("A/B/"))
    assertTrue(GxMediaEchoTuning.fieldTrialsValid("A/B/C/D/"))
    assertTrue(GxMediaEchoTuning.fieldTrialsValid("A/B/A/B/"))
    assertFalse(GxMediaEchoTuning.fieldTrialsValid("A/B"))
    assertFalse(GxMediaEchoTuning.fieldTrialsValid("A"))
    assertFalse(GxMediaEchoTuning.fieldTrialsValid("/B/"))
    assertFalse(GxMediaEchoTuning.fieldTrialsValid("A//"))
    assertFalse(GxMediaEchoTuning.fieldTrialsValid("A/B/A/C/"))
  }

  @Test
  fun theWarpTrialIsKeptOnlyWhenAsked() {
    val aec = "WebRTC-Aec3TransparentModeHmm/Enabled/"
    assertEquals(aec, GxMediaEchoTuning.mergeFieldTrials(keepWarp = false, extra = aec))
    assertEquals(GxMediaEchoTuning.WARP_TRIAL + aec, GxMediaEchoTuning.mergeFieldTrials(keepWarp = true, extra = aec))
    // the extra string already carries it: not twice
    assertEquals(
      GxMediaEchoTuning.WARP_TRIAL + aec,
      GxMediaEchoTuning.mergeFieldTrials(keepWarp = true, extra = GxMediaEchoTuning.WARP_TRIAL + aec),
    )
  }

  @Test
  fun lowLatencyPlayoutIsSetBeforePlayoutStarts() {
    val track = FakeTrack(lowLatency = false)
    val report = GxMediaEchoTuning.apply(FakeAdm(FakeRecord(1), track), mapOf("lowLatencyPlayout" to true), noTrials)
    assertTrue(track.lowLatency())
    assertEquals("applied", report["lowLatencyPlayout"])
    assertEquals(false, report["lowLatencyPlayoutWas"])
  }

  @Test
  fun lowLatencyOnARunningPlayoutAppliesFromTheNextStart() {
    val track = FakeTrack(lowLatency = true).apply { startPlayout() }
    val report = GxMediaEchoTuning.apply(FakeAdm(FakeRecord(1), track), mapOf("lowLatencyPlayout" to false), noTrials)
    assertFalse(track.lowLatency())
    assertEquals("appliedFromNextPlayout", report["lowLatencyPlayout"])
  }

  @Test
  fun theCaptureSourceIsChangedEvenThoughTheFieldIsFinal() {
    val record = FakeRecord(7) // VOICE_COMMUNICATION, the non-bypass module's default
    val report = GxMediaEchoTuning.apply(FakeAdm(record, FakeTrack(true)), mapOf("captureSource" to "mic"), noTrials)
    assertEquals(1, record.source()) // MediaRecorder.AudioSource.MIC
    assertEquals("applied", report["captureSource"])
    assertEquals(7, report["captureSourceWas"])
  }

  @Test
  fun aRunningCaptureGetsTheNewSourceAtItsNextStart() {
    val record = FakeRecord(1).apply { startCapture() }
    val report = GxMediaEchoTuning.apply(
      FakeAdm(record, FakeTrack(true)),
      mapOf("captureSource" to "voiceCommunication"),
      noTrials,
    )
    assertEquals(7, record.source())
    assertEquals("appliedFromNextCapture", report["captureSource"])
  }

  @Test
  fun anUnknownCaptureSourceIsRefusedAndNothingChanges() {
    val record = FakeRecord(1)
    val report = GxMediaEchoTuning.apply(FakeAdm(record, FakeTrack(true)), mapOf("captureSource" to "camcorder"), noTrials)
    assertEquals(1, record.source())
    assertEquals("refused: unknown source camcorder", report["captureSource"])
  }

  @Test
  fun fieldTrialsGoThroughTheInitializer() {
    var set: String? = null
    val report = GxMediaEchoTuning.apply(
      FakeAdm(FakeRecord(1), FakeTrack(false)),
      mapOf("aec3FieldTrials" to "WebRTC-Aec3TransparentModeHmm/Enabled/", "keepWarpTrial" to true),
    ) { set = it }
    assertEquals(GxMediaEchoTuning.WARP_TRIAL + "WebRTC-Aec3TransparentModeHmm/Enabled/", set)
    assertEquals("applied", report["fieldTrials"])
  }

  @Test
  fun aMalformedTrialStringNeverReachesLibwebrtc() {
    val report = GxMediaEchoTuning.apply(
      FakeAdm(FakeRecord(1), FakeTrack(false)),
      mapOf("aec3FieldTrials" to "WebRTC-Aec3TransparentModeHmm"),
      noTrials,
    )
    assertEquals("refused: malformed field-trial string", report["fieldTrials"])
  }

  @Test
  fun nothingSetNothingTouched() {
    val record = FakeRecord(1)
    val track = FakeTrack(false)
    val report = GxMediaEchoTuning.apply(FakeAdm(record, track), emptyMap(), noTrials)
    assertEquals(1, record.source())
    assertFalse(track.lowLatency())
    assertNull(report["lowLatencyPlayout"])
    assertNull(report["captureSource"])
    assertNull(report["fieldTrials"])
  }

  @Test
  fun aModuleWithoutTheExpectedFieldsIsReportedNotThrown() {
    val report = GxMediaEchoTuning.apply(Any(), mapOf("lowLatencyPlayout" to true), noTrials)
    assertTrue((report["lowLatencyPlayout"] as String).startsWith("failed"))
  }
}

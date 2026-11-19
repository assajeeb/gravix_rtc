// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GxSingerSourceTest {
  @Test
  fun namesMapToAudioSources() {
    assertEquals(GxSingerSource.MIC, GxSingerSource.resolve("mic", 34, false))
    assertEquals(GxSingerSource.VOICE_RECOGNITION, GxSingerSource.resolve("voiceRecognition", 34, false))
    assertEquals(GxSingerSource.UNPROCESSED, GxSingerSource.resolve("unprocessed", 34, true))
  }

  @Test
  fun unprocessedFallsBackToVoiceRecognition() {
    assertEquals(GxSingerSource.VOICE_RECOGNITION, GxSingerSource.resolve("unprocessed", 34, false))
    assertEquals(GxSingerSource.VOICE_RECOGNITION, GxSingerSource.resolve("unprocessed", 23, true))
  }

  @Test
  fun keepAndUnknownLeaveTheSource() {
    assertNull(GxSingerSource.resolve("keep", 34, true))
    assertNull(GxSingerSource.resolve(null, 34, true))
    assertNull(GxSingerSource.resolve("camcorder", 34, true))
  }

  @Test
  fun constantsMatchMediaRecorder() {
    // MediaRecorder.AudioSource: MIC 1, VOICE_RECOGNITION 6, VOICE_COMMUNICATION 7, UNPROCESSED 9
    assertEquals(1, GxSingerSource.MIC)
    assertEquals(6, GxSingerSource.VOICE_RECOGNITION)
    assertEquals(7, GxSingerSource.VOICE_COMMUNICATION)
    assertEquals(9, GxSingerSource.UNPROCESSED)
  }
}

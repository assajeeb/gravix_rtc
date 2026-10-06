package com.gravitycompile.gravix_cloud.rtc

import com.gravitycompile.gravix_cloud.rtc.CallServiceTypes.CAMERA
import com.gravitycompile.gravix_cloud.rtc.CallServiceTypes.MEDIA_PLAYBACK
import com.gravitycompile.gravix_cloud.rtc.CallServiceTypes.MICROPHONE
import org.junit.Assert.assertEquals
import org.junit.Test

class CallServiceTypesTest {
  private fun compute(sdk: Int, mic: Boolean = false, micOk: Boolean = false, cam: Boolean = false, camOk: Boolean = false) =
    CallServiceTypes.compute(sdk, mic, micOk, cam, camOk)

  @Test
  fun listenerGetsMediaPlaybackOnly() {
    assertEquals(MEDIA_PLAYBACK, compute(34))
    // permission granted but nothing published: still no microphone type
    assertEquals(MEDIA_PLAYBACK, compute(34, mic = false, micOk = true))
  }

  @Test
  fun microphoneNeedsBothThePublishAndThePermission() {
    assertEquals(MEDIA_PLAYBACK or MICROPHONE, compute(34, mic = true, micOk = true))
    // RECORD_AUDIO not granted: the microphone type would be a SecurityException on 34
    assertEquals(MEDIA_PLAYBACK, compute(34, mic = true, micOk = false))
  }

  @Test
  fun cameraNeedsBothTheRequestAndThePermission() {
    assertEquals(MEDIA_PLAYBACK or CAMERA, compute(36, cam = true, camOk = true))
    assertEquals(MEDIA_PLAYBACK, compute(36, cam = true, camOk = false))
    assertEquals(MEDIA_PLAYBACK or MICROPHONE or CAMERA, compute(36, mic = true, micOk = true, cam = true, camOk = true))
  }

  @Test
  fun apiLevelGates() {
    // API 29: mediaPlayback exists, microphone/camera types do not
    assertEquals(MEDIA_PLAYBACK, compute(29, mic = true, micOk = true, cam = true, camOk = true))
    assertEquals(MEDIA_PLAYBACK or MICROPHONE, compute(30, mic = true, micOk = true))
    // below 29: an untyped service
    assertEquals(0, compute(28, mic = true, micOk = true))
    assertEquals(0, compute(24))
  }

  @Test
  fun namesForTheReport() {
    assertEquals(listOf("microphone", "mediaPlayback"), CallServiceTypes.names(MEDIA_PLAYBACK or MICROPHONE))
    assertEquals(listOf("mediaPlayback", "camera"), CallServiceTypes.names(MEDIA_PLAYBACK or CAMERA))
    assertEquals(emptyList<String>(), CallServiceTypes.names(0))
  }
}

package com.gravitycompile.gravix_cloud.rtc

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RealFftTest {
  private val n = 512

  private fun magnitudes(dst: FloatArray) = FloatArray(n / 2 + 1) { hypot(dst[2 * it], dst[2 * it + 1]) }

  @Test
  fun dcSignalLandsInBinZero() {
    val src = FloatArray(n) { 0.5f }
    val mags = magnitudes(RealFft(n).fft(src, FloatArray(n + 2)))
    assertEquals(0.5f * n, mags[0], 1e-2f)
    for (bin in 1..n / 2) assertTrue("bin $bin = ${mags[bin]}", mags[bin] < 1e-2f)
  }

  @Test
  fun singleToneLandsInItsBin() {
    val k = 37
    val src = FloatArray(n) { sin(2 * PI * k * it / n).toFloat() }
    val mags = magnitudes(RealFft(n).fft(src, FloatArray(n + 2)))
    assertEquals(n / 2f, mags[k], 1e-2f)
    for (bin in 0..n / 2) if (bin != k) assertTrue("bin $bin = ${mags[bin]}", mags[bin] < 1e-2f)
  }

  @Test
  fun reusableAcrossCalls() {
    val fft = RealFft(n)
    val silent = FloatArray(n)
    fft.fft(FloatArray(n) { 1f }, FloatArray(n + 2))
    val out = fft.fft(silent, FloatArray(n + 2))
    assertTrue(out.all { abs(it) < 1e-6f })
  }
}

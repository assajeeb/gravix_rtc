// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Radix-2 FFT of a real signal, dependency-free.
 *
 * [fft] returns the `n / 2 + 1` non-negative-frequency bins interleaved as
 * `[re0, im0, re1, im1, ...]` (length `n + 2`), the layout the visualizer
 * reads. `n` must be a power of two. Not thread-safe: one instance per analyzer.
 */
class RealFft(private val n: Int) {
  private val re = DoubleArray(n)
  private val im = DoubleArray(n)
  private val cosTable = DoubleArray(n / 2) { cos(2.0 * PI * it / n) }
  private val sinTable = DoubleArray(n / 2) { sin(2.0 * PI * it / n) }
  private val levels = Integer.numberOfTrailingZeros(n)

  init {
    require(n >= 2 && n and (n - 1) == 0) { "FFT size must be a power of two, was $n" }
  }

  fun fft(src: FloatArray, dst: FloatArray): FloatArray {
    require(src.size >= n) { "src holds ${src.size} samples, need $n" }
    require(dst.size >= n + 2) { "dst holds ${dst.size} floats, need ${n + 2}" }
    for (i in 0 until n) {
      val j = Integer.reverse(i) ushr (32 - levels)
      re[j] = src[i].toDouble()
      im[j] = 0.0
    }
    var size = 2
    while (size <= n) {
      val half = size / 2
      val step = n / size
      var start = 0
      while (start < n) {
        var k = 0
        for (j in start until start + half) {
          val l = j + half
          val tRe = re[l] * cosTable[k] + im[l] * sinTable[k]
          val tIm = -re[l] * sinTable[k] + im[l] * cosTable[k]
          re[l] = re[j] - tRe
          im[l] = im[j] - tIm
          re[j] += tRe
          im[j] += tIm
          k += step
        }
        start += size
      }
      size *= 2
    }
    for (bin in 0..n / 2) {
      dst[2 * bin] = re[bin].toFloat()
      dst[2 * bin + 1] = im[bin].toFloat()
    }
    return dst
  }
}

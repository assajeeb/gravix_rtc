# Vendored third-party C sources (gx_ns)

Both components are BSD-3-Clause. Their license texts are kept next to the
sources (`rnnoise/COPYING`, `speexdsp/COPYING`) and copied to the repo's
`LICENSES/` folder; see `NOTICE`.

## rnnoise/ — RNNoise 0.1.1 (Xiph.Org / Jean-Marc Valin)
- Upstream: https://github.com/xiph/rnnoise
- Tag `v0.1.1`, commit `6cbfd53eb348a8d394e0757b4025c6ded34eb2b6` (2024-04-10).
- Files: `include/rnnoise.h`, the library sources from upstream `src/compile.sh`
  (`denoise.c rnn.c rnn_data.c pitch.c kiss_fft.c celt_lpc.c`) and their headers,
  `COPYING`, `AUTHORS`. Not vendored: training code, `rnn_reader.c`
  (model-from-file; we only use the built-in model), autotools files.
- Weights: the built-in 0.1 model in `rnn_data.c`.
- Local patch (marked `GRAVIX PATCH`): `rnnoise_reset()` in `src/denoise.c` and
  its declaration in `include/rnnoise.h` — clears the state in place without
  allocating (upstream `rnnoise_init` callocs the GRU state).

### Why 0.1.1 and not 0.2 (measured 2026-10-21, NDK r28 clang -O2, gc-sections, stripped .so)
| ABI | 0.1.1 | 0.2 |
|---|---|---|
| arm64-v8a | 124,496 B | does not build (`vec_neon.h` includes a missing `os_support.h`) |
| armeabi-v7a (NEON) | 109,240 B | same build error |
| x86_64 | 131,512 B | 1,468,336 B |
The 0.2 weight tables alone are ~1.4 MB (arch-independent), over the
<= 1 MB per-ABI budget before the resampler, gx_ns core and JNI glue are added.
Note: the 0.2 release tarball's `rnnoise_data.c` differs from the
`rnnoise_data-0b50c45.tar.gz` that `download_model.sh` fetches for tag v0.2.
Irrelevant for 0.1.1; recorded so nobody chases it again.

## speexdsp/ — Speex resampler (Xiph.Org Foundation, Jean-Marc Valin)
- Upstream: https://github.com/xiph/speexdsp
- Tag `SpeexDSP-1.2.1`, commit `1b28a0f61bc31162979e1f26f3981fc3637095c8`.
- Files: `libspeexdsp/resample.c`, `resample_neon.h`, `resample_sse.h`,
  `arch.h`, `include/speex/speex_resampler.h` (placed flat), `COPYING`, `AUTHORS`.
  Unmodified.
- Build defines: `OUTSIDE_SPEEX FLOATING_POINT RANDOM_PREFIX=gx EXPORT=`
  (+ `USE_NEON` on arm64 / `USE_SSE` on x86 when wanted).

## Whole gx_ns library (RNNoise 0.1.1 + resampler + gx_ns core, no JNI), 2026-10-21
NDK r28 clang -O2 -std=gnu11, gc-sections, hidden visibility, stripped .so:
arm64-v8a (USE_NEON) 149,352 B; armeabi-v7a 129,204 B; x86_64 (USE_SSE) 158,480 B; x86 156,488 B.
The Android size gate (bundletool per ABI, with JNI glue) is still to be run by the integrator.

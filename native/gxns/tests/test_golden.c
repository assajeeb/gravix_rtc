/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Golden vectors: tests/fixtures/rnnoise_v011_golden_48k.pcm was produced by
 * UNMODIFIED upstream rnnoise v0.1.1 examples/rnnoise_demo.c (see
 * tools/gen_fixture_input.py). Same host + same compiler family, so the
 * vendored copy must match to within 1 LSB (float->short truncation). */
#include <string.h>
#include "gx_ns.h"
#include "rnnoise.h"
#include "test_util.h"

#define F 480

int main(void) {
  float *in, *gold;
  int n = read_pcm(GXNS_FIXTURES "/noisy_speechlike_48k.pcm", &in);
  int ng = read_pcm(GXNS_FIXTURES "/rnnoise_v011_golden_48k.pcm", &gold);
  int i, j, maxd = 0;
  CHECK(ng == n - F, "golden length %d vs %d", ng, n - F);

  /* 1. vendored RNNoise, driven exactly like rnnoise_demo */
  {
    DenoiseState *st = rnnoise_create(NULL);
    float x[F];
    int frame = 0;
    for (i = 0; i + F <= n; i += F, frame++) {
      memcpy(x, in + i, sizeof(x));
      rnnoise_process_frame(st, x, x);
      if (frame == 0) continue; /* the demo drops the first (delay) frame */
      for (j = 0; j < F; j++) {
        int d = abs((short)x[j] - (int)gold[i - F + j]);
        if (d > maxd) maxd = d;
      }
    }
    CHECK(maxd <= 1, "vendored rnnoise vs upstream golden: max diff %d LSB", maxd);
    printf("vendored rnnoise vs upstream golden: max diff %d LSB over %d samples\n", maxd, ng);

    /* rnnoise_reset (GRAVIX PATCH) == fresh state */
    rnnoise_reset(st);
    maxd = 0;
    for (i = 0, frame = 0; i + F <= n; i += F, frame++) {
      memcpy(x, in + i, sizeof(x));
      rnnoise_process_frame(st, x, x);
      if (frame == 0) continue;
      for (j = 0; j < F; j++) {
        int d = abs((short)x[j] - (int)gold[i - F + j]);
        if (d > maxd) maxd = d;
      }
    }
    CHECK(maxd <= 1, "after rnnoise_reset: max diff %d", maxd);
    rnnoise_destroy(st);
  }

  /* 2. through gx_ns at 48 kHz / 10 ms frames, AGC off: golden delayed by the
   *    reported latency (= RNNoise's own 480 samples, no FIFO latency). */
  {
    gx_ns_config c;
    struct gx_ns *st;
    float *y = malloc(sizeof(float) * n);
    int lat, skip = 3 * F; /* the first 20 ms are the start-up fade-in */
    gx_ns_default_config(&c);
    c.agc_enabled = 0;
    st = gx_ns_create(&c);
    memcpy(y, in, sizeof(float) * n);
    run_frames(st, y, n, F, 48000);
    lat = gx_ns_latency_samples(st, 48000);
    CHECK(lat == GX_NS_RNNOISE_LATENCY, "latency %d", lat);
    maxd = 0;
    for (i = skip; i < ng; i++) {
      int d = abs((short)y[i + lat] - (int)gold[i]);
      if (d > maxd) maxd = d;
    }
    CHECK(maxd <= 1, "gx_ns(48k) vs golden: max diff %d", maxd);
    printf("gx_ns 48k/480 vs upstream golden: max diff %d LSB, latency %d samples\n", maxd, lat);
    /* RNNoise really removed noise: the pause (0.9..1.2 s) is much quieter */
    {
      double din = rms_db(in + 46080, 9600), dout = rms_db(y + 46080 + lat, 9600);
      CHECK(dout < din - 15, "noise in pause: in %.1f dB out %.1f dB", din, dout);
    }
    free(y);
    gx_ns_destroy(st);
  }
  free(in); free(gold);
  return TEST_DONE();
}

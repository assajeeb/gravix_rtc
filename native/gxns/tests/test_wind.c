/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Wind / air on the mic (2026-10-21, a fan blowing at a phone): low-frequency,
 * gusty, no pitch. It must never get our pre-gain / AGC lift, so the output
 * stays DTX-quiet; a deep male voice (F0 ~95 Hz, most of its energy low too)
 * keeps counting as talk and reaches the AGC target. RNNoise already removes
 * such wind (also gentler slopes, faster gusts and clipped gusts: < -75 dBFS
 * out), so the core has no separate wind detector; this pins that. Synthetic:
 * the real room recording stays off the repository. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000

static uint32_t rng;
static double urand(void) { rng = rng * 1664525u + 1013904223u; return ((rng >> 8) & 0xFFFFFF) / 16777216.0; }

/* gusts of sub-150 Hz noise: brown noise, two one-pole low-passes, gust envelope */
static void gen_wind(float *x, int n, double dbfs, unsigned seed) {
  double b = 0, l1 = 0, l2 = 0, hp = 0, acc = 0, g, env = 0, target = 0.3;
  const double a = 1 - exp(-2 * M_PI * 150.0 / SR);
  int i, next = 0;
  rng = seed * 2654435761u + 3;
  for (i = 0; i < n; i++) {
    double v;
    if (i >= next) { target = 0.15 + urand() * 1.6; next = i + (int)((0.15 + urand() * 0.6) * SR); } /* a new gust */
    env += (target - env) * (1.0 / (0.08 * SR));
    b += urand() - 0.5;
    hp += (b - hp) * (1.0 / (0.05 * SR)); /* remove the walk's drift (< ~3 Hz) */
    v = b - hp;
    l1 += a * (v - l1);
    l2 += a * (l1 - l2);
    x[i] = (float)(l2 * env);
    acc += (double)x[i] * x[i];
  }
  g = 32768.0 * pow(10, dbfs / 20.0) / sqrt(acc / n);
  for (i = 0; i < n; i++) x[i] *= (float)g;
}

/* a deep male voice: F0 90-100 Hz, harmonics to 4 kHz falling 9 dB/octave-ish,
 * syllables at 4 Hz, a pause every 3 s */
static void gen_male(float *x, int n, double dbfs) {
  double acc = 0, g, ph[45] = {0};
  int i, k, cnt = 0;
  for (i = 0; i < n; i++) {
    double t = (double)i / SR, f0 = 95 + 5 * sin(2 * M_PI * 0.7 * t), e = sin(2 * M_PI * 2.0 * t), v = 0;
    e = (e < 0 || fmod(t, 3.0) > 2.4) ? 0 : sqrt(e);
    for (k = 1; k <= 42; k++) {
      ph[k] += 2 * M_PI * f0 * k / SR;
      v += sin(ph[k]) / pow(k, 1.4);
    }
    x[i] = (float)(v * e);
    if (e > 0.05) { acc += (double)x[i] * x[i]; cnt++; }
  }
  g = 32768.0 * pow(10, dbfs / 20.0) / sqrt(acc / cnt);
  for (i = 0; i < n; i++) x[i] *= (float)g;
}

static struct gx_ns *mk(void) {
  gx_ns_config c;
  gx_ns_default_config(&c);
  return gx_ns_create(&c);
}

int main(void) {
  const double levels[] = {-45, -38, -30};
  int len = SR * 10, li, i;
  float *x = malloc(sizeof(float) * len), *ref = malloc(sizeof(float) * len);
  gx_ns_status s;
  for (li = 0; li < 3; li++) {
    struct gx_ns *st = mk();
    double out, in;
    gen_wind(x, len, levels[li], 7 + li);
    in = rms_db(x + SR * 2, len - SR * 2);
    run_frames(st, x, len, F, SR);
    out = rms_db(x + SR * 2, len - SR * 2);
    gx_ns_get_status(st, &s);
    printf("wind %5.1f dBFS (in %.1f) -> out %6.1f dBFS (pregain %+.1f agc %+.1f)\n", levels[li], in, out, s.pregain_db, s.agc_gain_db);
    CHECK(out < -45.0, "wind %.0f dBFS: out %.1f dBFS (lifted)", levels[li], out);
    CHECK(s.pregain_db <= 1.0f && s.agc_gain_db <= 1.0f, "wind %.0f dBFS: gains learnt %.1f / %.1f", levels[li], s.pregain_db, s.agc_gain_db);
    gx_ns_destroy(st);
  }
  /* a deep male voice at a quiet -40 dBFS: still talk, lifted to the AGC target */
  {
    struct gx_ns *st = mk();
    double out;
    int L;
    gen_male(x, len, -40);
    memcpy(ref, x, sizeof(float) * len);
    run_frames(st, x, len, F, SR);
    L = gx_ns_latency_samples(st, SR);
    out = active_rms_db(x + len - SR * 3 + L, ref + len - SR * 3, SR * 3 - L, F);
    gx_ns_get_status(st, &s);
    printf("male voice -40 dBFS -> %.1f dBFS (pregain %+.1f agc %+.1f)\n", out, s.pregain_db, s.agc_gain_db);
    CHECK(out > -18.0, "deep male voice only %.1f dBFS (not counted as talk?)", out);
    gx_ns_destroy(st);
  }
  (void)i;
  free(x); free(ref);
  return TEST_DONE();
}

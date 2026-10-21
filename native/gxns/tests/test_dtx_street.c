/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* DTX on real-world noise (2026-10-21): swelling traffic noise (passing cars
 * over a low rumble) and street noise (faster swells, more tyre hiss) fooled
 * the pause gate of 70ddcb00: RNNoise's VAD calls them speech (~100% of
 * blocks), so pre-gain (+14) and AGC (+24) lifted -45 dBFS traffic to -20 dBFS
 * and Opus DTX never engaged. Noise alone must stay under -50 dBFS; speech
 * over that noise still gets its gains.
 *
 * The noises are generated as in the NS evaluation clips (traffic_snr*.wav of
 * the 2026-10-21 DPDFNet spike, also synthetic): brown-noise rumble low-passed
 * at 250 Hz plus band-passed tyre hiss (800-6000 Hz), times an envelope of
 * Gaussian swells (passing vehicles). Deterministic, no fixture file. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000
#define LIMIT_DB (-50.0)

typedef struct { double b0, b1, b2, a1, a2, z1, z2; } bq;
static void bq_lp(bq *f, double fc) {
  double w = 2 * M_PI * fc / SR, c = cos(w), al = sin(w) / (2 * 0.7071), a0 = 1 + al;
  f->b0 = (1 - c) / 2 / a0; f->b1 = (1 - c) / a0; f->b2 = f->b0; f->a1 = -2 * c / a0; f->a2 = (1 - al) / a0; f->z1 = f->z2 = 0;
}
static void bq_hp(bq *f, double fc) {
  double w = 2 * M_PI * fc / SR, c = cos(w), al = sin(w) / (2 * 0.7071), a0 = 1 + al;
  f->b0 = (1 + c) / 2 / a0; f->b1 = -(1 + c) / a0; f->b2 = f->b0; f->a1 = -2 * c / a0; f->a2 = (1 - al) / a0; f->z1 = f->z2 = 0;
}
static double bq_run(bq *f, double x) {
  double y = f->b0 * x + f->z1;
  f->z1 = f->b1 * x - f->a1 * y + f->z2;
  f->z2 = f->b2 * x - f->a2 * y;
  return y;
}

static uint32_t rng;
static double urand(void) { rng = rng * 1664525u + 1013904223u; return ((rng >> 8) & 0xFFFFFF) / 16777216.0; }
static double nrand(void) { double u = urand() + 1e-12, v = urand(); return sqrt(-2 * log(u)) * cos(2 * M_PI * v); }

/* traffic: swells = number of passing vehicles, sigma = swell width (s),
 * hiss = tyre hiss relative to the rumble */
static void gen_traffic(float *x, int n, double dbfs, unsigned seed, int swells, double sigma, double base, double hiss) {
  bq lp, hp, h1, h2;
  double br = 0, acc = 0, ra = 0, ha = 0, g, *c = malloc(sizeof(double) * swells), *r = malloc(sizeof(double) * n), *h = malloc(sizeof(double) * n);
  int i, k;
  rng = seed * 2654435761u + 7;
  bq_lp(&lp, 250); bq_hp(&hp, 5); bq_hp(&h1, 800); bq_lp(&h2, 6000);
  for (k = 0; k < swells; k++) c[k] = urand() * n / SR;
  for (i = 0; i < n; i++) {
    br += nrand();
    r[i] = bq_run(&lp, bq_run(&hp, br));
    h[i] = bq_run(&h2, bq_run(&h1, nrand()));
    ra += r[i] * r[i]; ha += h[i] * h[i];
  }
  ra = sqrt(ra / n); ha = sqrt(ha / n);
  for (i = 0; i < n; i++) {
    double t = (double)i / SR, env = base, v;
    for (k = 0; k < swells; k++) env += 1.6 * exp(-(t - c[k]) * (t - c[k]) / (2 * sigma * sigma));
    v = (r[i] / ra + hiss * h[i] / ha) * env;
    x[i] = (float)v; acc += v * v;
  }
  g = 32768.0 * pow(10, dbfs / 20.0) / sqrt(acc / n);
  for (i = 0; i < n; i++) x[i] *= (float)g;
  free(c); free(r); free(h);
}

static struct gx_ns *mk(void) {
  gx_ns_config c;
  gx_ns_default_config(&c); /* RNNoise, pre-gain on, AGC on, after NS */
  return gx_ns_create(&c);
}

int main(void) {
  const char *names[2] = {"traffic", "street"};
  const double levels[] = {-65, -55, -50, -45, -40};
  int len = SR * 10, ni, li, i;
  float *x = malloc(sizeof(float) * len), *sp = malloc(sizeof(float) * len), *y = malloc(sizeof(float) * len);
  gx_ns_status s;
  for (ni = 0; ni < 2; ni++) {
    /* noise alone: under the DTX threshold (the first 2 s skipped: the NS settles) */
    for (li = 0; li < 5; li++) {
      struct gx_ns *st = mk();
      double out;
      if (ni == 0) gen_traffic(x, len, levels[li], 5 + li, 5, 0.9, 0.4, 0.3);
      else gen_traffic(x, len, levels[li], 50 + li, 14, 0.4, 0.8, 0.8);
      run_frames(st, x, len, F, SR);
      out = rms_db(x + SR * 2, len - SR * 2);
      gx_ns_get_status(st, &s);
      printf("%-7s noise %5.1f dBFS -> out %6.1f dBFS (pregain %+.1f agc %+.1f)\n", names[ni], levels[li], out, s.pregain_db, s.agc_gain_db);
      /* street noise at -40 dBFS (a loud kerb) is partly kept by RNNoise as
       * voice-like: there only "no gain of ours on top" is asserted */
      if (ni == 1 && levels[li] > -45) CHECK(s.pregain_db <= 1.0f && out < -45.0, "street %.0f dBFS: out %.1f pregain %.1f", levels[li], out, s.pregain_db);
      else CHECK(out < LIMIT_DB, "%s noise %.0f dBFS: out %.1f dBFS >= %.0f (DTX would not engage)", names[ni], levels[li], out, LIMIT_DB);
      gx_ns_destroy(st);
    }
    /* quiet speech over that noise (SNR 10 dB): still lifted toward the AGC target */
    {
      struct gx_ns *st = mk();
      double out;
      if (ni == 0) gen_traffic(x, len, -55, 9, 5, 0.9, 0.4, 0.3);
      else gen_traffic(x, len, -55, 59, 14, 0.4, 0.8, 0.8);
      gen_speechlike(sp, len, SR, -45);
      for (i = 0; i < len; i++) { x[i] += sp[i]; y[i] = sp[i]; }
      run_frames(st, x, len, F, SR);
      out = active_rms_db(x + len - SR * 4 + gx_ns_latency_samples(st, SR), y + len - SR * 4, SR * 4 - gx_ns_latency_samples(st, SR), F);
      gx_ns_get_status(st, &s);
      printf("%-7s -45 dBFS speech over -55 dBFS noise -> %6.1f dBFS (pregain %+.1f agc %+.1f)\n", names[ni], out, s.pregain_db, s.agc_gain_db);
      CHECK(out > -24.0, "%s: speech over noise only %.1f dBFS (gains lost)", names[ni], out);
      gx_ns_destroy(st);
    }
  }
  free(x); free(sp); free(y);
  return TEST_DONE();
}

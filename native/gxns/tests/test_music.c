/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Auto music (2026-11-20, field report: a guest's song from a speaker into the
 * mic was gated 15-25 dB between notes).
 *   1. synthetic music (chords + melody + bass, piano-like decays) is detected
 *      within 6 s and the chain stops cutting it;
 *   2. it leaves within ~4 s once the music stops;
 *   3. speech-like bursts, a babble of five of them, white noise, a mains buzz
 *      and traffic never trigger it, and the output is then bit-identical to
 *      auto music off;
 *   4. music bypass (room music / singer mode) rests the detector.
 * Tuned on real recordings (Infinix / Redmi capdumps of a song from a speaker,
 * TTS speech, babble, fan, TV) with tools/gxns_replay --music. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000

static unsigned rng = 1;
static double urand(void) { rng = rng * 1664525u + 1013904223u; return (rng >> 8) / 16777216.0; }

static void scale_to(float *x, int n, double dbfs) {
  double acc = 0, g;
  int i;
  for (i = 0; i < n; i++) acc += (double)x[i] * x[i];
  if (acc <= 0) return;
  g = 32768.0 * pow(10, dbfs / 20.0) / sqrt(acc / n);
  for (i = 0; i < n; i++) x[i] *= (float)g;
}

/* one struck note: 8 harmonics, exponential decay */
static void add_pluck(float *x, int n, int start, double f0, double amp, double tau) {
  int i, k, len = (int)(SR * tau * 4);
  for (i = 0; i < len && start + i < n; i++) {
    double t = (double)i / SR, e = amp * exp(-t / tau) * (i < 96 ? i / 96.0 : 1.0), s = 0;
    for (k = 1; k <= 8; k++) {
      if (f0 * k > SR / 2.5) break;
      s += sin(2 * M_PI * f0 * k * t + k) / (k * k * 0.5 + 0.5);
    }
    x[start + i] += (float)(e * s);
  }
}

/* chords every 1 s (I-V-vi-IV), a melody note every 250 ms, a bass note per chord */
static void gen_music(float *x, int n, double dbfs, unsigned seed) {
  static const double roots[4] = {261.63, 392.00, 440.00, 349.23};
  static const int third[4] = {4, 4, 3, 4};
  int c, m;
  rng = seed;
  memset(x, 0, sizeof(float) * (size_t)n);
  for (c = 0; c * SR < n; c++) {
    double r = roots[c % 4];
    add_pluck(x, n, c * SR, r, 0.5, 0.9);
    add_pluck(x, n, c * SR, r * pow(2, third[c % 4] / 12.0), 0.4, 0.9);
    add_pluck(x, n, c * SR, r * 1.5, 0.4, 0.9);
    add_pluck(x, n, c * SR, r / 4, 0.8, 0.7);
    for (m = 0; m < 4; m++) {
      static const int steps[8] = {0, 2, 4, 7, 9, 12, 7, 4};
      add_pluck(x, n, c * SR + m * SR / 4, r * 2 * pow(2, steps[(int)(urand() * 8)] / 12.0), 0.35, 0.4);
    }
  }
  scale_to(x, n, dbfs);
}

/* 100 Hz mains buzz (20 harmonics) */
static void gen_buzz(float *x, int n, double dbfs) {
  int i, h;
  for (i = 0; i < n; i++) {
    double t = (double)i / SR, v = 0;
    for (h = 1; h <= 20; h++) v += sin(2 * M_PI * 100.0 * h * t + h) / h;
    x[i] = (float)v;
  }
  scale_to(x, n, dbfs);
}

/* low-passed noise with slow swells (passing cars) */
static void gen_traffic(float *x, int n, double dbfs, unsigned seed) {
  int i;
  double lp = 0;
  gen_noise(x, n, 1.0, seed);
  for (i = 0; i < n; i++) {
    double t = (double)i / SR;
    lp += 0.05 * (x[i] - lp);
    x[i] = (float)(lp * (1.0 + 0.8 * sin(2 * M_PI * 0.15 * t) + 0.4 * sin(2 * M_PI * 0.41 * t)));
  }
  scale_to(x, n, dbfs);
}

/* one talker: its own voice pitch with intonation (1-4 Hz, +-15%), syllables
 * at ~5 Hz with a pause every few words, a vowel colour per syllable
 * (formant-like harmonic weights). Five of them = a babble. (A babble of
 * gen_speechlike copies is five people humming one slow glide: that is
 * sustained notes, and may count as music.) */
static void gen_talker(float *x, int n, double dbfs, unsigned seed) {
  int i, k, syl = -1;
  double f0b, ph = 0, w[12] = {0}, a1, a2, p1, p2, env = 0, next = 0, on = 1;
  rng = seed * 2654435761u + 3;
  f0b = 100 + 120 * urand();
  a1 = 1.3 + urand(); a2 = 2.5 + 1.2 * urand(); p1 = 6.28 * urand(); p2 = 6.28 * urand();
  for (i = 0; i < n; i++) {
    double t = (double)i / SR, f0 = f0b * (1 + 0.08 * sin(2 * M_PI * a1 * t + p1) + 0.07 * sin(2 * M_PI * a2 * t + p2)), v = 0, target;
    if (t >= next) { /* a new syllable (or a pause) */
      syl++;
      on = (syl % (3 + (int)(urand() * 4)) == 0 && urand() < 0.6) ? 0 : 1;
      next = t + (on ? 0.12 + 0.12 * urand() : 0.15 + 0.3 * urand());
      for (k = 0; k < 12; k++) w[k] = (0.2 + urand()) / (k + 1);
    }
    target = on ? 1.0 : 0.0;
    env += (target - env) * (target > env ? 0.004 : 0.002);
    ph += 2 * M_PI * f0 / SR;
    for (k = 0; k < 12; k++) {
      if (f0 * (k + 1) > SR / 2.2) break;
      v += w[k] * sin((k + 1) * ph);
    }
    x[i] = (float)(v * env * (0.6 + 0.4 * sin(2 * M_PI * 5.0 * (t - next))));
  }
  scale_to(x, n, dbfs);
}

static struct gx_ns *mk(int music) {
  gx_ns_config c;
  gx_ns_default_config(&c);
  c.auto_music = music;
  return gx_ns_create(&c);
}

/* runs x in 10 ms frames; returns the share of blocks with music detected,
 * first / last detected block in *first / *last (-1 = none) */
static double run(struct gx_ns *st, float *x, int n, int *first, int *last) {
  int i, b = 0, on = 0;
  gx_ns_status s;
  *first = *last = -1;
  for (i = 0; i + F <= n; i += F, b++) {
    gx_ns_process(st, x + i, F, SR);
    gx_ns_get_status(st, &s);
    if (s.music_detected) { on++; if (*first < 0) *first = b; *last = b; }
  }
  return (double)on / b;
}

/* share of 50 ms frames from `from` (s) where y (latency-aligned) is > 10 dB under x */
static double cut_share(const float *x, const float *y, int n, int lat, double from) {
  int fr = SR / 20, k, m = 0, c = 0;
  for (k = (int)(from * SR); k + fr + lat <= n; k += fr) {
    double a = rms_db(x + k, fr), b = rms_db(y + k + lat, fr);
    if (a < -60) continue;
    m++; c += b < a - 10;
  }
  return m ? (double)c / m : 0;
}

static void never(const char *name, float *x, int n) {
  float *a = malloc(sizeof(float) * (size_t)n), *b = malloc(sizeof(float) * (size_t)n);
  struct gx_ns *s0 = mk(0), *s1 = mk(1);
  int f, l;
  double share;
  memcpy(a, x, sizeof(float) * (size_t)n);
  memcpy(b, x, sizeof(float) * (size_t)n);
  run(s0, a, n, &f, &l);
  share = run(s1, b, n, &f, &l);
  CHECK(share == 0.0, "%s: never music (%.0f%% of blocks, first at %.2f s)", name, 100 * share, f / 100.0);
  CHECK(!memcmp(a, b, sizeof(float) * (size_t)n), "%s: output bit-identical to auto music off", name);
  gx_ns_destroy(s0); gx_ns_destroy(s1);
  free(a); free(b);
}

int main(void) {
  const int n = SR * 20;
  float *x = malloc(sizeof(float) * (size_t)n), *y = malloc(sizeof(float) * (size_t)n), *z = malloc(sizeof(float) * (size_t)n);
  int f, l, i;

  /* 1. music is detected, and the chain stops cutting it */
  {
    struct gx_ns *s0 = mk(0), *s1 = mk(1);
    double share, c0, c1;
    float *bed = malloc(sizeof(float) * (size_t)n);
    gen_music(x, n, -26, 3);
    gen_noise(bed, n, 1.0, 11); scale_to(bed, n, -62); /* a quiet room under it */
    for (i = 0; i < n; i++) x[i] += bed[i];
    memcpy(y, x, sizeof(float) * (size_t)n);
    memcpy(z, x, sizeof(float) * (size_t)n);
    run(s0, y, n, &f, &l);
    share = run(s1, z, n, &f, &l);
    CHECK(f >= 0 && f <= 600, "music detected within 6 s (first at %.2f s)", f / 100.0);
    CHECK(share > 0.6, "music detected most of the time (%.0f%%)", 100 * share);
    c0 = cut_share(x, y, n, gx_ns_latency_samples(s0, SR), 7.0);
    c1 = cut_share(x, z, n, gx_ns_latency_samples(s1, SR), 7.0);
    printf("music: first %.2f s, on %.0f%%, frames cut >10 dB after 7 s: off %.1f%% on %.1f%%\n", f / 100.0, 100 * share, 100 * c0, 100 * c1);
    CHECK(c1 <= 0.02, "music mode: almost nothing cut > 10 dB (%.1f%%)", 100 * c1);
    CHECK(c1 <= c0, "never cuts more than without it (%.1f%% vs %.1f%%)", 100 * c1, 100 * c0);
    gx_ns_destroy(s0); gx_ns_destroy(s1);
    free(bed);
  }

  /* 2. leaves once the music stops (12 s music, then 8 s of speech-like bursts) */
  {
    struct gx_ns *s1 = mk(1);
    gen_music(x, SR * 12, -26, 5);
    gen_speechlike(x + SR * 12, n - SR * 12, SR, -26);
    run(s1, x, n, &f, &l);
    CHECK(f >= 0, "music detected");
    CHECK(l >= 0 && l < 1200 + 450, "music left within 4.5 s of its end (last at %.2f s)", l / 100.0);
    gx_ns_destroy(s1);
  }

  /* 2b. a new capture stream starts over: reset right after detection clears it
   * at once (not 3 s later), then the music is found again */
  {
    struct gx_ns *s1 = mk(1);
    gx_ns_status s;
    gen_music(x, n, -26, 7);
    run(s1, x, SR * 10, &f, &l);
    CHECK(f >= 0, "music detected before the reset");
    gx_ns_reset_music(s1);
    gx_ns_process(s1, x + SR * 10, F, SR);
    gx_ns_get_status(s1, &s);
    CHECK(!s.music_detected, "reset_music: not detected on the next block");
    run(s1, x + SR * 10 + F, SR * 9, &f, &l);
    CHECK(f >= 0 && f <= 600, "found again after the reset (at %.2f s)", f / 100.0);
    gx_ns_request_reset(s1);
    gx_ns_process(s1, x, F, SR);
    gx_ns_get_status(s1, &s);
    CHECK(!s.music_detected, "request_reset clears it too");
    gx_ns_destroy(s1);
  }

  /* 3. never: speech, babble, noise, buzz, traffic */
  gen_speechlike(x, n, SR, -26);
  never("speech-like", x, n);
  gen_talker(x, n, -26, 41);
  never("one talker", x, n);
  {
    int k;
    memset(x, 0, sizeof(float) * (size_t)n);
    for (k = 0; k < 5; k++) {
      gen_talker(y, n, -30 - 2 * k, 50 + (unsigned)k);
      for (i = 0; i < n; i++) x[i] += y[i];
    }
    never("babble of five talkers", x, n);
  }
  gen_noise(x, n, 3000.0, 21);
  never("white noise", x, n);
  gen_buzz(x, n, -40);
  never("mains buzz", x, n);
  gen_traffic(x, n, -38, 31);
  never("traffic", x, n);

  /* 4. music bypass rests the detector */
  {
    struct gx_ns *s1 = mk(1);
    gx_ns_set_bypass(s1, 1);
    gen_music(x, n, -26, 3);
    CHECK(run(s1, x, n, &f, &l) == 0.0, "no detection under music bypass (first at %.2f s)", f / 100.0);
    gx_ns_destroy(s1);
  }

  /* 5. bypass makeup gain: +12 dB on a quiet singer, a hot one is limited (never clipped), none without bypass */
  {
    struct gx_ns *s1 = mk(0);
    double lin, lout, peak = 0;
    gx_ns_set_bypass(s1, 1);
    gx_ns_set_bypass_makeup(s1, 12.f);
    gen_music(x, n, -39, 7);
    memcpy(y, x, sizeof(float) * (size_t)n);
    run(s1, y, n, &f, &l);
    lin = rms_db(x + SR * 2, SR * 10);
    lout = rms_db(y + SR * 2 + gx_ns_latency_samples(s1, SR), SR * 10);
    CHECK(fabs(lout - lin - 12.0) < 0.5, "makeup +12 dB (got %+.2f dB)", lout - lin);
    gen_music(x, n, -8, 7);
    run(s1, x, n, &f, &l);
    for (i = SR; i < n; i++) if (fabsf(x[i]) > peak) peak = fabsf(x[i]);
    CHECK(peak <= 32768.0 * pow(10, -1.0 / 20) + 1, "hot input limited at -1 dBFS (peak %.1f dBFS)", 20 * log10(peak / 32768.0));
    gx_ns_set_bypass(s1, 0);
    gen_speechlike(x, n, SR, -39);
    memcpy(y, x, sizeof(float) * (size_t)n);
    {
      struct gx_ns *s0 = mk(0);
      gx_ns_set_bypass(s1, 0);
      run(s0, y, n, &f, &l);
      gx_ns_destroy(s0);
    }
    run(s1, x, n, &f, &l);
    CHECK(fabs(rms_db(x + SR * 5, SR * 10) - rms_db(y + SR * 5, SR * 10)) < 0.5, "no makeup without the bypass");
    gx_ns_destroy(s1);
  }

  free(x); free(y); free(z);
  return TEST_DONE();
}

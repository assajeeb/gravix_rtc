/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* A held sung note is talk, not a pause (singer report 2026-11-20): a steady
 * note never rises 15 dB over its own 1 s minimum, so the talk detector used to
 * drop it after ~1 s and the pause expander then cut it by 15 dB. Default
 * chain (RNNoise + pre-gain + AGC after NS + pause expander).
 *  1. a 2 s held note (harmonics + 5.5 Hz vibrato) over quiet room noise:
 *     expander cut < 1 dB for the whole note, and the noise between two such
 *     phrases is still expanded (DTX keeps working);
 *  2. the same over a mains buzz the NS keeps (what the expander is for);
 *  3. street noise that steps up right after speech: the sustain path must not
 *     hold the gate open on it (pause output under the DTX limit). */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000

static void gen_pink(float *x, int n, double dbfs, unsigned seed) {
  double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, acc = 0, g;
  int i;
  gen_noise(x, n, 1.0, seed);
  for (i = 0; i < n; i++) {
    double w = x[i], p;
    b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759;
    b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856;
    b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980;
    p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362; b6 = w * 0.115926;
    x[i] = (float)p; acc += p * p;
  }
  g = 32768.0 * pow(10, dbfs / 20.0) / sqrt(acc / n);
  for (i = 0; i < n; i++) x[i] *= (float)g;
}

/* Sung vowel: f0 with 5.5 Hz / +-40 cent vibrato, 12 harmonics with a soft
 * formant-ish tilt, 30 ms attack/release, RMS = level_dbfs over the note. */
static void add_note(float *x, int start, int len, double f0, double level_dbfs) {
  int i, k;
  double ph = 0, acc = 0, g;
  float *v = malloc(sizeof(float) * len);
  for (i = 0; i < len; i++) {
    double t = (double)i / SR, f = f0 * pow(2.0, 40.0 / 1200.0 * sin(2 * M_PI * 5.5 * t)), s = 0, e;
    ph += 2 * M_PI * f / SR;
    for (k = 1; k <= 12; k++) {
      if (f0 * k > SR / 2.2) break;
      s += sin(k * ph + 0.6 * k) / (k <= 3 ? 1.0 : (double)k / 2.0);
    }
    e = 1.0;
    if (i < SR * 3 / 100) e = (double)i / (SR * 3 / 100);
    if (len - i < SR * 3 / 100) e = (double)(len - i) / (SR * 3 / 100);
    v[i] = (float)(s * e);
    acc += s * s;
  }
  g = 32768.0 * pow(10, level_dbfs / 20.0) / sqrt(acc / len);
  for (i = 0; i < len; i++) x[start + i] += (float)(v[i] * g);
  free(v);
}

/* street noise as in test_dtx_street.c: RNNoise passes some of it and its VAD
 * calls it speech, the case the pause expander exists for */
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
  gx_ns_default_config(&c);
  return gx_ns_create(&c);
}

/* Runs x in 10 ms frames; att[b] = pause expander attenuation after block b. */
static float gain_db[SR * 12 / F]; /* pre-gain + AGC applied per block (run_att) */

static void run_att(struct gx_ns *st, float *x, int n, float *att, int *talk) {
  int i, b = 0;
  gx_ns_status s;
  for (i = 0; i + F <= n; i += F, b++) {
    gx_ns_process(st, x + i, F, SR);
    gx_ns_get_status(st, &s);
    att[b] = s.pause_att_db;
    if (b < SR * 12 / F) gain_db[b] = s.pregain_applied_db + s.agc_applied_db;
    if (talk) talk[b] = s.talk;
  }
}

static float mean_in(const float *a, int b0, int b1) {
  float m = 0.f; int b;
  for (b = b0; b < b1; b++) m += a[b];
  return m / (float)(b1 - b0);
}

/* 100 Hz mains buzz (20 harmonics, 1/k): stationary and harmonic, RNNoise
 * keeps most of it (a ground loop on a sound card cable, a fridge) */
static void gen_buzz(float *x, int n, double dbfs) {
  int i, h;
  double acc = 0, g;
  for (i = 0; i < n; i++) {
    double t = (double)i / SR, v = 0;
    for (h = 1; h <= 20; h++) v += sin(2 * M_PI * 100.0 * h * t + h) / h;
    x[i] = (float)v; acc += v * v;
  }
  g = 32768.0 * pow(10, dbfs / 20.0) / sqrt(acc / n);
  for (i = 0; i < n; i++) x[i] *= (float)g;
}

static float max_in(const float *a, int b0, int b1) {
  float m = 0.f; int b;
  for (b = b0; b < b1; b++) if (a[b] > m) m = a[b];
  return m;
}

int main(void) {
  /* 1 + 2: phrase layout 1 s noise, 2 s note, 6 s noise, 2 s note, 1 s noise */
  {
    const double floors[] = {-65, -40, -35};
    const double f0s[] = {220, 330, 440};
    const double levels[] = {-20, -8};
    int fi, ni, li;
    int n = SR * 12, nb = n / F;
    float *x = malloc(sizeof(float) * n), *att = malloc(sizeof(float) * nb), *y = malloc(sizeof(float) * n);
    for (fi = 0; fi < 3; fi++)
      for (ni = 0; ni < 3; ni++)
        for (li = 0; li < 2; li++) {
          struct gx_ns *st = mk();
          float note1, note2, gap_end, cut_kept;
          double gap_ns;
          int kept, bb, L;
          if (floors[fi] <= -60) gen_pink(x, n, floors[fi], 51 + fi);
          else gen_buzz(x, n, floors[fi]);
          add_note(x, SR * 1, SR * 2, f0s[ni], levels[li]);
          add_note(x, SR * 9, SR * 2, f0s[ni], levels[li]);
          memcpy(y, x, sizeof(float) * n);
          run_att(st, y, n, att, NULL);
          L = gx_ns_latency_samples(st, SR);
          /* Per 10 ms block of each note (after its first 100 ms): what the NS
           * left = output + the expander's cut - our gains, against the input.
           * A 440 Hz note over a 100 Hz buzz is partly erased by RNNoise itself
           * (a separate issue, singer report item 2; its VAD drops with it):
           * the expander is judged on the blocks the NS kept (within 3 dB). */
          kept = 0; cut_kept = 0.f; note1 = note2 = 0.f;
          for (bb = 110; bb < 1100; bb++) {
            int in_note = bb < 300 || bb >= 910;
            double inb, outb;
            if (!in_note) continue;
            inb = rms_db(x + bb * F, F);
            outb = rms_db(y + bb * F + L, F) + att[bb] - gain_db[bb];
            if (bb < 300 && att[bb] > note1) note1 = att[bb];
            if (bb >= 910 && att[bb] > note2) note2 = att[bb];
            if (outb > inb - 3.0) {
              kept++;
              if (att[bb] > cut_kept) cut_kept = att[bb];
            }
          }
          /* the noise between the phrases: the expander at work (mean of its last second) */
          gap_end = mean_in(att, 790, 890);
          gap_ns = rms_db(y + SR * 79 / 10, SR) + gap_end; /* (with our gains: what DTX would see) */
          printf("note %3.0f Hz %5.1f dBFS over %5.1f dBFS %s: NS kept %3d/380 blocks, expander cut there %4.1f dB "
                 "(note1/2 max %4.1f/%4.1f); gap: out before the expander %6.1f dBFS, cut %4.1f dB\n", f0s[ni], levels[li],
                 floors[fi], floors[fi] <= -60 ? "pink" : "buzz", kept, cut_kept, note1, note2, gap_ns, gap_end);
          CHECK(cut_kept < 1.f, "%.0f Hz %.0f dBFS / noise %.0f: held note cut %.1f dB", f0s[ni], levels[li], floors[fi], cut_kept);
          /* a quiet room: the NS keeps the whole note, the expander leaves it alone */
          if (floors[fi] <= -60) CHECK(kept >= 370 && note1 < 1.f && note2 < 1.f, "%.0f Hz quiet room: kept %d, cut %.1f/%.1f",
                                       f0s[ni], kept, note1, note2);
          /* noise the NS keeps (the buzz, over the -56 dBFS target): still
           * expanded between the phrases (a quiet room has nothing to expand) */
          if (gap_ns > -50.0)
            CHECK(gap_end > 10.f, "noise %.0f: gap between phrases not expanded (%.1f dB)", floors[fi], gap_end);
          gx_ns_destroy(st);
        }
    free(x); free(att); free(y);
  }
  /* 3: speech over a quiet floor, then the floor steps up to steady loud noise
   * (a fan / AC switched on as the talker stops): the sustain path must not
   * keep the gate open; the pause is expanded under the DTX limit within 2 s. */
  {
    const double steps[] = {-45, -40, -35, -40, -35, -30};
    int k;
    for (k = 0; k < 6; k++) {
      int buzz = k >= 3;
      int talk = SR * 4, rest = SR * 6, n = talk + rest, i, nb = n / F;
      float *x = malloc(sizeof(float) * n), *sp = malloc(sizeof(float) * talk), *att = malloc(sizeof(float) * nb), *nz;
      int *tk = malloc(sizeof(int) * nb), talk_after = 0, b;
      struct gx_ns *st = mk();
      double out;
      gen_pink(x, n, -65, 61 + k);
      gen_speechlike(sp, talk, SR, -25);
      for (i = 0; i < talk; i++) x[i] += sp[i];
      nz = malloc(sizeof(float) * rest);
      if (buzz) gen_buzz(nz, rest, steps[k]); /* the NS keeps it: judged on the expander's cut */
      else gen_traffic(nz, rest, steps[k], 71 + k, 14, 0.4, 0.8, 0.8); /* street */
      for (i = 0; i < rest; i++) x[talk + i] += nz[i];
      run_att(st, x, n, att, tk);
      for (b = (talk + SR * 2) / F; b < nb; b++) talk_after += tk[b];
      out = rms_db(x + talk + SR * 2, rest - SR * 2);
      printf("speech then %s step to %5.1f dBFS: talk blocks after 2 s %d, pause out %6.1f dBFS, cut %4.1f dB\n",
             buzz ? "buzz  " : "street", steps[k], talk_after, out, mean_in(att, (talk + SR * 2) / F, nb));
      if (buzz) CHECK(mean_in(att, (talk + SR * 2) / F, nb) > 10.f, "buzz step %.0f: not expanded", steps[k]);
      else CHECK(out < -50.0, "noise step %.0f: pause out %.1f dBFS over the DTX limit", steps[k], out);
      CHECK(talk_after * 10 < (rest - SR * 2) / F, "noise step %.0f: talk held on noise (%d blocks)", steps[k], talk_after);
      gx_ns_destroy(st);
      free(x); free(sp); free(att); free(tk); free(nz);
    }
  }
  return TEST_DONE();
}

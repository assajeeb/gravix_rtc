/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
#include "test_util.h"
#include <stdint.h>
#include <string.h>

int g_fail = 0, g_checks = 0;

int read_pcm(const char *path, float **out) {
  FILE *f = fopen(path, "rb");
  long sz; int n, i; int16_t *tmp;
  if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
  fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
  n = (int)(sz / 2);
  tmp = malloc(sizeof(int16_t) * n);
  if (fread(tmp, 2, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", path); exit(2); }
  fclose(f);
  *out = malloc(sizeof(float) * n);
  for (i = 0; i < n; i++) (*out)[i] = tmp[i];
  free(tmp);
  return n;
}

void gen_tone(float *x, int n, double freq, double rate, double amp, double phase0) {
  int i;
  for (i = 0; i < n; i++) x[i] = (float)(amp * sin(phase0 + 2 * M_PI * freq * i / rate));
}

double rms_db(const float *x, int n) {
  double a = 0; int i;
  for (i = 0; i < n; i++) a += (double)x[i] * x[i];
  a /= n;
  return a <= 0 ? -200 : 10 * log10(a / (32768.0 * 32768.0));
}

double est_freq(const float *x, int n, double rate) {
  double first = -1, last = -1; int i, count = 0;
  for (i = 1; i < n; i++) {
    if (x[i - 1] < 0 && x[i] >= 0) {
      double t = (i - 1) + x[i - 1] / (x[i - 1] - x[i]);
      if (first < 0) first = t; else count++;
      last = t;
    }
  }
  if (count < 1) return 0;
  return count * rate / (last - first);
}

int best_lag(const float *x, const float *y, int n, int maxlag) {
  int lag, i, best = 0; double bv = -1e300;
  for (lag = 0; lag <= maxlag; lag++) {
    double a = 0;
    for (i = 0; i + lag < n; i++) a += (double)x[i] * y[i + lag];
    if (a > bv) { bv = a; best = lag; }
  }
  return best;
}

void gen_noise(float *x, int n, double amp, unsigned seed) {
  int i; uint32_t s = seed * 2654435761u + 1;
  for (i = 0; i < n; i++) {
    s = s * 1664525u + 1013904223u;
    x[i] = (float)(amp * (((s >> 8) & 0xFFFF) / 32767.5 - 1.0));
  }
}

static double env_at(double t) {
  double e = sin(2 * M_PI * 2.0 * t);
  double m = fmod(t, 3.0);
  if (e < 0 || m > 2.4) return 0; /* syllables, 0.6 s pause every 3 s */
  return pow(e, 0.5);
}

void gen_speechlike(float *x, int n, double rate, double level_dbfs) {
  int i, k; double acc = 0; int cnt = 0, b;
  for (i = 0; i < n; i++) {
    double t = i / rate, f0 = 140 + 30 * sin(2 * M_PI * 0.5 * t), v = 0;
    for (k = 1; k <= 12; k++) {
      double f = f0 * k;
      if (f > rate / 2.2) break;
      v += sin(2 * M_PI * f * t + k * 0.7) / k;
    }
    x[i] = (float)(v * env_at(t));
  }
  /* RMS over active 10 ms blocks */
  b = (int)(rate / 100);
  for (i = 0; i + b <= n; i += b) {
    if (env_at((i + b / 2) / rate) > 0.05) {
      for (k = 0; k < b; k++) acc += (double)x[i + k] * x[i + k];
      cnt += b;
    }
  }
  {
    double cur = 10 * log10(acc / cnt), g = pow(10, (level_dbfs - cur) / 20) * 32768.0;
    for (i = 0; i < n; i++) x[i] *= (float)g;
  }
}

double active_rms_db(const float *y, const float *ref, int n, int block) {
  int i, k, cnt = 0; double acc = 0, thr = 0;
  for (i = 0; i < n; i++) if (fabs(ref[i]) > thr) thr = fabs(ref[i]);
  thr *= 0.05;
  for (i = 0; i + block <= n; i += block) {
    double r = 0;
    for (k = 0; k < block; k++) r += (double)ref[i + k] * ref[i + k];
    if (sqrt(r / block) > thr) {
      for (k = 0; k < block; k++) acc += (double)y[i + k] * y[i + k];
      cnt += block;
    }
  }
  return cnt ? 10 * log10(acc / cnt / (32768.0 * 32768.0)) : -200;
}

double max_step(const float *x, int n) {
  double m = 0; int i;
  for (i = 1; i < n; i++) { double d = fabs((double)x[i] - x[i - 1]); if (d > m) m = d; }
  return m;
}

#include "gx_ns.h"
void run_frames(struct gx_ns *st, float *x, int len, int frame, int rate) {
  int i;
  for (i = 0; i + frame <= len; i += frame) gx_ns_process(st, x + i, frame, rate);
}

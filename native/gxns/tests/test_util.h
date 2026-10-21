/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
#ifndef GX_TEST_UTIL_H
#define GX_TEST_UTIL_H
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

extern int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; \
  fprintf(stderr, "FAIL %s:%d: %s -- ", __FILE__, __LINE__, #cond); \
  fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)
#define TEST_DONE() (printf("%s: %d checks, %d failed\n", __FILE__, g_checks, g_fail), g_fail ? 1 : 0)

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* reads int16 LE mono PCM into floats; returns sample count */
int read_pcm(const char *path, float **out);
void gen_tone(float *x, int n, double freq, double rate, double amp, double phase0);
double rms_db(const float *x, int n);
/* frequency from interpolated rising zero crossings */
double est_freq(const float *x, int n, double rate);
/* lag (0..maxlag) maximising the cross-correlation of y against x */
int best_lag(const float *x, const float *y, int n, int maxlag);
/* deterministic white noise in [-amp, amp] */
void gen_noise(float *x, int n, double amp, unsigned seed);
/* speech-like signal: harmonic bursts with a 4 Hz syllable envelope and pauses;
 * scaled so the RMS over active (envelope > 0) blocks is `level_dbfs`. */
void gen_speechlike(float *x, int n, double rate, double level_dbfs);
/* power-average RMS (dBFS) over 10 ms blocks of y whose matching block in ref is active */
double active_rms_db(const float *y, const float *ref, int n, int block);
/* max |x[i]-x[i-1]| */
double max_step(const float *x, int n);
#endif
struct gx_ns;
/* runs x through gx_ns in frames of `frame` samples at `rate`, in place */
void run_frames(struct gx_ns *st, float *x, int len, int frame, int rate);

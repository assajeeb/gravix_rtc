/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Offline replay: a raw mic recording through the gx_ns core (defaults: RNNoise,
 * pre-gain, AGC after NS, pause gate + expander) with per-window metrics.
 *
 *   gxns_replay <in.wav|in.pcm> [--rate 48000] [--out out.pcm] [--as-is]
 *               [--win name:start-end ...]
 *
 * in: a mono 16-bit wav (header skipped) or raw int16 pcm at --rate. --as-is
 * measures the input itself (or a device's output). Per window (seconds):
 * p50/p90 of 20 ms frame levels, the share of DTX-quiet frames (< -55 dBFS)
 * and the active level (frames over -45 dBFS). Built with GXNS_BUILD_TESTS.
 * 2026-10-21: a Xiaomi room recording replays
 * within 0.5 dB of the device's own output. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "gx_ns.h"

static double lvl(const float *x, int n) {
  double a = 0;
  int i;
  for (i = 0; i < n; i++) a += (double)x[i] * x[i];
  a /= n;
  return a <= 0 ? -200 : 10 * log10(a / (32768.0 * 32768.0));
}
static int cmpd(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
  const char *in = NULL, *out = NULL, *wn[32];
  double wa[32], wb[32];
  int rate = 48000, asis = 0, nw = 0, i, n, blk;
  FILE *f;
  long sz;
  short *pcm;
  float *x;
  for (i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--rate") && i + 1 < argc) rate = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
    else if (!strcmp(argv[i], "--as-is")) asis = 1;
    else if (!strcmp(argv[i], "--win") && i + 1 < argc && nw < 32) {
      char *s = argv[++i], *c = strchr(s, ':');
      if (!c || sscanf(c + 1, "%lf-%lf", &wa[nw], &wb[nw]) != 2) { fprintf(stderr, "bad --win %s\n", s); return 2; }
      *c = 0; wn[nw++] = s;
    } else in = argv[i];
  }
  if (!in) { fprintf(stderr, "usage: see the file comment\n"); return 2; }
  if (!(f = fopen(in, "rb"))) { fprintf(stderr, "cannot open %s\n", in); return 2; }
  fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
  pcm = malloc(sz);
  if (fread(pcm, 1, sz, f) != (size_t)sz) { fprintf(stderr, "short read\n"); return 2; }
  fclose(f);
  {
    int off = (sz > 44 && !memcmp(pcm, "RIFF", 4)) ? 22 : 0; /* 44-byte header, in shorts */
    n = (int)(sz / 2) - off;
    x = malloc(sizeof(float) * n);
    for (i = 0; i < n; i++) x[i] = pcm[off + i];
  }
  if (!asis) {
    gx_ns_config c;
    struct gx_ns *st;
    gx_ns_default_config(&c);
    st = gx_ns_create(&c);
    blk = rate / 100;
    for (i = 0; i + blk <= n; i += blk) gx_ns_process(st, x + i, blk, rate);
    gx_ns_destroy(st);
  }
  if (out) {
    FILE *o = fopen(out, "wb");
    for (i = 0; i < n; i++) {
      float v = x[i];
      short s = v > 32767.f ? 32767 : v < -32768.f ? -32768 : (short)v;
      fwrite(&s, 2, 1, o);
    }
    fclose(o);
  }
  if (!nw) { wn[0] = "all"; wa[0] = 0; wb[0] = (double)n / rate; nw = 1; }
  for (i = 0; i < nw; i++) {
    int fr = rate / 50, a = (int)(wa[i] * rate), b = (int)(wb[i] * rate), k, m = 0, q = 0, na = 0;
    double *v, act = 0;
    if (b > n) b = n;
    v = malloc(sizeof(double) * ((b - a) / fr + 1));
    for (k = a; k + fr <= b; k += fr) {
      double r = lvl(x + k, fr);
      v[m++] = r;
      q += r < -55;
      if (r > -45) { int j; for (j = 0; j < fr; j++) act += (double)x[k + j] * x[k + j]; na += fr; }
    }
    if (!m) { free(v); continue; }
    qsort(v, m, sizeof(double), cmpd);
    printf("%-10s p50 %6.1f p90 %6.1f dtx-quiet(<-55) %3.0f%% active(>-45) %6.1f dBFS over %3.0f%%\n", wn[i], v[m / 2], v[m * 9 / 10],
           100.0 * q / m, na ? 10 * log10(act / na / (32768.0 * 32768.0)) : -200.0, 100.0 * na / ((double)m * fr));
    free(v);
  }
  free(pcm); free(x);
  return 0;
}

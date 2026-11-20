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
  int rate = 48000, asis = 0, nw = 0, i, n, blk, music = 0, trace = 0, lat = 0;
  float *x0 = NULL;
  FILE *f;
  long sz;
  short *pcm;
  float *x;
  for (i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--rate") && i + 1 < argc) rate = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
    else if (!strcmp(argv[i], "--as-is")) asis = 1;
    else if (!strcmp(argv[i], "--music")) music = 1;
    else if (!strcmp(argv[i], "--trace")) trace = 1;
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
    int on_blocks = 0, toggles = 0, prev = 0, first = -1, nb = 0;
    gx_ns_default_config(&c);
    c.auto_music = music;
    st = gx_ns_create(&c);
    blk = rate / 100;
    x0 = malloc(sizeof(float) * n);
    memcpy(x0, x, sizeof(float) * n);
    for (i = 0; i + blk <= n; i += blk) {
      gx_ns_status s;
      float d[7];
      gx_ns_process(st, x + i, blk, rate);
      gx_ns_get_status(st, &s);
      gx_ns_get_music_debug(st, d);
      nb++;
      on_blocks += s.music_detected;
      if (s.music_detected != prev) { toggles++; if (s.music_detected && first < 0) first = nb; prev = s.music_detected; }
      if (trace && nb % 50 == 0)
        printf("t=%5.1f music=%d m=%.2f dip=%.3f tonal=%.2f onsets=%3.0f stable=%2.0f lvl=%.1f pg=%.1f agc=%.1f att=%.1f\n", nb / 100.0,
               s.music_detected, d[5], d[0], d[1], d[2], d[3], d[6], s.pregain_applied_db, s.agc_applied_db, s.pause_att_db);
    }
    lat = gx_ns_latency_samples(st, rate);
    if (music) printf("music: on %.0f%% first %.1fs toggles %d\n", 100.0 * on_blocks / (nb ? nb : 1), first < 0 ? -1.0 : first / 100.0, toggles);
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
  if (x0) {
    /* the peer's metric: 50 ms frames where the output is > 10 / > 20 dB under the input
     * (latency-aligned), over frames where the input is > -60 dBFS */
    int fr = rate / 20, k, m = 0, d10 = 0, d20 = 0;
    for (k = 0; k + fr + lat <= n; k += fr) {
      double li = lvl(x0 + k, fr), lo = lvl(x + k + lat, fr);
      if (li < -60) continue;
      m++; d10 += lo < li - 10; d20 += lo < li - 20;
    }
    printf("cut: >10dB %4.1f%% >20dB %4.1f%% (of %d active 50 ms frames)\n", m ? 100.0 * d10 / m : 0, m ? 100.0 * d20 / m : 0, m);
    free(x0);
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

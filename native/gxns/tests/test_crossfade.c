/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Crossfades must not click and must not comb-filter: every path is delay
 * compensated, so fading between two paths that carry the same signal gives
 * back exactly that signal. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000

/* identity "studio" engine with a configurable algorithmic delay */
typedef struct { float ring[4096]; int w, lat, calls; float max_in; } ident;
static int ident_process(void *u, float *out, const float *in, int n) {
  ident *e = (ident *)u; int i;
  for (i = 0; i < n; i++) {
    if (fabsf(in[i]) > e->max_in) e->max_in = fabsf(in[i]);
    e->ring[(e->w + i) % 4096] = in[i];
  }
  for (i = 0; i < n; i++) out[i] = e->ring[(e->w + i - e->lat + 4096) % 4096];
  e->w = (e->w + n) % 4096;
  e->calls++;
  return 0;
}

static struct gx_ns *mk(gx_ns_engine e) {
  gx_ns_config c;
  gx_ns_default_config(&c);
  c.agc_enabled = 0;
  c.initial_engine = e;
  return gx_ns_create(&c);
}

static void ident_case(int lat) {
  int len = SR * 6, i, k, L;
  float *x = malloc(sizeof(float) * len), *y = malloc(sizeof(float) * len);
  static ident e;
  gx_ns_external_engine ext;
  struct gx_ns *st = mk(GX_NS_ENGINE_OFF);
  gx_ns_status s;
  double maxerr = 0, stepx;
  int start = -1;
  memset(&e, 0, sizeof(e));
  e.lat = lat;
  ext.process = ident_process; ext.reset = NULL; ext.user = &e; ext.latency_samples = lat;
  CHECK(gx_ns_set_external_engine(st, &ext) == 0, "attach");
  gen_tone(x, len, 440, SR, 8000, 0.1);
  memcpy(y, x, sizeof(float) * len);
  /* dry <-> studio every 25 blocks (250 ms) */
  for (k = 0, i = 0; i + F <= len; i += F, k++) {
    if (k % 25 == 0) gx_ns_set_engine(st, (k / 25) % 2 ? GX_NS_ENGINE_DFN3 : GX_NS_ENGINE_OFF);
    gx_ns_process(st, y + i, F, SR);
    gx_ns_get_status(st, &s);
    if (start < 0 && s.latency_samples == (lat > 480 ? lat : 480)) start = i + 2 * F; /* after the delay change + its fade */
  }
  L = gx_ns_latency_samples(st, SR);
  CHECK(L == (lat > 480 ? lat : 480), "lat %d -> L %d", lat, L);
  CHECK(start > 0, "delay change applied");
  for (i = start; i < len - F; i++) {
    double d = fabs(y[i] - x[i - L]);
    if (d > maxerr) maxerr = d;
  }
  CHECK(maxerr < 1.0, "ext lat %d: dry<->studio crossfades must reproduce the input exactly; max err %.4f", lat, maxerr);
  CHECK(e.max_in <= 1.0f && e.max_in > 0.2f, "studio engine gets [-1,1] scale: max |in| %.4f", e.max_in);
  stepx = max_step(x, len);
  CHECK(max_step(y + F, len - F) <= stepx * 1.1 + 40, "no click incl. the 5 ms delay-change fade: %.1f vs %.1f", max_step(y + F, len - F), stepx);
  printf("identity studio engine lat=%d: L=%d, max err %.4f over %d crossfades\n", lat, L, maxerr, len / F / 25);
  gx_ns_destroy(st);
  free(x); free(y);
}

int main(void) {
  ident_case(480);
  ident_case(960);
  ident_case(240);

  /* dry <-> RNNoise on noisy speech: no clicks */
  {
    float *in, *a, *b, *c;
    int n = read_pcm(GXNS_FIXTURES "/noisy_speechlike_48k.pcm", &in), i, k;
    struct gx_ns *sa = mk(GX_NS_ENGINE_OFF), *sb = mk(GX_NS_ENGINE_RNNOISE), *sc = mk(GX_NS_ENGINE_OFF);
    double ma, mb, mc;
    gx_ns_stats s;
    a = malloc(sizeof(float) * n); b = malloc(sizeof(float) * n); c = malloc(sizeof(float) * n);
    memcpy(a, in, sizeof(float) * n); memcpy(b, in, sizeof(float) * n); memcpy(c, in, sizeof(float) * n);
    run_frames(sa, a, n, F, SR);
    run_frames(sb, b, n, F, SR);
    for (k = 0, i = 0; i + F <= n; i += F, k++) {
      if (k % 7 == 3) gx_ns_set_engine(sc, (k / 7) % 2 ? GX_NS_ENGINE_OFF : GX_NS_ENGINE_RNNOISE);
      gx_ns_process(sc, c + i, F, SR);
    }
    ma = max_step(a + 3 * F, n - 3 * F); mb = max_step(b + 3 * F, n - 3 * F); mc = max_step(c + 3 * F, n - 3 * F);
    CHECK(mc <= (ma > mb ? ma : mb) * 1.25 + 70, "dry<->rnnoise toggling: max step %.1f (dry %.1f, rnnoise %.1f)", mc, ma, mb);
    gx_ns_get_stats(sc, &s);
    CHECK(s.engine_switches >= 20, "switches %u", s.engine_switches);
    printf("dry<->rnnoise every 70 ms: max step %.1f (dry %.1f, rnnoise %.1f), %u crossfades\n", mc, ma, mb, s.engine_switches);
    gx_ns_destroy(sa); gx_ns_destroy(sb); gx_ns_destroy(sc);
    free(in); free(a); free(b); free(c);
  }

  /* dry <-> RNNoise on a clean tone (small natural steps, so a click shows) */
  {
    int len = SR * 2, i, k;
    float *x = malloc(sizeof(float) * len), *a = malloc(sizeof(float) * len), *b = malloc(sizeof(float) * len), *c = malloc(sizeof(float) * len);
    struct gx_ns *sa = mk(GX_NS_ENGINE_OFF), *sb = mk(GX_NS_ENGINE_RNNOISE), *sc = mk(GX_NS_ENGINE_OFF);
    double ma, mb, mc;
    gen_tone(x, len, 437, SR, 6000, 0); /* 480 samples is not a whole number of periods */
    memcpy(a, x, sizeof(float) * len); memcpy(b, x, sizeof(float) * len); memcpy(c, x, sizeof(float) * len);
    run_frames(sa, a, len, F, SR);
    run_frames(sb, b, len, F, SR);
    for (k = 0, i = 0; i + F <= len; i += F, k++) {
      if (k % 7 == 3) gx_ns_set_engine(sc, (k / 7) % 2 ? GX_NS_ENGINE_OFF : GX_NS_ENGINE_RNNOISE);
      gx_ns_process(sc, c + i, F, SR);
    }
    ma = max_step(a + 3 * F, len - 3 * F); mb = max_step(b + 3 * F, len - 3 * F); mc = max_step(c + 3 * F, len - 3 * F);
    CHECK(mc <= (ma > mb ? ma : mb) * 1.1 + 20, "tone dry<->rnnoise: max step %.1f (dry %.1f, rnnoise %.1f)", mc, ma, mb);
    printf("tone dry<->rnnoise every 70 ms: max step %.1f (dry %.1f, rnnoise %.1f)\n", mc, ma, mb);
    gx_ns_destroy(sa); gx_ns_destroy(sb); gx_ns_destroy(sc);
    free(x); free(a); free(b); free(c);
  }

  /* route-change reset: engine fades back in from dry, no click, no gap */
  {
    int len = SR * 2, i, k;
    float *x = malloc(sizeof(float) * len), *y = malloc(sizeof(float) * len);
    struct gx_ns *st = mk(GX_NS_ENGINE_RNNOISE);
    gx_ns_status s;
    gen_tone(x, len, 300, SR, 6000, 0);
    gen_noise(y, len, 1500, 3);
    for (i = 0; i < len; i++) x[i] += y[i];
    memcpy(y, x, sizeof(float) * len);
    for (k = 0, i = 0; i + F <= len; i += F, k++) {
      if (k == 100) gx_ns_request_reset(st);
      gx_ns_process(st, y + i, F, SR);
      if (k == 100) { gx_ns_get_status(st, &s); CHECK(s.crossfading == 1, "fading back in after reset"); }
    }
    {
      /* reference: the same input fully dry and fully RNNoise (white noise has big steps) */
      float *d = malloc(sizeof(float) * len);
      struct gx_ns *sd = mk(GX_NS_ENGINE_OFF);
      double ref, around, gap, steady;
      memcpy(d, x, sizeof(float) * len);
      run_frames(sd, d, len, F, SR);
      ref = max_step(d + 90 * F, 20 * F);
      { double r2 = max_step(y + 80 * F, 20 * F); if (r2 > ref) ref = r2; }
      around = max_step(y + 99 * F, 8 * F);
      gap = rms_db(y + 100 * F, 4 * F); steady = rms_db(y + 90 * F, 4 * F);
      CHECK(around <= ref * 1.1 + 70, "reset: max step %.1f vs dry/rnnoise %.1f", around, ref);
      CHECK(gap > steady - 6, "reset: no gap (%.1f dB vs %.1f dB)", gap, steady);
      printf("route reset: max step %.1f (reference %.1f), level %.1f dB vs %.1f dB\n", around, ref, gap, steady);
      gx_ns_destroy(sd);
      free(d);
    }
    gx_ns_destroy(st);
    free(x); free(y);
  }

  /* music bypass: crossfade to dry and back */
  {
    int len = SR, i, k;
    float *x = malloc(sizeof(float) * len), *y = malloc(sizeof(float) * len);
    struct gx_ns *st = mk(GX_NS_ENGINE_RNNOISE);
    gx_ns_status s;
    gen_tone(x, len, 440, SR, 8000, 0);
    memcpy(y, x, sizeof(float) * len);
    for (k = 0, i = 0; i + F <= len; i += F, k++) {
      if (k == 20) gx_ns_set_bypass(st, 1);
      if (k == 60) gx_ns_set_bypass(st, 0);
      gx_ns_process(st, y + i, F, SR);
      if (k == 50) {
        gx_ns_get_status(st, &s);
        CHECK(s.active == GX_NS_ENGINE_OFF && s.reason == GX_NS_REASON_BYPASS, "bypass: active %d reason %d", s.active, s.reason);
      }
    }
    CHECK(fabs(rms_db(y + 40 * F, 10 * F) - rms_db(x, 10 * F)) < 0.1, "bypass passes the tone at unity");
    gx_ns_get_status(st, &s);
    CHECK(s.active == GX_NS_ENGINE_RNNOISE && s.reason == GX_NS_REASON_OK, "back to rnnoise");
    gx_ns_destroy(st);
    free(x); free(y);
  }
  return TEST_DONE();
}

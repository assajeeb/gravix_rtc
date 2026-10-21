/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* VAD-gated AGC: speech-level input settles within +-2 dB of the target,
 * noise alone is not pumped up, the limiter holds the ceiling. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000

/* An identity "studio" engine: the AGC is measured on its own, with an engine
 * on (engine "off" takes our AGC out too, review #1 2026-10-21). */
static int ident_process(void *u, float *out, const float *in, int n) {
  (void)u;
  memcpy(out, in, sizeof(float) * n);
  return 0;
}

static struct gx_ns *mk(gx_ns_agc_order order) {
  gx_ns_config c;
  gx_ns_external_engine e;
  struct gx_ns *st;
  gx_ns_default_config(&c);
  c.initial_engine = GX_NS_ENGINE_DFN3;
  c.agc_order = order;
  c.max_external_latency = 1440;
  st = gx_ns_create(&c);
  memset(&e, 0, sizeof(e));
  e.process = ident_process; e.latency_samples = 480;
  gx_ns_set_external_engine(st, &e);
  return st;
}

int main(void) {
  const double levels[] = {-30, -26, -22, -18, -14, -10};
  int li, oi, len = SR * 12;
  float *x = malloc(sizeof(float) * len), *y = malloc(sizeof(float) * len);
  for (oi = 0; oi < 2; oi++) {
    for (li = 0; li < 6; li++) {
      struct gx_ns *st = mk(oi ? GX_NS_AGC_BEFORE_NS : GX_NS_AGC_AFTER_NS);
      int L, tail = SR * 4;
      double out;
      gen_speechlike(x, len, SR, levels[li]);
      memcpy(y, x, sizeof(float) * len);
      run_frames(st, y, len, F, SR);
      L = gx_ns_latency_samples(st, SR);
      out = active_rms_db(y + len - tail, x + len - tail - L, tail - L, F);
      CHECK(fabs(out - GX_NS_DEFAULT_AGC_TARGET_DBFS) <= 2.0, "order %s in %.0f dBFS -> out %.2f dBFS (target %d)", oi ? "before" : "after", levels[li], out, GX_NS_DEFAULT_AGC_TARGET_DBFS);
      printf("AGC %-6s in %6.1f dBFS -> %6.2f dBFS\n", oi ? "before" : "after", levels[li], out);
      gx_ns_destroy(st);
    }
  }
  /* noise only at -50 dBFS: gain must not climb */
  {
    struct gx_ns *st = mk(GX_NS_DEFAULT_AGC_ORDER);
    gx_ns_status s;
    gen_noise(x, len, 32768.0 * pow(10, -50 / 20.0) * sqrt(3.0), 5);
    memcpy(y, x, sizeof(float) * len);
    run_frames(st, y, len, F, SR);
    gx_ns_get_status(st, &s);
    CHECK(s.agc_gain_db <= 1.0, "noise-only gain %.2f dB", s.agc_gain_db);
    gx_ns_destroy(st);
  }
  /* limiter: a full-scale square wave never exceeds the -1 dBFS ceiling */
  {
    struct gx_ns *st = mk(GX_NS_DEFAULT_AGC_ORDER);
    int i; double pk = 0, ceil = 32768.0 * pow(10, -1 / 20.0);
    for (i = 0; i < len; i++) x[i] = ((i / 55) % 2) ? 32767.f : -32768.f;
    memcpy(y, x, sizeof(float) * len);
    run_frames(st, y, len, F, SR);
    for (i = 0; i < len; i++) if (fabs(y[i]) > pk) pk = fabs(y[i]);
    CHECK(pk <= ceil + 0.5, "limiter peak %.1f > ceiling %.1f", pk, ceil);
    gx_ns_destroy(st);
  }
  /* AGC off: unity */
  {
    gx_ns_config c; struct gx_ns *st; int L;
    gx_ns_default_config(&c); c.initial_engine = GX_NS_ENGINE_OFF;
    st = gx_ns_create(&c);
    gx_ns_set_agc(st, 0);
    gen_speechlike(x, len, SR, -30);
    memcpy(y, x, sizeof(float) * len);
    run_frames(st, y, len, F, SR);
    L = gx_ns_latency_samples(st, SR);
    CHECK(fabs(active_rms_db(y + SR + L, x + SR, len - SR - L, F) + 30) < 0.2, "agc off is unity");
    gx_ns_destroy(st);
  }
  /* engine off (SDK "off" / kill switch): our AGC is out too, WebRTC's AGC
   * owns the level there; it comes back with an engine (review #1, 2026-10-21) */
  {
    struct gx_ns *st = mk(GX_NS_DEFAULT_AGC_ORDER);
    int L, k, nb = len / F, half = (nb / 2) * F;
    gx_ns_status s;
    gen_speechlike(x, len, SR, -30);
    memcpy(y, x, sizeof(float) * len);
    gx_ns_set_engine(st, GX_NS_ENGINE_OFF);
    for (k = 0; k < nb; k++) {
      if (k * F == half) gx_ns_set_engine(st, GX_NS_ENGINE_DFN3);
      gx_ns_process(st, y + k * F, F, SR);
      if (k * F == half - F) {
        gx_ns_get_status(st, &s);
        CHECK(s.agc_gain_db == 0.f, "engine off: agc gain %.2f dB", s.agc_gain_db);
      }
    }
    L = gx_ns_latency_samples(st, SR);
    CHECK(fabs(active_rms_db(y + SR + L, x + SR, half - SR - L, F) + 30) < 0.2, "engine off: our AGC is unity (%.2f dBFS)",
          active_rms_db(y + SR + L, x + SR, half - SR - L, F));
    CHECK(active_rms_db(y + len - SR * 2, x + len - SR * 2 - L, SR * 2 - L, F) > -22, "AGC back with an engine");
    gx_ns_destroy(st);
  }
  /* music bypass takes the whole chain out: our AGC goes to unity too (it
   * would lift -30 dBFS by +12 dB), and comes back after the bypass. */
  {
    struct gx_ns *st = mk(GX_NS_DEFAULT_AGC_ORDER);
    int L, k, nb = len / F, half = (nb / 2) * F;
    gx_ns_status s;
    gen_speechlike(x, len, SR, -30);
    memcpy(y, x, sizeof(float) * len);
    gx_ns_set_bypass(st, 1);
    for (k = 0; k < nb; k++) {
      if (k * F == half) gx_ns_set_bypass(st, 0);
      gx_ns_process(st, y + k * F, F, SR);
    }
    L = gx_ns_latency_samples(st, SR);
    CHECK(fabs(active_rms_db(y + SR + L, x + SR, half - SR - L, F) + 30) < 0.2, "bypass: our AGC is unity (%.2f dBFS)",
          active_rms_db(y + SR + L, x + SR, half - SR - L, F));
    CHECK(active_rms_db(y + len - SR * 2, x + len - SR * 2 - L, SR * 2 - L, F) > -22, "AGC back after bypass");
    gx_ns_get_status(st, &s);
    CHECK(s.reason == GX_NS_REASON_OK, "reason after bypass %d", s.reason);
    gx_ns_destroy(st);
  }
  /* The default order lives in ONE constant per language; the shared fixture
   * (test/fixtures/ns_policy_cases.json, also in the JS SDK) pins all three. */
  {
    FILE *f = fopen(GXNS_SHARED_FIXTURE, "rb");
    char buf[65536];
    size_t n = f ? fread(buf, 1, sizeof(buf) - 1, f) : 0;
    const char *want = GX_NS_DEFAULT_AGC_ORDER == GX_NS_AGC_AFTER_NS ? "\"agcOrder\": \"ownAfterNs\"" : "\"agcOrder\": \"webrtcBeforeNs\"";
    if (f) fclose(f);
    buf[n] = 0;
    CHECK(n > 0, "shared fixture readable: %s", GXNS_SHARED_FIXTURE);
    CHECK(strstr(buf, want) != NULL, "GX_NS_DEFAULT_AGC_ORDER disagrees with defaults.agcOrder in the shared fixture");
  }
  free(x); free(y);
  return TEST_DONE();
}

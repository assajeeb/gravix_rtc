/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Studio (external engine) plumbing: unavailable -> RNNoise with a reason,
 * engine error -> immediate RNNoise fallback, latency limit, detach,
 * attenuation limit, rolling-p95 fallback (studio_slow). */
#include <string.h>
#include <time.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000

typedef struct { int calls, fail_at, resets; } fake;
static int fake_process(void *u, float *out, const float *in, int n) {
  fake *f = (fake *)u; int i;
  f->calls++;
  if (f->fail_at && f->calls >= f->fail_at) return -1;
  for (i = 0; i < n; i++) out[i] = in[i] * 0.5f;
  return 0;
}
static void fake_reset(void *u) { ((fake *)u)->resets++; }

/* fully suppressing engine (outputs silence) */
static int zero_process(void *u, float *out, const float *in, int n) {
  int i; (void)u; (void)in;
  for (i = 0; i < n; i++) out[i] = 0.f;
  return 0;
}
/* slow engine: busy-waits *(int *)u microseconds per block */
static int slow_process(void *u, float *out, const float *in, int n) {
  struct timespec a, b; long us = *(int *)u; int i;
  clock_gettime(CLOCK_MONOTONIC, &a);
  do { clock_gettime(CLOCK_MONOTONIC, &b); } while ((b.tv_sec - a.tv_sec) * 1000000L + (b.tv_nsec - a.tv_nsec) / 1000L < us);
  for (i = 0; i < n; i++) out[i] = in[i];
  return 0;
}
static double run_rms_db(struct gx_ns *st, int blocks) {
  float b[F]; int k, i; double acc = 0; int cnt = 0;
  for (k = 0; k < blocks; k++) {
    gen_noise(b, F, 3000, 1000 + k); gx_ns_process(st, b, F, SR);
    for (i = 0; i < F; i++) { acc += (double)b[i] * b[i]; cnt++; }
  }
  return 10.0 * log10(acc / cnt + 1e-12);
}
static int fixture_has(const char *needle) {
  FILE *f = fopen(GXNS_SHARED_FIXTURE, "rb");
  static char buf[65536];
  size_t n = f ? fread(buf, 1, sizeof(buf) - 1, f) : 0;
  if (f) fclose(f);
  buf[n] = 0;
  return n > 0 && strstr(buf, needle) != NULL;
}

static void run(struct gx_ns *st, int blocks) {
  float b[F]; int k;
  for (k = 0; k < blocks; k++) { gen_noise(b, F, 3000, k); gx_ns_process(st, b, F, SR); }
}

int main(void) {
  gx_ns_status s;
  gx_ns_stats t;
  fake f;
  gx_ns_external_engine e;
  struct gx_ns *st = gx_ns_create(NULL);

  /* studio requested, nothing attached -> rnnoise, studio_unavailable */
  gx_ns_set_engine(st, GX_NS_ENGINE_DFN3);
  run(st, 10);
  gx_ns_get_status(st, &s);
  CHECK(s.requested == GX_NS_ENGINE_DFN3 && s.active == GX_NS_ENGINE_RNNOISE, "active %s", gx_ns_engine_name(s.active));
  CHECK(s.reason == GX_NS_REASON_NO_EXTERNAL && !strcmp(gx_ns_reason_name(s.reason), "studio_unavailable"), "reason %s", gx_ns_reason_name(s.reason));

  /* attach (latency == RNNoise's: no delay change) -> dfn3 after pre-roll + fade */
  memset(&f, 0, sizeof(f));
  e.process = fake_process; e.reset = fake_reset; e.user = &f; e.latency_samples = 480;
  CHECK(gx_ns_set_external_engine(st, &e) == 0, "attach");
  run(st, 10);
  gx_ns_get_status(st, &s);
  CHECK(s.active == GX_NS_ENGINE_DFN3 && s.reason == GX_NS_REASON_OK && !s.crossfading, "active %s reason %s", gx_ns_engine_name(s.active), gx_ns_reason_name(s.reason));

  /* route reset reaches the engine */
  gx_ns_request_reset(st);
  run(st, 3); /* fade to dry (20 ms), then reset */
  CHECK(f.resets == 1, "engine reset %d", f.resets);
  run(st, 5);

  /* engine error -> rnnoise at once, counted, reason studio_error */
  f.fail_at = f.calls + 1;
  run(st, 3);
  gx_ns_get_status(st, &s);
  gx_ns_get_stats(st, &t);
  CHECK(s.active == GX_NS_ENGINE_RNNOISE && s.reason == GX_NS_REASON_EXT_ERROR, "after error: %s %s", gx_ns_engine_name(s.active), gx_ns_reason_name(s.reason));
  CHECK(t.ext_errors == 1, "ext_errors %u", t.ext_errors);
  CHECK(f.calls == f.fail_at, "failed engine not called again (%d calls)", f.calls);

  /* re-attaching clears the error latch */
  f.fail_at = 0;
  gx_ns_set_external_engine(st, &e);
  run(st, 10);
  gx_ns_get_status(st, &s);
  CHECK(s.active == GX_NS_ENGINE_DFN3, "re-attached: %s", gx_ns_engine_name(s.active));

  /* detach without switching away: hard cut to rnnoise, never calls the engine again */
  {
    uint32_t b0 = gx_ns_blocks_processed(st);
    int calls;
    gx_ns_set_external_engine(st, NULL);
    run(st, 1);
    CHECK(gx_ns_blocks_processed(st) > b0, "block counter advances");
    calls = f.calls;
    run(st, 5);
    CHECK(f.calls == calls, "detached engine not called");
    gx_ns_get_status(st, &s);
    CHECK(s.active == GX_NS_ENGINE_RNNOISE && s.reason == GX_NS_REASON_NO_EXTERNAL, "detached: %s", gx_ns_engine_name(s.active));
  }

  /* latency above max_external_latency is refused */
  e.latency_samples = 5000;
  CHECK(gx_ns_set_external_engine(st, &e) == -1, "too much latency refused");
  e.latency_samples = 480; e.process = NULL;
  CHECK(gx_ns_set_external_engine(st, &e) == -1, "NULL process refused");

  /* off */
  gx_ns_set_engine(st, GX_NS_ENGINE_OFF);
  run(st, 5);
  gx_ns_get_status(st, &s);
  CHECK(s.active == GX_NS_ENGINE_OFF, "off");
  CHECK(!strcmp(gx_ns_engine_name(GX_NS_ENGINE_RNNOISE), "rnnoise") && !strcmp(gx_ns_engine_name(GX_NS_ENGINE_DFN3), "dfn3") && !strcmp(gx_ns_engine_name(GX_NS_ENGINE_OFF), "off"), "names");
  gx_ns_destroy(st);

  /* attenuation limit: an engine that removes everything is held at -limit dB (AGC off) */
  {
    gx_ns_config c;
    double dry, lim40, lim20, none;
    gx_ns_default_config(&c);
    CHECK(c.ext_atten_lim_db == 40.f && c.ext_p95_budget_us == 3000 && c.ext_p95_window == 200, "defaults %.0f/%d/%d", c.ext_atten_lim_db, c.ext_p95_budget_us, c.ext_p95_window);
    c.agc_enabled = 0;
    st = gx_ns_create(&c);
    gx_ns_set_engine(st, GX_NS_ENGINE_OFF);
    run(st, 20);
    dry = run_rms_db(st, 50);
    e.process = zero_process; e.reset = NULL; e.user = NULL; e.latency_samples = 480;
    CHECK(gx_ns_set_external_engine(st, &e) == 0, "attach zero engine");
    gx_ns_set_engine(st, GX_NS_ENGINE_DFN3);
    run(st, 20);
    gx_ns_get_status(st, &s);
    CHECK(s.active == GX_NS_ENGINE_DFN3 && !s.crossfading, "zero engine active: %s", gx_ns_engine_name(s.active));
    lim40 = run_rms_db(st, 50);
    gx_ns_set_atten_limit(st, 20.f); run(st, 2);
    lim20 = run_rms_db(st, 50);
    gx_ns_set_atten_limit(st, 0.f); run(st, 2);
    none = run_rms_db(st, 50);
    CHECK(fabs((dry - lim40) - 40.0) < 0.5, "40 dB limit: %.2f dB below dry", dry - lim40);
    CHECK(fabs((dry - lim20) - 20.0) < 0.5, "20 dB limit: %.2f dB below dry", dry - lim20);
    CHECK(dry - none > 80.0, "no limit: %.1f dB below dry", dry - none);
    gx_ns_destroy(st);
  }

  /* rolling p95: a 4 ms/block engine is demoted to RNNoise (studio_slow) after one window;
   * re-attaching clears it; a fast engine with the default 2 s window never trips */
  {
    gx_ns_config c;
    int slow_us = 4000;
    gx_ns_default_config(&c);
    c.ext_p95_window = 20; /* 200 ms keeps the test short */
    st = gx_ns_create(&c);
    e.process = slow_process; e.reset = NULL; e.user = &slow_us; e.latency_samples = 480;
    gx_ns_set_external_engine(st, &e);
    gx_ns_set_engine(st, GX_NS_ENGINE_DFN3);
    run(st, 60);
    gx_ns_get_status(st, &s);
    gx_ns_get_stats(st, &t);
    CHECK(s.active == GX_NS_ENGINE_RNNOISE && s.reason == GX_NS_REASON_EXT_SLOW && !strcmp(gx_ns_reason_name(s.reason), "studio_slow"),
          "slow engine: %s %s", gx_ns_engine_name(s.active), gx_ns_reason_name(s.reason));
    CHECK(t.ext_slow == 1 && t.ext_p95_us >= 3000, "stats slow=%u p95=%u", t.ext_slow, t.ext_p95_us);
    slow_us = 0;
    gx_ns_set_external_engine(st, &e); /* re-attach (now fast) */
    run(st, 10);
    gx_ns_get_status(st, &s);
    gx_ns_get_stats(st, &t);
    CHECK(s.active == GX_NS_ENGINE_DFN3 && t.ext_slow == 0, "re-attached: %s slow=%u", gx_ns_engine_name(s.active), t.ext_slow);
    gx_ns_set_ext_p95_budget(st, 0); /* 0 = off: even a slow engine stays */
    slow_us = 4000;
    run(st, 60);
    gx_ns_get_status(st, &s);
    CHECK(s.active == GX_NS_ENGINE_DFN3, "budget off: %s", gx_ns_engine_name(s.active));
    gx_ns_destroy(st);

    st = gx_ns_create(NULL);
    slow_us = 0;
    gx_ns_set_external_engine(st, &e);
    gx_ns_set_engine(st, GX_NS_ENGINE_DFN3);
    run(st, 260);
    gx_ns_get_status(st, &s);
    gx_ns_get_stats(st, &t);
    CHECK(s.active == GX_NS_ENGINE_DFN3 && t.ext_slow == 0 && t.ext_p95_us < 3000, "fast engine kept: %s p95=%u", gx_ns_engine_name(s.active), t.ext_p95_us);
    gx_ns_destroy(st);
  }

  /* one constant per language; the shared fixture pins C, Dart and TS */
  CHECK(fixture_has("\"studioAttenLimitDb\": 40") && GX_NS_DEFAULT_ATTEN_LIM_DB == 40, "atten limit default vs shared fixture");
  CHECK(fixture_has("\"studioP95BudgetUs\": 3000") && GX_NS_DEFAULT_EXT_P95_BUDGET_US == 3000, "p95 budget default vs shared fixture");
  CHECK(fixture_has("\"studioP95WindowMs\": 2000") && GX_NS_DEFAULT_EXT_P95_WINDOW * 10 == 2000, "p95 window default vs shared fixture");
  return TEST_DONE();
}

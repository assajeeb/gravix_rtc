/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* The library is built with every malloc/calloc/realloc/free redirected to
 * counters (tests/alloc_trap.h). After gx_ns_create(), nothing on the hot path
 * may allocate: engine switches, bypass, AGC order, route resets, every rate,
 * odd frame sizes, studio attach/detach, stats. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

extern int gxt_allocs, gxt_frees;

static int ident(void *u, float *out, const float *in, int n) { (void)u; memcpy(out, in, sizeof(float) * n); return 0; }

int main(void) {
  static const int rates[] = {48000, 16000, 44100, 8000, 24000, 32000, 48000};
  float buf[4096];
  int a0, f0, ri, k;
  gx_ns_stats s; gx_ns_status t;
  gx_ns_external_engine e = {ident, NULL, NULL, 960};
  struct gx_ns *st = gx_ns_create(NULL);
  CHECK(st != NULL, "create");
  CHECK(gxt_allocs > 0, "the trap sees create()'s allocations (%d)", gxt_allocs);
  a0 = gxt_allocs; f0 = gxt_frees;
  for (ri = 0; ri < 7; ri++) {
    int rate = rates[ri], frames[] = {rate / 100, 128, 97, rate / 50, 3000};
    for (k = 0; k < 400; k++) {
      int n = frames[k % 5];
      gen_noise(buf, n, 4000, k);
      if (k == 10) gx_ns_set_engine(st, GX_NS_ENGINE_OFF);
      if (k == 30) gx_ns_set_engine(st, GX_NS_ENGINE_RNNOISE);
      if (k == 50) gx_ns_set_bypass(st, 1);
      if (k == 70) gx_ns_set_bypass(st, 0);
      if (k == 90) gx_ns_set_agc_order(st, GX_NS_AGC_BEFORE_NS);
      if (k == 110) gx_ns_request_reset(st);
      if (k == 130) gx_ns_set_external_engine(st, &e);
      if (k == 131) gx_ns_set_engine(st, GX_NS_ENGINE_DFN3);
      if (k == 300) gx_ns_set_engine(st, GX_NS_ENGINE_RNNOISE);
      if (k == 330) gx_ns_set_external_engine(st, NULL);
      if (k == 350) { gx_ns_set_agc_order(st, GX_NS_AGC_AFTER_NS); gx_ns_set_agc(st, ri % 2); }
      if (k == 360) gx_ns_reset_stats(st);
      gx_ns_process(st, buf, n, rate);
      gx_ns_get_stats(st, &s);
      gx_ns_get_status(st, &t);
    }
  }
  CHECK(gxt_allocs == a0 && gxt_frees == f0, "hot path allocated: %d allocs, %d frees", gxt_allocs - a0, gxt_frees - f0);
  printf("no-alloc: %d allocations during create, 0 expected after; got %d\n", a0, gxt_allocs - a0);
  gx_ns_destroy(st);
  /* RNNoise keeps its FFT tables in a process-wide static (allocated once, by design upstream) */
  CHECK(gxt_allocs - gxt_frees <= 3, "destroy frees everything but RNNoise's shared FFT tables (%d/%d)", gxt_frees, gxt_allocs);
  a0 = gxt_allocs - gxt_frees;
  gx_ns_destroy(gx_ns_create(NULL));
  CHECK(gxt_allocs - gxt_frees == a0, "a second create/destroy leaks nothing");
  return TEST_DONE();
}

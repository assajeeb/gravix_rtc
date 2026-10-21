/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
#include "gx_ns_timer.h"
#include "gx_ns.h"
#include "test_util.h"

int main(void) {
  static gx_timer t;
  int i;
  gx_timer_init(&t, 8000);
  CHECK(gx_timer_percentile(&t, 0.5) == 0, "empty");
  for (i = 1; i <= 100; i++) gx_timer_add(&t, (uint32_t)i * 10); /* 10..1000 us */
  CHECK(gx_timer_percentile(&t, 0.50) == 500, "p50=%u", gx_timer_percentile(&t, 0.50));
  CHECK(gx_timer_percentile(&t, 0.95) == 950, "p95=%u", gx_timer_percentile(&t, 0.95));
  CHECK(gx_timer_percentile(&t, 0.99) == 990, "p99=%u", gx_timer_percentile(&t, 0.99));
  CHECK(atomic_load(&t.max_us) == 1000, "max");
  CHECK(atomic_load(&t.over) == 0, "over");
  /* coarse buckets: 10 us below 10 ms, 100 us below 100 ms; never above max */
  gx_timer_clear(&t);
  gx_timer_add(&t, 2345);
  CHECK(gx_timer_percentile(&t, 0.5) == 2345, "clamped to max: %u", gx_timer_percentile(&t, 0.5));
  gx_timer_add(&t, 2355); gx_timer_add(&t, 50000);
  CHECK(gx_timer_percentile(&t, 0.5) == 2359, "10us bucket edge: %u", gx_timer_percentile(&t, 0.5));
  /* watchdog: over budget + consecutive run */
  gx_timer_clear(&t);
  gx_timer_add(&t, 9000); gx_timer_add(&t, 9000); gx_timer_add(&t, 9000);
  CHECK(atomic_load(&t.consecutive) == 3, "consecutive=%u", atomic_load(&t.consecutive));
  gx_timer_add(&t, 100);
  CHECK(atomic_load(&t.consecutive) == 0 && atomic_load(&t.over) == 3, "run reset");
  gx_timer_add(&t, 200000);
  CHECK(gx_timer_percentile(&t, 1.0) == 100000 || gx_timer_percentile(&t, 1.0) == 200000, "overflow bucket");

  /* stats through the public API: real frames are timed */
  {
    struct gx_ns *st = gx_ns_create(NULL);
    float x[480] = {0};
    gx_ns_stats s;
    for (i = 0; i < 50; i++) gx_ns_process(st, x, 480, 48000);
    gx_ns_get_stats(st, &s);
    CHECK(s.frames == 50, "frames=%u", s.frames);
    CHECK(s.p50_us <= s.p95_us && s.p95_us <= s.p99_us && s.p99_us <= s.max_us, "ordered %u %u %u %u", s.p50_us, s.p95_us, s.p99_us, s.max_us);
    CHECK(s.max_us < 8000, "rnnoise frame well under budget on host: %u us", s.max_us);
    printf("host frame time (rnnoise, 48k/480): p50=%u p95=%u p99=%u max=%u us\n", s.p50_us, s.p95_us, s.p99_us, s.max_us);
    gx_ns_reset_stats(st);
    gx_ns_process(st, x, 480, 48000);
    gx_ns_get_stats(st, &s);
    CHECK(s.frames == 1, "reset_stats: frames=%u", s.frames);
    gx_ns_destroy(st);
  }
  return TEST_DONE();
}

/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
#include "gx_ns_timer.h"

#include <time.h>

#if defined(__EMSCRIPTEN__)
#include <emscripten.h>
#elif defined(__APPLE__)
#include <mach/mach_time.h>
#endif

static int bucket_of(uint32_t us) {
  if (us < 1000) return (int)us;
  if (us < 10000) return 1000 + (int)((us - 1000) / 10);
  if (us < 100000) return 1900 + (int)((us - 10000) / 100);
  return GX_TIMER_BUCKETS - 1;
}

static uint32_t upper_edge(int b) {
  if (b < 1000) return (uint32_t)b;
  if (b < 1900) return 1000u + (uint32_t)(b - 1000) * 10u + 9u;
  if (b < 2800) return 10000u + (uint32_t)(b - 1900) * 100u + 99u;
  return 100000u;
}

void gx_timer_clear(gx_timer *t) {
  int i;
  for (i = 0; i < GX_TIMER_BUCKETS; i++) atomic_store_explicit(&t->hist[i], 0, memory_order_relaxed);
  atomic_store_explicit(&t->count, 0, memory_order_relaxed);
  atomic_store_explicit(&t->max_us, 0, memory_order_relaxed);
  atomic_store_explicit(&t->over, 0, memory_order_relaxed);
  atomic_store_explicit(&t->consecutive, 0, memory_order_relaxed);
}

void gx_timer_init(gx_timer *t, uint32_t budget_us) {
  t->budget_us = budget_us;
  gx_timer_clear(t);
}

void gx_timer_add(gx_timer *t, uint32_t us) {
  int b = bucket_of(us);
  atomic_fetch_add_explicit(&t->hist[b], 1, memory_order_relaxed);
  atomic_fetch_add_explicit(&t->count, 1, memory_order_relaxed);
  if (us > atomic_load_explicit(&t->max_us, memory_order_relaxed))
    atomic_store_explicit(&t->max_us, us, memory_order_relaxed);
  if (us > t->budget_us) {
    atomic_fetch_add_explicit(&t->over, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&t->consecutive, 1, memory_order_relaxed);
  } else {
    atomic_store_explicit(&t->consecutive, 0, memory_order_relaxed);
  }
}

uint32_t gx_timer_percentile(gx_timer *t, double p) {
  uint32_t total = 0, acc = 0, need;
  int i;
  for (i = 0; i < GX_TIMER_BUCKETS; i++) total += atomic_load_explicit(&t->hist[i], memory_order_relaxed);
  if (total == 0) return 0;
  need = (uint32_t)(p * (double)total + 0.999999);
  if (need < 1) need = 1;
  if (need > total) need = total;
  for (i = 0; i < GX_TIMER_BUCKETS; i++) {
    acc += atomic_load_explicit(&t->hist[i], memory_order_relaxed);
    if (acc >= need) {
      uint32_t e = upper_edge(i), m = atomic_load_explicit(&t->max_us, memory_order_relaxed);
      return e < m ? e : m;
    }
  }
  return atomic_load_explicit(&t->max_us, memory_order_relaxed);
}

uint64_t gx_timer_now_ns(void) {
#if defined(__EMSCRIPTEN__)
  return (uint64_t)(emscripten_get_now() * 1e6);
#elif defined(__APPLE__)
  static mach_timebase_info_data_t tb; /* filled on first use (gx_ns_create calls this) */
  if (tb.denom == 0) mach_timebase_info(&tb);
  return mach_absolute_time() * tb.numer / tb.denom;
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

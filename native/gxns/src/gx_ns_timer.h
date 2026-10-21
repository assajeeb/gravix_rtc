/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Frame-time histogram (internal). Lock-free: one writer (audio thread),
 * readers on any thread with relaxed atomics. Resolution: 1 us below 1 ms,
 * 10 us below 10 ms, 100 us below 100 ms. */
#ifndef GX_NS_TIMER_H
#define GX_NS_TIMER_H

#include <stdatomic.h>
#include <stdint.h>

#define GX_TIMER_BUCKETS (1000 + 900 + 900 + 1)

typedef struct {
  _Atomic uint32_t hist[GX_TIMER_BUCKETS];
  _Atomic uint32_t count;
  _Atomic uint32_t max_us;
  _Atomic uint32_t over;
  _Atomic uint32_t consecutive;
  uint32_t budget_us;
} gx_timer;

void gx_timer_init(gx_timer *t, uint32_t budget_us);
void gx_timer_clear(gx_timer *t);
void gx_timer_add(gx_timer *t, uint32_t us);
/* p in (0, 1]; returns the upper edge of the bucket holding that percentile. */
uint32_t gx_timer_percentile(gx_timer *t, double p);
uint64_t gx_timer_now_ns(void);

#endif

/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
#include <stdatomic.h>
#include <stdlib.h>
#include "include/gxns_ios.h"

struct gxns_flag { _Atomic int32_t v; };

gxns_flag *gxns_flag_new(int32_t initial) {
  gxns_flag *f = (gxns_flag *)malloc(sizeof(gxns_flag));
  if (f) atomic_init(&f->v, initial);
  return f;
}
void gxns_flag_free(gxns_flag *f) { free(f); }
int32_t gxns_flag_get(const gxns_flag *f) {
  return atomic_load_explicit((_Atomic int32_t *)&f->v, memory_order_acquire);
}
void gxns_flag_set(gxns_flag *f, int32_t v) { atomic_store_explicit(&f->v, v, memory_order_release); }

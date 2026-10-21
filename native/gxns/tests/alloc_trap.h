/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Force-included (-include) into the gxns_alloctrap library: every heap call
 * goes through counters so test_noalloc can prove the hot path never allocates. */
#ifndef GX_ALLOC_TRAP_H
#define GX_ALLOC_TRAP_H
#include <stddef.h>
#include <stdlib.h>
void *gxt_malloc(size_t n);
void *gxt_calloc(size_t a, size_t b);
void *gxt_realloc(void *p, size_t n);
void gxt_free(void *p);
#define malloc gxt_malloc
#define calloc gxt_calloc
#define realloc gxt_realloc
#define free gxt_free
#endif

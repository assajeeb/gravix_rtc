/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
#include <stdlib.h>
int gxt_allocs = 0, gxt_frees = 0;
void *gxt_malloc(size_t n) { gxt_allocs++; return malloc(n); }
void *gxt_calloc(size_t a, size_t b) { gxt_allocs++; return calloc(a, b); }
void *gxt_realloc(void *p, size_t n) { gxt_allocs++; return realloc(p, n); }
void gxt_free(void *p) { if (p) gxt_frees++; free(p); }

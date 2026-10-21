/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Small helpers for the Swift processor: an atomic flag (Swift 5 has no
 * stdlib atomics) and the external-engine glue. */
#ifndef GXNS_IOS_H
#define GXNS_IOS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct gxns_flag gxns_flag;
gxns_flag *gxns_flag_new(int32_t initial);
void gxns_flag_free(gxns_flag *f);
int32_t gxns_flag_get(const gxns_flag *f);
void gxns_flag_set(gxns_flag *f, int32_t v);
#ifdef __cplusplus
}
#endif
#endif

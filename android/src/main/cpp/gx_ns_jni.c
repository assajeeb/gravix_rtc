/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/*
 * JNI bridge for GxNoiseProcessor.kt (com.gravitycompile.gravix_cloud.rtc.GxNsNative).
 * process() runs on WebRTC's audio thread: no allocation, no locks, no logging.
 */
#include <jni.h>
#include <stdint.h>
#include "gx_ns.h"

#define JNI_FN(name) Java_com_gravitycompile_gravix_1cloud_rtc_GxNsNative_##name
#define ST(h) ((struct gx_ns *)(intptr_t)(h))

JNIEXPORT jlong JNICALL JNI_FN(nativeCreate)(JNIEnv *env, jclass cls, jint engine, jint agcEnabled,
                                                                  jint agcOrder, jint watchdogUs, jint p95WindowBlocks) {
  gx_ns_config c;
  (void)env; (void)cls;
  gx_ns_default_config(&c);
  c.initial_engine = (gx_ns_engine)engine;
  c.agc_enabled = agcEnabled ? 1 : 0;
  c.agc_order = (gx_ns_agc_order)agcOrder;
  if (watchdogUs > 0) c.watchdog_us = watchdogUs;
  if (p95WindowBlocks > 0) c.ext_p95_window = p95WindowBlocks; /* studio rolling-p95 window (10 ms blocks) */
  c.max_external_latency = 1440; /* DFN3 standard: 30 ms (LL: 10 ms) */
  return (jlong)(intptr_t)gx_ns_create(&c);
}

JNIEXPORT void JNICALL JNI_FN(nativeDestroy)(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  if (h) gx_ns_destroy(ST(h));
}

/* In place on a direct ByteBuffer of `n` native-order floats (int16 scale).
 * Returns 0 ok, -1 unsupported rate, -2 not a direct buffer / too small. */
JNIEXPORT jint JNICALL JNI_FN(nativeProcess)(JNIEnv *env, jclass cls, jlong h, jobject buf, jint n,
                                                                   jint rate) {
  float *p;
  (void)cls;
  if (!h || n <= 0) return -2;
  p = (float *)(*env)->GetDirectBufferAddress(env, buf);
  if (!p || (*env)->GetDirectBufferCapacity(env, buf) < (jlong)n * 4) return -2;
  return gx_ns_process(ST(h), p, n, rate);
}

JNIEXPORT void JNICALL JNI_FN(nativeSetEngine)(JNIEnv *env, jclass cls, jlong h, jint e) {
  (void)env; (void)cls;
  if (h) gx_ns_set_engine(ST(h), (gx_ns_engine)e);
}

JNIEXPORT void JNICALL JNI_FN(nativeSetBypass)(JNIEnv *env, jclass cls, jlong h, jboolean b) {
  (void)env; (void)cls;
  if (h) gx_ns_set_bypass(ST(h), b ? 1 : 0);
}

JNIEXPORT void JNICALL JNI_FN(nativeSetAgc)(JNIEnv *env, jclass cls, jlong h, jboolean on, jint order) {
  (void)env; (void)cls;
  if (!h) return;
  gx_ns_set_agc_order(ST(h), (gx_ns_agc_order)order);
  gx_ns_set_agc(ST(h), on ? 1 : 0);
}

JNIEXPORT void JNICALL JNI_FN(nativeRequestReset)(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  if (h) gx_ns_request_reset(ST(h));
}

/* Studio attenuation limit (centi-dB, 0 = none) and rolling-p95 budget (us, 0 = off). */
JNIEXPORT void JNICALL JNI_FN(nativeSetStudioLimits)(JNIEnv *env, jclass cls, jlong h, jint attenCentiDb, jint p95BudgetUs) {
  (void)env; (void)cls;
  if (!h) return;
  gx_ns_set_atten_limit(ST(h), (float)attenCentiDb / 100.f);
  gx_ns_set_ext_p95_budget(ST(h), p95BudgetUs);
}

JNIEXPORT void JNICALL JNI_FN(nativeResetStats)(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  if (h) gx_ns_reset_stats(ST(h));
}

/* out[0..12] = frames, p50, p95, p99, max, over, consecutive, underflows, extErrors, switches,
 * studio rolling p95 us, studio slow (0/1), studio suppress (0/1); shorter arrays get a prefix (>= 10). */
JNIEXPORT void JNICALL JNI_FN(nativeStats)(JNIEnv *env, jclass cls, jlong h, jintArray out) {
  gx_ns_stats s;
  jint v[13];
  jsize len;
  (void)cls;
  if (!h || (len = (*env)->GetArrayLength(env, out)) < 10) return;
  gx_ns_get_stats(ST(h), &s);
  v[0] = (jint)s.frames; v[1] = (jint)s.p50_us; v[2] = (jint)s.p95_us; v[3] = (jint)s.p99_us; v[4] = (jint)s.max_us;
  v[5] = (jint)s.over_budget; v[6] = (jint)s.consecutive_over; v[7] = (jint)s.underflows; v[8] = (jint)s.ext_errors;
  v[9] = (jint)s.engine_switches;
  v[10] = (jint)s.ext_p95_us; v[11] = (jint)s.ext_slow; v[12] = (jint)s.ext_suppress;
  (*env)->SetIntArrayRegion(env, out, 0, len >= 13 ? 13 : len >= 12 ? 12 : 10, v);
}

/* out[0..6] = requested, active, crossfading, reason, rate, latencySamples, agcGainDb*100
 * (+ out[7] = preGainDb*100 when the array has 8; + out[8..10] = the APPLIED
 * pre-gain*100, applied AGC*100, pause attenuation*100 when it has 11: the
 * held values above are not what a pause gets); returns vad*1000 */
JNIEXPORT jint JNICALL JNI_FN(nativeStatus)(JNIEnv *env, jclass cls, jlong h, jintArray out) {
  gx_ns_status s;
  jint v[11];
  jsize len;
  (void)cls;
  if (!h || (len = (*env)->GetArrayLength(env, out)) < 7) return 0;
  gx_ns_get_status(ST(h), &s);
  v[0] = s.requested; v[1] = s.active; v[2] = s.crossfading; v[3] = s.reason; v[4] = s.rate; v[5] = s.latency_samples;
  v[6] = (jint)(s.agc_gain_db * 100.f); v[7] = (jint)(s.pregain_db * 100.f);
  v[8] = (jint)(s.pregain_applied_db * 100.f); v[9] = (jint)(s.agc_applied_db * 100.f); v[10] = (jint)(s.pause_att_db * 100.f);
  (*env)->SetIntArrayRegion(env, out, 0, len >= 11 ? 11 : len >= 8 ? 8 : 7, v);
  return (jint)(s.vad * 1000.f);
}

JNIEXPORT jstring JNICALL JNI_FN(nativeReasonName)(JNIEnv *env, jclass cls, jint r) {
  (void)cls;
  return (*env)->NewStringUTF(env, gx_ns_reason_name((gx_ns_reason)r));
}

/* Studio engine seam: `enginePtr` is a gx_ns_external_engine* owned by the
 * engine's own library (e.g. an ORT DFN3 build), or 0 to detach. The struct is
 * copied. Returns gx_ns_set_external_engine's result. */
JNIEXPORT jint JNICALL JNI_FN(nativeAttachExternal)(JNIEnv *env, jclass cls, jlong h, jlong enginePtr) {
  (void)env; (void)cls;
  if (!h) return -1;
  return gx_ns_set_external_engine(ST(h), (const gx_ns_external_engine *)(intptr_t)enginePtr);
}

JNIEXPORT jint JNICALL JNI_FN(nativeBlocks)(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  return h ? (jint)gx_ns_blocks_processed(ST(h)) : 0;
}

/* Pre-gain the core settles on for speech at `db` dBFS (studio benchmark input). */
JNIEXPORT jfloat JNICALL JNI_FN(nativePregainForLevel)(JNIEnv *env, jclass cls, jfloat db) {
  (void)env; (void)cls;
  return gx_ns_pregain_for_level(db);
}

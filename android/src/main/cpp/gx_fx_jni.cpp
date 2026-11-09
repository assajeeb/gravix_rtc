// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.
// JNI bridge for GxVoiceFx.kt.
#include <jni.h>
#include "gx_fx.h"
#define JNI_FN(n) Java_com_gravitycompile_gravix_1cloud_rtc_GxVoiceFx_##n
#define FX(h) reinterpret_cast<gx_fx *>(h)
extern "C" {
JNIEXPORT jlong JNICALL JNI_FN(nativeCreate)(JNIEnv *, jclass) { return reinterpret_cast<jlong>(gx_fx_create()); }
JNIEXPORT jint JNICALL JNI_FN(nativeSetPreset)(JNIEnv *, jclass, jlong h, jint p) { return h ? gx_fx_set_preset(FX(h), p) : -1; }
JNIEXPORT void JNICALL JNI_FN(nativeRebuild)(JNIEnv *, jclass, jlong h) { if (h) gx_fx_rebuild(FX(h)); }
JNIEXPORT void JNICALL JNI_FN(nativeSetBypass)(JNIEnv *, jclass, jlong h, jboolean on) { if (h) gx_fx_set_bypass(FX(h), on); }
JNIEXPORT void JNICALL JNI_FN(nativeSetWatchdog)(JNIEnv *, jclass, jlong h, jint us, jint n) { if (h) gx_fx_set_watchdog(FX(h), us, n); }
JNIEXPORT jint JNICALL JNI_FN(nativeProcess)(JNIEnv *env, jclass, jlong h, jobject buf, jint n, jint rate) {
  if (!h || n <= 0) return GX_FX_PASSTHROUGH;
  auto *p = static_cast<float *>(env->GetDirectBufferAddress(buf));
  if (!p || env->GetDirectBufferCapacity(buf) < static_cast<jlong>(n) * 4) return GX_FX_PASSTHROUGH;
  return gx_fx_process(FX(h), p, n, rate);
}
// requested, active, rate, bypass, watchdog, latency_ms, frames, over, max_us
JNIEXPORT void JNICALL JNI_FN(nativeStatus)(JNIEnv *env, jclass, jlong h, jintArray out) {
  gx_fx_status s = {};
  if (h) gx_fx_get_status(FX(h), &s);
  jint v[9] = {s.requested, s.active, s.rate, s.bypass, s.watchdog, s.latency_ms, (jint)s.frames, (jint)s.over, (jint)s.max_us};
  env->SetIntArrayRegion(out, 0, 9, v);
}
// blocks, p50, p95, max, latency
JNIEXPORT jint JNICALL JNI_FN(nativeBenchmark)(JNIEnv *env, jclass, jint p, jint rate, jint sec, jintArray out) {
  gx_fx_bench b = {};
  int rc = gx_fx_benchmark(p, rate, sec, &b);
  jint v[5] = {b.blocks, b.p50_us, b.p95_us, b.max_us, b.latency_ms};
  env->SetIntArrayRegion(out, 0, 5, v);
  return rc;
}
}

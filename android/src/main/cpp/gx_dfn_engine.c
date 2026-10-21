/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/*
 * libgxns_dfn.so (arm64-v8a): DeepFilterNet3 streaming engine on a minimal
 * ONNX Runtime (bundled libonnxruntime.so, ORT 1.31.0), exposed as a
 * gx_ns_external_engine for libgxns (gx_ns_set_external_engine).
 *
 * Model contract (release manifest, reference_stream.py): 48 kHz mono, 480
 * float samples in [-1, 1] -> 480 out per call; every input except
 * input_frame / gx_dft_cos / gx_dft_sin is a state fed back from the output
 * `new_<name>`. All tensors are bound to buffers allocated at load (two
 * ping-pong sets for the states), so a frame only copies 480 samples in and
 * out around OrtApi::Run (which may still allocate internally).
 */
#include <jni.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <android/log.h>
#include "gx_ns.h"
#include "onnxruntime_c_api.h"

#define TAG "GravixNS"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define MAXT 24
#define NFFT 960
#define NBIN 481

typedef struct {
  gx_ns_external_engine ext; /* first: the pointer handed to gx_ns */
  const OrtApi *api;
  OrtEnv *env;
  OrtSession *sess;
  OrtMemoryInfo *mem;
  size_t n_in, n_out;
  char *in_names[MAXT], *out_names[MAXT];
  float *in_buf[2][MAXT];  /* per parity: state inputs alias the other parity's outputs */
  size_t in_len[MAXT];
  int out_state_of[MAXT];  /* output j -> input index of its state, -1 = audio out */
  int frame_in, cos_in, sin_in;
  OrtValue *in_val[2][MAXT], *out_val[2][MAXT];
  float *audio_out;
  float *tables;
  int parity;
  int failed;
} gxdfn;

static void drop(const OrtApi *a, OrtStatus *s) {
  if (s) a->ReleaseStatus(s);
}

static const OrtApi *ort(void) { return OrtGetApiBase()->GetApi(ORT_API_VERSION); }

static int ok(gxdfn *e, OrtStatus *s, const char *what) {
  if (!s) return 1;
  LOGW("[GravixNS] dfn3 %s: %s", what, e->api->GetErrorMessage(s));
  e->api->ReleaseStatus(s);
  return 0;
}

static void init_states(gxdfn *e, int parity) {
  size_t i, k;
  for (i = 0; i < e->n_in; i++) {
    float *b = e->in_buf[parity][i];
    if ((int)i == e->frame_in || (int)i == e->cos_in || (int)i == e->sin_in) continue;
    memset(b, 0, sizeof(float) * e->in_len[i]);
    if (!strcmp(e->in_names[i], "erb_norm_state"))
      for (k = 0; k < e->in_len[i]; k++) b[k] = -60.f + (-30.f) * (float)k / (float)(e->in_len[i] - 1);
    else if (!strcmp(e->in_names[i], "band_unit_norm_state"))
      for (k = 0; k < e->in_len[i]; k++) b[k] = 0.001f + (0.0001f - 0.001f) * (float)k / (float)(e->in_len[i] - 1);
  }
}

static int dfn_process(void *user, float *out, const float *in, int n) {
  gxdfn *e = (gxdfn *)user;
  OrtStatus *s;
  int p = e->parity;
  if (e->failed || n != GX_NS_BLOCK) return -1;
  memcpy(e->in_buf[p][e->frame_in], in, sizeof(float) * GX_NS_BLOCK);
  s = e->api->Run(e->sess, NULL, (const char *const *)e->in_names, (const OrtValue *const *)e->in_val[p], e->n_in,
                  (const char *const *)e->out_names, e->n_out, e->out_val[p]);
  if (s) {
    e->failed = 1;
    ok(e, s, "run");
    return -1;
  }
  memcpy(out, e->audio_out, sizeof(float) * GX_NS_BLOCK);
  e->parity = p ^ 1;
  return 0;
}

static void dfn_reset(void *user) {
  gxdfn *e = (gxdfn *)user;
  init_states(e, e->parity);
}

static void dfn_free(gxdfn *e) {
  size_t i;
  int p;
  OrtAllocator *al = NULL;
  if (!e) return;
  if (e->api) {
    drop(e->api, e->api->GetAllocatorWithDefaultOptions(&al));
    for (p = 0; p < 2; p++)
      for (i = 0; i < MAXT; i++) {
        if (e->in_val[p][i]) e->api->ReleaseValue(e->in_val[p][i]);
        if (e->out_val[p][i]) e->api->ReleaseValue(e->out_val[p][i]);
      }
    for (i = 0; i < MAXT; i++) {
      if (al && e->in_names[i]) drop(e->api, e->api->AllocatorFree(al, e->in_names[i]));
      if (al && e->out_names[i]) drop(e->api, e->api->AllocatorFree(al, e->out_names[i]));
    }
    if (e->sess) e->api->ReleaseSession(e->sess);
    if (e->mem) e->api->ReleaseMemoryInfo(e->mem);
    if (e->env) e->api->ReleaseEnv(e->env);
  }
  for (p = 0; p < 2; p++)
    for (i = 0; i < MAXT; i++)
      if (e->in_buf[p][i] && (int)i != e->cos_in && (int)i != e->sin_in) free(e->in_buf[p][i]);
  free(e->audio_out);
  free(e->tables);
  free(e);
}

static int tensor_shape(gxdfn *e, OrtTypeInfo *ti, int64_t *dims, size_t *nd, size_t *len) {
  const OrtTensorTypeAndShapeInfo *tsi;
  size_t i;
  if (!ok(e, e->api->CastTypeInfoToTensorInfo(ti, &tsi), "cast")) return 0;
  if (!ok(e, e->api->GetDimensionsCount(tsi, nd), "ndims") || *nd > 8) return 0;
  if (!ok(e, e->api->GetDimensions(tsi, dims, *nd), "dims")) return 0;
  *len = 1;
  for (i = 0; i < *nd; i++) {
    if (dims[i] <= 0) dims[i] = 1;
    *len *= (size_t)dims[i];
  }
  return 1;
}

/* Loads the model (bytes are copied by ORT) and binds every tensor.
 * latency = the model's algorithmic delay at 48 kHz (std 1440, LL 480). */
static gxdfn *dfn_create(const void *model, size_t bytes, int latency) {
  gxdfn *e = (gxdfn *)calloc(1, sizeof(gxdfn));
  OrtSessionOptions *so = NULL;
  OrtAllocator *al = NULL;
  size_t i, j;
  int p;
  if (!e) return NULL;
  e->api = ort();
  if (!e->api) { free(e); return NULL; }
  e->frame_in = e->cos_in = e->sin_in = -1;
  if (!ok(e, e->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "gxns", &e->env), "env")) goto fail;
  if (!ok(e, e->api->CreateSessionOptions(&so), "options")) goto fail;
  drop(e->api, e->api->SetIntraOpNumThreads(so, 1));
  drop(e->api, e->api->SetInterOpNumThreads(so, 1));
  drop(e->api, e->api->AddSessionConfigEntry(so, "session.load_model_format", "ORT"));
  drop(e->api, e->api->AddSessionConfigEntry(so, "session.intra_op.allow_spinning", "0"));
  if (!ok(e, e->api->CreateSessionFromArray(e->env, model, bytes, so, &e->sess), "load")) goto fail;
  e->api->ReleaseSessionOptions(so);
  so = NULL;
  if (!ok(e, e->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &e->mem), "meminfo")) goto fail;
  if (!ok(e, e->api->GetAllocatorWithDefaultOptions(&al), "allocator")) goto fail;
  if (!ok(e, e->api->SessionGetInputCount(e->sess, &e->n_in), "inputs") ||
      !ok(e, e->api->SessionGetOutputCount(e->sess, &e->n_out), "outputs") || e->n_in > MAXT || e->n_out > MAXT)
    goto fail;

  /* DFT tables, shared by both parities */
  e->tables = (float *)malloc(sizeof(float) * NFFT * NBIN * 2);
  if (!e->tables) goto fail;
  for (i = 0; i < NFFT; i++)
    for (j = 0; j < NBIN; j++) {
      double a = (double)((i * j) % NFFT) * (2.0 * M_PI / NFFT);
      e->tables[i * NBIN + j] = (float)cos(a);
      e->tables[NFFT * NBIN + i * NBIN + j] = (float)sin(a);
    }

  for (i = 0; i < e->n_in; i++) {
    OrtTypeInfo *ti = NULL;
    int64_t dims[8];
    size_t nd, len;
    if (!ok(e, e->api->SessionGetInputName(e->sess, i, al, &e->in_names[i]), "in name")) goto fail;
    if (!ok(e, e->api->SessionGetInputTypeInfo(e->sess, i, &ti), "in type")) goto fail;
    if (!tensor_shape(e, ti, dims, &nd, &len)) { e->api->ReleaseTypeInfo(ti); goto fail; }
    e->api->ReleaseTypeInfo(ti);
    e->in_len[i] = len;
    if (!strcmp(e->in_names[i], "input_frame")) e->frame_in = (int)i;
    else if (!strcmp(e->in_names[i], "gx_dft_cos")) e->cos_in = (int)i;
    else if (!strcmp(e->in_names[i], "gx_dft_sin")) e->sin_in = (int)i;
    for (p = 0; p < 2; p++) {
      if ((int)i == e->cos_in) e->in_buf[p][i] = e->tables;
      else if ((int)i == e->sin_in) e->in_buf[p][i] = e->tables + NFFT * NBIN;
      else if (!(e->in_buf[p][i] = (float *)calloc(len, sizeof(float)))) goto fail;
      if (((int)i == e->cos_in || (int)i == e->sin_in) && len != NFFT * NBIN) goto fail;
      if (!ok(e, e->api->CreateTensorWithDataAsOrtValue(e->mem, e->in_buf[p][i], len * sizeof(float), dims, nd,
                                                          ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &e->in_val[p][i]),
              "in value"))
        goto fail;
    }
  }
  if (e->frame_in < 0 || e->cos_in < 0 || e->sin_in < 0 || e->in_len[e->frame_in] != GX_NS_BLOCK) goto fail;

  e->audio_out = (float *)calloc(GX_NS_BLOCK, sizeof(float));
  if (!e->audio_out) goto fail;
  for (j = 0; j < e->n_out; j++) {
    OrtTypeInfo *ti = NULL;
    int64_t dims[8];
    size_t nd, len;
    if (!ok(e, e->api->SessionGetOutputName(e->sess, j, al, &e->out_names[j]), "out name")) goto fail;
    if (!ok(e, e->api->SessionGetOutputTypeInfo(e->sess, j, &ti), "out type")) goto fail;
    if (!tensor_shape(e, ti, dims, &nd, &len)) { e->api->ReleaseTypeInfo(ti); goto fail; }
    e->api->ReleaseTypeInfo(ti);
    e->out_state_of[j] = -1;
    if (!strncmp(e->out_names[j], "new_", 4)) {
      for (i = 0; i < e->n_in; i++)
        if (!strcmp(e->in_names[i], e->out_names[j] + 4)) e->out_state_of[j] = (int)i;
      if (e->out_state_of[j] < 0 || e->in_len[e->out_state_of[j]] != len) goto fail;
    } else if (len != GX_NS_BLOCK) {
      goto fail;
    }
    for (p = 0; p < 2; p++) {
      /* parity p reads states from in_buf[p] and writes them into in_buf[p^1] */
      float *dst = e->out_state_of[j] >= 0 ? e->in_buf[p ^ 1][e->out_state_of[j]] : e->audio_out;
      if (!ok(e, e->api->CreateTensorWithDataAsOrtValue(e->mem, dst, len * sizeof(float), dims, nd,
                                                          ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &e->out_val[p][j]),
              "out value"))
        goto fail;
    }
  }
  init_states(e, 0);
  e->ext.process = dfn_process;
  e->ext.reset = dfn_reset;
  e->ext.user = e;
  e->ext.latency_samples = latency;
  return e;
fail:
  if (so) e->api->ReleaseSessionOptions(so);
  dfn_free(e);
  return NULL;
}

/* ---------------- JNI (com.gravitycompile.gravix_cloud.rtc.GxNsStudio) ---------------- */
#define JNI_FN(name) Java_com_gravitycompile_gravix_1cloud_rtc_GxNsStudio_##name

/* model: direct ByteBuffer with the .ort bytes. Returns the gx_ns_external_engine* or 0. */
JNIEXPORT jlong JNICALL JNI_FN(nativeCreate)(JNIEnv *env, jclass cls, jobject model, jint latency) {
  void *p = (*env)->GetDirectBufferAddress(env, model);
  jlong n = (*env)->GetDirectBufferCapacity(env, model);
  (void)cls;
  if (!p || n <= 0) return 0;
  return (jlong)(intptr_t)dfn_create(p, (size_t)n, latency);
}

/* Only once gx_ns no longer references it (detached + a block processed, or never attached). */
JNIEXPORT void JNICALL JNI_FN(nativeDestroy)(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  dfn_free((gxdfn *)(intptr_t)h);
}

static double now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static int cmp_d(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

/*
 * First-run benchmark (plan §4) on its own engine instance, on the calling
 * (background) thread: `warm` frames, then `frames` timed frames of the clip
 * (int16 PCM, looped). out[0..5] = p50 us, p95 us, max us, in rms dBFS*100,
 * out rms dBFS*100, parity SNR dB*100 vs `ref` (int16, the reference loop's
 * output for the same clip; 0 len = not compared -> -99900).
 */
JNIEXPORT jint JNICALL JNI_FN(nativeBenchmark)(JNIEnv *env, jclass cls, jlong h, jshortArray clip, jshortArray ref,
                                               jint warm, jint frames, jintArray out) {
  gxdfn *e = (gxdfn *)(intptr_t)h;
  jint n = (*env)->GetArrayLength(env, clip), nref = ref ? (*env)->GetArrayLength(env, ref) : 0;
  jshort *c, *r = NULL;
  double *t;
  float in[GX_NS_BLOCK], o[GX_NS_BLOCK];
  double si = 0, so_ = 0, sn = 0, ss = 0;
  long cnt = 0;
  int f, k, total = warm + frames, rc = 0, nb = n / GX_NS_BLOCK;
  jint v[6];
  (void)cls;
  if (!e || nb <= 0 || frames <= 0) return -1;
  t = (double *)malloc(sizeof(double) * frames);
  if (!t) return -1;
  c = (*env)->GetShortArrayElements(env, clip, NULL);
  if (nref) r = (*env)->GetShortArrayElements(env, ref, NULL);
  init_states(e, e->parity);
  for (f = 0; f < total; f++) {
    int b = f % nb;
    double t0;
    for (k = 0; k < GX_NS_BLOCK; k++) in[k] = c[b * GX_NS_BLOCK + k] / 32768.f;
    t0 = now_us();
    if (dfn_process(e, o, in, GX_NS_BLOCK) != 0) { rc = -2; break; }
    if (f >= warm) t[f - warm] = now_us() - t0;
    for (k = 0; k < GX_NS_BLOCK; k++) {
      if (!isfinite(o[k])) { rc = -3; break; }
      si += (double)in[k] * in[k];
      so_ += (double)o[k] * o[k];
      cnt++;
    }
    /* parity: the first pass over the clip from a clean state matches the reference loop */
    if (r && f < nb && (f + 1) * GX_NS_BLOCK <= nref)
      for (k = 0; k < GX_NS_BLOCK; k++) {
        double d = o[k] - r[f * GX_NS_BLOCK + k] / 32768.0;
        sn += d * d;
        ss += (double)(r[f * GX_NS_BLOCK + k] / 32768.0) * (r[f * GX_NS_BLOCK + k] / 32768.0);
      }
    if (rc) break;
  }
  (*env)->ReleaseShortArrayElements(env, clip, c, JNI_ABORT);
  if (r) (*env)->ReleaseShortArrayElements(env, ref, r, JNI_ABORT);
  init_states(e, e->parity);
  if (rc == 0) {
    qsort(t, frames, sizeof(double), cmp_d);
    v[0] = (jint)t[frames / 2];
    v[1] = (jint)t[(frames * 95) / 100];
    v[2] = (jint)t[frames - 1];
    v[3] = (jint)(100.0 * 10.0 * log10(si / (cnt ? cnt : 1) + 1e-20));
    v[4] = (jint)(100.0 * 10.0 * log10(so_ / (cnt ? cnt : 1) + 1e-20));
    v[5] = ss > 0 ? (jint)(100.0 * 10.0 * log10(ss / (sn + 1e-20))) : -99900;
    (*env)->SetIntArrayRegion(env, out, 0, 6, v);
  }
  free(t);
  return rc;
}

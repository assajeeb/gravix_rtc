/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/*
 * gx_ns — platform-independent core of Gravix on-device noise suppression.
 *
 * One instance per capture stream (mono). Feed it the APM capture frames
 * (any size, any of 8/16/24/32/44.1/48 kHz) in INT16 SCALE floats
 * ([-32768, 32767], as WebRTC's capturePostProcessing delivers them); it
 * returns the same number of samples, processed, in place, with a fixed
 * latency (gx_ns_latency_samples()).
 *
 * Inside, everything runs at 48 kHz in 10 ms (480-sample) blocks:
 *
 *   in(R) -> [up R->48k] -> FIFO -> block 480 --+-- dry (delay-compensated)
 *                                               +-- RNNoise (int16 scale)
 *                                               +-- external engine (DFN3,
 *                                                   [-1,1] scale, optional)
 *   (the block first passes the PRE-GAIN: a speech-gated level normaliser to
 *    ~-26 dBFS, 0..+30 dB, soft-limited, so every engine sees speech at a
 *    sane level; DFN3 erases quiet input, device run 2026-10-21)
 *            -> 20 ms complementary crossfade between the sources
 *            -> VAD-gated AGC (before or after NS) -> peak limiter
 *            -> [down 48k->R] -> FIFO -> out(R)
 *
 * Threads: gx_ns_process() runs on the real-time audio thread and never
 * allocates or locks. Every gx_ns_set_* / gx_ns_request_* call is an atomic
 * store that is safe from any thread; it takes effect at the next 10 ms block.
 * gx_ns_create() / gx_ns_destroy() allocate and must not race with
 * gx_ns_process() on the same instance.
 */
#ifndef GX_NS_H
#define GX_NS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__) || defined(__clang__)
#define GX_NS_API __attribute__((visibility("default")))
#else
#define GX_NS_API
#endif

#define GX_NS_ENGINE_RATE 48000
#define GX_NS_BLOCK 480 /* 10 ms at 48 kHz */

/* Engines (what produces the output). */
typedef enum {
  GX_NS_ENGINE_OFF = 0,     /* dry, delay-compensated */
  GX_NS_ENGINE_RNNOISE = 1, /* "standard" */
  GX_NS_ENGINE_DFN3 = 2     /* "studio", via gx_ns_set_external_engine() */
} gx_ns_engine;

/* Where OUR small digital AGC sits. Mapping of the SDK option (Dart/TS agcOrder):
 *   ownAfterNs     -> agc_enabled=1, GX_NS_AGC_AFTER_NS; WebRTC software NS + AGC off
 *   webrtcBeforeNs -> agc_enabled=0 (plan option B: WebRTC's AGC stays on, our NS after it)
 * GX_NS_AGC_BEFORE_NS (our AGC ahead of our NS) exists only for loudness A/B probes. */
typedef enum {
  GX_NS_AGC_AFTER_NS = 0,  /* AEC -> our NS -> our AGC (Agora/ZEGO style, plan option A) */
  GX_NS_AGC_BEFORE_NS = 1  /* our AGC -> our NS (A/B probe only) */
} gx_ns_agc_order;

/* The default order. ONE place to flip it in C; Dart
 * (kGravixNsDefaultAgcOrder) and TS (GRAVIX_NS_DEFAULT_AGC_ORDER) mirror it and
 * test/fixtures/ns_policy_cases.json pins all three to the same value. */
#define GX_NS_DEFAULT_AGC_ORDER GX_NS_AGC_AFTER_NS

/* Studio (DFN3) attenuation limit: the external engine's output is mixed with
 * the delay-aligned dry signal so noise is attenuated by at most this many dB
 * (DeepFilterNet's atten_lim; out = (1-g)*ext + g*dry, g = 10^(-dB/20)).
 * 0 = no limit. 40 dB: the 2026-10-21 sweep (dpdfnet-spike/tune) kept speech
 * level and PESQ unchanged vs no limit while pauses stay >= 20 dB quieter.
 * Mirrored by Dart (kGravixNsDefaultStudioAttenLimitDb) and TS
 * (GRAVIX_NS_DEFAULT_STUDIO_ATTEN_LIMIT_DB); the shared fixture pins all three. */
#define GX_NS_DEFAULT_ATTEN_LIM_DB 40
/* Mid-call studio fallback: rolling p95 of the external engine's per-block time
 * over the last ext_p95_window blocks (200 = 2 s); above the budget the core
 * switches to RNNoise (reason GX_NS_REASON_EXT_SLOW) until an engine is
 * (re)attached. Pinned by the shared fixture like the attenuation limit. */
#define GX_NS_DEFAULT_EXT_P95_BUDGET_US 3000
#define GX_NS_DEFAULT_EXT_P95_WINDOW 200
#define GX_NS_EXT_P95_WINDOW_MAX 1000
/* Pre-gain (before NS, every engine; owner 2026-10-21 "AEC -> pre-gain -> NS ->
 * our AGC"): boost-only speech-level normaliser. Gain = target - speech level,
 * clamped to [0, max]; fast attack / slow release level tracking, updated only
 * on speech blocks (held in pauses: no noise pumping), soft limiter after it.
 * Off while the engine is off or music bypass runs. */
#define GX_NS_DEFAULT_PREGAIN_TARGET_DBFS (-26)
#define GX_NS_DEFAULT_PREGAIN_MAX_DB 30
/* Our AGC after NS: speech target / max gain. -14 dBFS (block RMS of speech)
 * lands the sent level within ~3 dB of WebRTC's own AGC (device run 2026-10-21:
 * WebRTC -10 dB active speech vs ours -31 with the old -18 / 12 dB). */
#define GX_NS_DEFAULT_AGC_TARGET_DBFS (-14)
#define GX_NS_DEFAULT_AGC_MAX_GAIN_DB 24
/* Live studio guard: if the external engine's output speech energy stays this
 * many dB under its input for GX_NS_EXT_SUPPRESS_BLOCKS speech blocks (2 s of
 * speech), the core falls back to RNNoise (reason "studio_suppress") until an
 * engine is re-attached. */
#define GX_NS_EXT_SUPPRESS_DB 20
#define GX_NS_EXT_SUPPRESS_BLOCKS 200
#define GX_NS_EXT_VS_RNN_DB 10 /* ... or this far under RNNoise (its shadow) on the same speech blocks */

/* Why the active engine differs from the requested one (gx_ns_status.reason). */
typedef enum {
  GX_NS_REASON_OK = 0,
  GX_NS_REASON_BYPASS = 1,       /* music bypass */
  GX_NS_REASON_NO_EXTERNAL = 2,  /* DFN3 requested but no engine attached */
  GX_NS_REASON_EXT_ERROR = 3,    /* external engine returned an error */
  GX_NS_REASON_DELAY_PENDING = 4, /* waiting for a quiet block to change delay */
  GX_NS_REASON_EXT_SLOW = 5,      /* studio rolling p95 over budget -> RNNoise ("studio_slow") */
  GX_NS_REASON_EXT_SUPPRESS = 6   /* studio output speech collapsed vs its input -> RNNoise ("studio_suppress") */
} gx_ns_reason;

/* External (studio) engine, e.g. DFN3. Called on the audio thread with one
 * 480-sample block at 48 kHz in [-1, 1] scale; must not allocate. Returns 0 on
 * success; non-zero makes the core fall back to RNNoise at once
 * (reason GX_NS_REASON_EXT_ERROR). latency_samples = its algorithmic delay at
 * 48 kHz; the core delays the other paths to match (delay compensation). */
typedef struct {
  int (*process)(void *user, float *out, const float *in, int n);
  void (*reset)(void *user); /* optional: clear state (route change); may be NULL */
  void *user;
  int latency_samples;
} gx_ns_external_engine;

typedef struct {
  int max_frame_samples;   /* largest frame per gx_ns_process call (any rate); larger calls are chunked. default 2048 */
  int crossfade_ms;        /* default 20 */
  int resampler_quality;   /* speex 0..10, default 5 */
  gx_ns_engine initial_engine; /* default RNNOISE; audible from the first block (no crossfade from dry) */
  int agc_enabled;         /* default 1 */
  gx_ns_agc_order agc_order; /* default GX_NS_DEFAULT_AGC_ORDER */
  float agc_target_dbfs;   /* speech RMS target, default GX_NS_DEFAULT_AGC_TARGET_DBFS */
  float agc_max_gain_db;   /* default GX_NS_DEFAULT_AGC_MAX_GAIN_DB */
  float agc_min_gain_db;   /* default -10 */
  float limiter_dbfs;      /* peak ceiling, default -1 */
  int watchdog_us;         /* frame time counted as over budget, default 8000 */
  int max_external_latency;/* largest external latency to support (48 kHz samples), default 960 */
  float ext_atten_lim_db;  /* studio attenuation limit, default GX_NS_DEFAULT_ATTEN_LIM_DB; 0 = none */
  int ext_p95_budget_us;   /* studio rolling-p95 budget, default GX_NS_DEFAULT_EXT_P95_BUDGET_US; 0 = off */
  int ext_p95_window;      /* blocks in the rolling window, default GX_NS_DEFAULT_EXT_P95_WINDOW (2 s), max GX_NS_EXT_P95_WINDOW_MAX */
  int pregain_enabled;     /* default 1 */
  float pregain_target_dbfs; /* default GX_NS_DEFAULT_PREGAIN_TARGET_DBFS */
  float pregain_max_db;    /* default GX_NS_DEFAULT_PREGAIN_MAX_DB */
} gx_ns_config;

typedef struct {
  uint32_t frames;          /* gx_ns_process calls timed */
  uint32_t p50_us, p95_us, p99_us, max_us;
  uint32_t over_budget;     /* calls longer than watchdog_us */
  uint32_t consecutive_over;/* current run of over-budget calls (watchdog: >= 3 -> fallback) */
  uint32_t underflows;      /* output FIFO underflows (should stay 0) */
  uint32_t ext_errors;      /* external engine failures */
  uint32_t engine_switches; /* completed crossfades */
  uint32_t ext_p95_us;      /* studio engine: rolling p95 per-block time (last full window), 0 = none yet */
  uint32_t ext_slow;        /* studio demoted for its rolling p95 (sticky until re-attach) */
  uint32_t ext_suppress;    /* studio demoted: output speech collapsed (sticky until re-attach) */
} gx_ns_stats;

typedef struct {
  gx_ns_engine requested;
  gx_ns_engine active;      /* source currently audible (target once a fade ends) */
  int crossfading;
  gx_ns_reason reason;
  int rate;                 /* current I/O rate, 0 before the first frame */
  int latency_samples;      /* at `rate` */
  float vad;                /* last block voice probability 0..1 */
  float agc_gain_db;        /* the AGC's learnt (held) gain */
  float pregain_db;         /* the learnt (held) pre-gain (0 = unity) */
  /* What the last block actually got (2026-10-21): out of talk the boosts are
   * held but not applied (pause gate), and the pause expander attenuates. */
  float pregain_applied_db;
  float agc_applied_db;
  float pause_att_db;       /* pause expander attenuation (>= 0) */
  int talk;                 /* the talk detector: this block is talk (or its hangover) */
} gx_ns_status;

GX_NS_API void gx_ns_default_config(gx_ns_config *cfg);

/* Allocates everything (resamplers for every supported rate, FIFOs, RNNoise
 * state + FFT tables warm-up). NULL cfg = defaults. NULL on failure. */
GX_NS_API struct gx_ns *gx_ns_create(const gx_ns_config *cfg);
GX_NS_API void gx_ns_destroy(struct gx_ns *st);

/* Real-time path. Processes n mono samples in place (int16 scale). A change of
 * sample_rate (8000/16000/24000/32000/44100/48000) resets the stream state
 * without allocating and fades in over the crossfade time. Returns 0, or -1
 * for an unsupported rate (samples left untouched). */
GX_NS_API int gx_ns_process(struct gx_ns *st, float *samples, int n, int sample_rate);

/* Control (any thread, atomic, applied at the next 10 ms block). */
GX_NS_API void gx_ns_set_engine(struct gx_ns *st, gx_ns_engine engine);
GX_NS_API void gx_ns_set_bypass(struct gx_ns *st, int bypass);       /* music: crossfade to dry, our AGC to unity */
GX_NS_API void gx_ns_set_agc(struct gx_ns *st, int enabled);
GX_NS_API void gx_ns_set_agc_order(struct gx_ns *st, gx_ns_agc_order order);
GX_NS_API void gx_ns_request_reset(struct gx_ns *st);                /* route change: fade to dry, reset engine state, fade back (~40 ms) */
GX_NS_API void gx_ns_set_atten_limit(struct gx_ns *st, float db);    /* studio attenuation limit in dB; 0 = none */
GX_NS_API void gx_ns_set_ext_p95_budget(struct gx_ns *st, int us);   /* studio rolling-p95 budget; 0 = off */
GX_NS_API void gx_ns_reset_stats(struct gx_ns *st);
GX_NS_API void gx_ns_set_pregain(struct gx_ns *st, int enabled);

/* The pre-gain the core settles on for speech at `speech_dbfs` (default target
 * and max): what a studio benchmark applies to its input to test the engine at
 * the level it will really see. */
GX_NS_API float gx_ns_pregain_for_level(float speech_dbfs);

/* Delay-compensation hook. Attaching (non-NULL) raises the dry and RNNoise
 * delay to the engine's latency; detaching lowers it again. The delay change is
 * applied at the next quiet block (VAD low) with a 5 ms fade out/in, or after
 * 2 s at the latest. DFN3 becomes audible only after that. To detach safely:
 * gx_ns_set_external_engine(st, NULL), then wait until gx_ns_blocks_processed()
 * has advanced (or the audio thread is stopped) before freeing the engine.
 * The struct is copied. Returns -1 if latency_samples > max_external_latency. */
GX_NS_API int gx_ns_set_external_engine(struct gx_ns *st, const gx_ns_external_engine *eng);

GX_NS_API void gx_ns_get_stats(struct gx_ns *st, gx_ns_stats *out);
GX_NS_API void gx_ns_get_status(struct gx_ns *st, gx_ns_status *out);
GX_NS_API int gx_ns_latency_samples(struct gx_ns *st, int sample_rate);
GX_NS_API uint32_t gx_ns_blocks_processed(struct gx_ns *st);

GX_NS_API const char *gx_ns_engine_name(gx_ns_engine e); /* "off" | "rnnoise" | "dfn3" */
GX_NS_API const char *gx_ns_reason_name(gx_ns_reason r);

/* RNNoise's own algorithmic delay at 48 kHz (one frame). */
#define GX_NS_RNNOISE_LATENCY 480

#ifdef __cplusplus
}
#endif

#endif /* GX_NS_H */

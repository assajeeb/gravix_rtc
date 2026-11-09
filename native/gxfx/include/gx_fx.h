/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* gx_fx: on-device voice effects, run on the capture stream after gx_ns.
 *
 * Threads: gx_fx_process is called from the audio thread only and never
 * allocates, locks or logs. Everything else is control-thread only (one
 * thread at a time). gx_fx_destroy needs the audio thread to have stopped. */
#ifndef GX_FX_H
#define GX_FX_H
#ifdef __cplusplus
extern "C" {
#endif

typedef enum gx_fx_preset {
  GX_FX_NONE = 0,
  GX_FX_STUDIO = 1,
  GX_FX_HALL = 2,
  GX_FX_ROBOT = 3,
  GX_FX_GIRL = 4,
  GX_FX_TRANSFORMER = 5,
  /* 6..35: same order as kPresets in gx_fx.cpp and the name lists in GxVoiceFx (Kotlin, Swift) and GravixVoiceEffect (Dart) */
  GX_FX_AUTOTUNE_MAJOR_C = 33,
  GX_FX_AUTOTUNE_MINOR_A = 34,
  GX_FX_AUTOTUNE_HARMONIC_MINOR = 35,
  GX_FX_PRESET_COUNT = 36
} gx_fx_preset;

/* gx_fx_process results */
enum {
  GX_FX_OK = 0,            /* pcm now holds the effect */
  GX_FX_PASSTHROUGH = 1,   /* pcm untouched */
  GX_FX_NEED_REBUILD = 2,  /* pcm untouched; call gx_fx_rebuild from the control thread (once per change) */
  GX_FX_WATCHDOG = 3       /* pcm untouched; the effect just went over budget and stays off until the next set_preset */
};

typedef struct gx_fx gx_fx;

typedef struct gx_fx_status {
  int requested;      /* last set_preset */
  int active;         /* preset in the audio path */
  int rate;           /* sample rate of the active chain, 0 when none */
  int bypass;         /* music bypass */
  int watchdog;       /* 1 after a watchdog trip */
  int latency_ms;     /* delay added by the active chain */
  unsigned frames;    /* audio blocks processed */
  unsigned over;      /* blocks over budget */
  unsigned max_us;    /* slowest block */
} gx_fx_status;

typedef struct gx_fx_bench {
  int blocks;
  int p50_us;
  int p95_us;
  int max_us;
  int latency_ms;
} gx_fx_bench;

gx_fx *gx_fx_create(void);
void gx_fx_destroy(gx_fx *fx);

/* Builds the chain here and publishes it to the audio thread. 0, or -1 for an unknown preset. */
int gx_fx_set_preset(gx_fx *fx, int preset);
/* Rebuilds the requested preset for the rate the audio thread reported. */
void gx_fx_rebuild(gx_fx *fx);
/* Music in the capture stream: output goes dry so the music is not pitch shifted. */
void gx_fx_set_bypass(gx_fx *fx, int on);
void gx_fx_set_watchdog(gx_fx *fx, int budget_us, int consecutive);
void gx_fx_get_status(gx_fx *fx, gx_fx_status *out);

/* In place, mono float, one 10 ms block (any block size up to 4096 frames). */
int gx_fx_process(gx_fx *fx, float *pcm, int frames, int rate);

/* Runs a preset on a private chain over synthetic speech. Control thread. 0, or -1. */
int gx_fx_benchmark(int preset, int rate, int seconds, gx_fx_bench *out);

#ifdef __cplusplus
}
#endif
#endif

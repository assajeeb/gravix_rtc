/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
#include "gx_ns.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "gx_ns_timer.h"
#include "rnnoise.h"
#include "speex_resampler.h"

#define NB_RATES 6
#define GX_NS_TALK_WIN 100  /* talk detector: 1 s of post-NS block levels */
#define GX_NS_TALK_WARM 200 /* the first 2 s (RNNoise's output on noise still rising) ... */
#define GX_NS_TALK_WIN0 30  /* ... compare with the last 300 ms only */
static const int k_rates[NB_RATES] = {8000, 16000, 24000, 32000, 44100, 48000};

#define SRC_DRY 0
#define SRC_RNN 1
#define SRC_EXT 2

#define DELAY_FADE 240          /* 5 ms at 48 kHz */
#define DELAY_FORCE_BLOCKS 200  /* change the delay after 2 s even if never quiet */
#define RESAMPLE_SLACK 8        /* samples of FIFO headroom against resampler jitter */

/* ---------- small ring FIFO ---------- */
typedef struct {
  float *buf;
  int cap, r, count;
} fifo;

static int fifo_alloc(fifo *f, int cap) {
  f->buf = (float *)calloc((size_t)cap, sizeof(float));
  f->cap = cap;
  f->r = f->count = 0;
  return f->buf ? 0 : -1;
}
static void fifo_clear(fifo *f) { f->r = f->count = 0; }
static int fifo_push(fifo *f, const float *x, int n) {
  int i, w;
  if (n > f->cap - f->count) n = f->cap - f->count; /* never happens with our sizing */
  w = f->r + f->count;
  for (i = 0; i < n; i++) f->buf[(w + i) % f->cap] = x ? x[i] : 0.f;
  f->count += n;
  return n;
}
static int fifo_pop(fifo *f, float *x, int n) {
  int i;
  if (n > f->count) n = f->count;
  for (i = 0; i < n; i++) x[i] = f->buf[(f->r + i) % f->cap];
  f->r = (f->r + n) % f->cap;
  f->count -= n;
  return n;
}

/* ---------- delay line (48 kHz, block-wise) ---------- */
typedef struct {
  float *buf;
  int cap, w; /* w = next write position */
} delay_line;

static int dl_alloc(delay_line *d, int cap) {
  d->buf = (float *)calloc((size_t)cap, sizeof(float));
  d->cap = cap;
  d->w = 0;
  return d->buf ? 0 : -1;
}
static void dl_clear(delay_line *d) {
  memset(d->buf, 0, sizeof(float) * (size_t)d->cap);
  d->w = 0;
}
static void dl_write(delay_line *d, const float *x, int n) {
  int i;
  for (i = 0; i < n; i++) d->buf[(d->w + i) % d->cap] = x[i];
  d->w = (d->w + n) % d->cap;
}
/* The n samples written last, delayed by `delay` samples. */
static void dl_read(const delay_line *d, float *out, int n, int delay) {
  int i, start = d->w - n - delay;
  while (start < 0) start += d->cap;
  for (i = 0; i < n; i++) out[i] = d->buf[(start + i) % d->cap];
}

/* ---------- per-rate resamplers (pre-allocated) ---------- */
typedef struct {
  int rate, block; /* block = samples per 10 ms at this rate */
  SpeexResamplerState *up, *down;
  int up_lat, down_lat; /* in samples at `rate` */
} rate_ctx;

struct gx_ns {
  gx_ns_config cfg;

  /* control (any thread) */
  _Atomic int req_engine, req_bypass, req_agc, req_agc_order, req_p95_budget, req_pregain;
  _Atomic float req_atten_db;
  _Atomic uint32_t req_reset, req_stats_reset;
  _Atomic(gx_ns_external_engine *) ext_ptr;
  gx_ns_external_engine ext_slots[2];
  int ext_slot_next;
  _Atomic uint32_t ext_gen;
  _Atomic uint32_t blocks;

  /* status published for readers */
  _Atomic int pub_active, pub_xfade, pub_reason, pub_rate, pub_latency;
  _Atomic float pub_vad, pub_gain_db, pub_pregain_db;
  _Atomic float pub_pg_applied_db, pub_agc_applied_db, pub_pause_att_db;
  atomic_int pub_talk;

  /* stream (audio thread only) */
  rate_ctx rates[NB_RATES];
  rate_ctx *rc;
  int need_reprime;
  int prefill;
  fifo in48, out_r;
  float *scratch_in48, *scratch_out_r;
  int scratch48_cap, scratch_r_cap;

  /* engines */
  DenoiseState *rnn;
  int rnn_running;
  float vad;
  uint32_t reset_seen, stats_reset_seen, ext_gen_seen;
  int ext_failed;
  int ext_slow;      /* rolling p95 over budget: studio demoted until the next attach */
  uint16_t ext_us[GX_NS_EXT_P95_WINDOW_MAX], ext_sel[GX_NS_EXT_P95_WINDOW_MAX];
  int ext_us_n, ext_us_w, ext_us_since;
  _Atomic uint32_t pub_ext_p95, pub_ext_slow, pub_ext_suppress;
  int ext_suppress;  /* output speech collapsed vs input: studio demoted until the next attach */
  int sup_run;       /* consecutive speech blocks with the collapse */
  float sup_in, sup_out; /* speech-gated power EMAs of the engine's input / output ([-1,1] scale) */
  float sup_rnn;         /* ... and of RNNoise's (its shadow) output on the same blocks */
  int reset_pending;
  int ext_preroll;

  /* delay compensation */
  int L;        /* output alignment latency at 48 kHz */
  delay_line dl_dry, dl_rnn, dl_ext;
  int quiet_wait;
  int delay_fade_in; /* samples left of the 5 ms fade-in after a delay change */

  /* crossfade */
  int cur, next, xf_pos, xf_len;
  int fade_in_pos; /* reset/rate fade-in progress, == xf_len when idle */
  gx_ns_reason reason;

  /* AGC + limiter */
  int have_level;
  float level_db, gain_db, prev_gain_lin;
  float nf_db; /* energy VAD noise floor */
  int nf_have; /* the floor starts at the first non-silent block's level */
  /* Talk detector + pause gate (DTX, 2026-10-21). "Talk" is judged on what the
   * NS leaves (post-NS level, pre-gain taken out, before our AGC) against its
   * minimum over the last second: speech dips between syllables, what RNNoise
   * leaves of noise does not. RNNoise's VAD alone calls swelling traffic
   * noise speech (~100% of blocks), and a slow noise floor follows the swells
   * too late. Out of talk (after a hangover) the pre-gain and AGC boosts ramp
   * to unity (values held), so neither lifts the noise over Opus' DTX
   * threshold; talk opens the gate at once. */
  float post_hist[GX_NS_TALK_WIN]; /* post-NS block levels, ring */
  int post_pos;
  float in_hist[3]; /* the last input block levels (the NS output lags them) */
  float exp_lvl_db, exp_prev_lin; /* pause expander: output level EMA, last gain */
  int exp_quiet;  /* blocks since the last talk block (the expander waits for a real pause) */
  int pnf_have;     /* blocks with signal seen, up to GX_NS_TALK_WARM */
  int talk_now;     /* this / the last block was talk */
  int talk_hang;    /* blocks of hangover left */
  float pg_applied_db; /* pre-gain actually applied to the last block */
  float gate;
  float lim_env, lim_rel, lim_ceil;

  /* pre-gain (before NS) */
  int pg_have;
  float pg_level_db, pg_gain_db, pg_prev_lin;

  /* block buffers */
  float blk[GX_NS_BLOCK], b_rnn[GX_NS_BLOCK], b_ext[GX_NS_BLOCK], b_tmp[GX_NS_BLOCK];
  float s_dry[GX_NS_BLOCK], s_rnn[GX_NS_BLOCK], s_ext[GX_NS_BLOCK];

  gx_timer timer;
  _Atomic uint32_t underflows, ext_errors, switches;
};

typedef struct gx_ns gx_ns;

static float db_to_lin(float db) { return powf(10.f, db / 20.f); }

static float block_rms_db(const float *x, int n) {
  double acc = 0;
  int i;
  for (i = 0; i < n; i++) acc += (double)x[i] * x[i];
  acc /= n;
  if (acc < 1e-3) return -120.f;
  return (float)(10.0 * log10(acc / (32768.0 * 32768.0)));
}

void gx_ns_default_config(gx_ns_config *c) {
  memset(c, 0, sizeof(*c));
  c->max_frame_samples = 2048;
  c->crossfade_ms = 20;
  c->resampler_quality = 5;
  c->initial_engine = GX_NS_ENGINE_RNNOISE;
  c->agc_enabled = 1;
  c->agc_order = GX_NS_DEFAULT_AGC_ORDER;
  c->agc_target_dbfs = (float)GX_NS_DEFAULT_AGC_TARGET_DBFS;
  c->agc_max_gain_db = (float)GX_NS_DEFAULT_AGC_MAX_GAIN_DB;
  c->agc_min_gain_db = -10.f;
  c->limiter_dbfs = -1.f;
  c->watchdog_us = 8000;
  c->max_external_latency = 960;
  c->ext_atten_lim_db = (float)GX_NS_DEFAULT_ATTEN_LIM_DB;
  c->ext_p95_budget_us = GX_NS_DEFAULT_EXT_P95_BUDGET_US;
  c->ext_p95_window = GX_NS_DEFAULT_EXT_P95_WINDOW;
  c->pregain_enabled = 1;
  c->pregain_target_dbfs = (float)GX_NS_DEFAULT_PREGAIN_TARGET_DBFS;
  c->pregain_max_db = (float)GX_NS_DEFAULT_PREGAIN_MAX_DB;
}

float gx_ns_pregain_for_level(float speech_dbfs) {
  float g = (float)GX_NS_DEFAULT_PREGAIN_TARGET_DBFS - speech_dbfs;
  if (g > (float)GX_NS_DEFAULT_PREGAIN_MAX_DB) g = (float)GX_NS_DEFAULT_PREGAIN_MAX_DB;
  return g < 0.f ? 0.f : g;
}

const char *gx_ns_engine_name(gx_ns_engine e) {
  switch (e) {
    case GX_NS_ENGINE_RNNOISE: return "rnnoise";
    case GX_NS_ENGINE_DFN3: return "dfn3";
    default: return "off";
  }
}

const char *gx_ns_reason_name(gx_ns_reason r) {
  switch (r) {
    case GX_NS_REASON_BYPASS: return "music_bypass";
    case GX_NS_REASON_NO_EXTERNAL: return "studio_unavailable";
    case GX_NS_REASON_EXT_ERROR: return "studio_error";
    case GX_NS_REASON_DELAY_PENDING: return "delay_pending";
    case GX_NS_REASON_EXT_SLOW: return "studio_slow";
    case GX_NS_REASON_EXT_SUPPRESS: return "studio_suppress";
    default: return "ok";
  }
}

static gx_ns_engine src_engine(int src) {
  return src == SRC_RNN ? GX_NS_ENGINE_RNNOISE : src == SRC_EXT ? GX_NS_ENGINE_DFN3 : GX_NS_ENGINE_OFF;
}

void gx_ns_destroy(gx_ns *st) {
  int i;
  if (!st) return;
  for (i = 0; i < NB_RATES; i++) {
    if (st->rates[i].up) gx_resampler_destroy(st->rates[i].up);
    if (st->rates[i].down) gx_resampler_destroy(st->rates[i].down);
  }
  if (st->rnn) rnnoise_destroy(st->rnn);
  free(st->in48.buf);
  free(st->out_r.buf);
  free(st->scratch_in48);
  free(st->scratch_out_r);
  free(st->dl_dry.buf);
  free(st->dl_rnn.buf);
  free(st->dl_ext.buf);
  free(st);
}

gx_ns *gx_ns_create(const gx_ns_config *cfg) {
  gx_ns *st;
  int i, err = 0, maxf, dl_cap;
  st = (gx_ns *)calloc(1, sizeof(*st));
  if (!st) return NULL;
  if (cfg) st->cfg = *cfg; else gx_ns_default_config(&st->cfg);
  if (st->cfg.max_frame_samples < 64) st->cfg.max_frame_samples = 64;
  if (st->cfg.crossfade_ms < 1) st->cfg.crossfade_ms = 1;
  if (st->cfg.max_external_latency < GX_NS_RNNOISE_LATENCY) st->cfg.max_external_latency = GX_NS_RNNOISE_LATENCY;
  maxf = st->cfg.max_frame_samples;

  for (i = 0; i < NB_RATES; i++) {
    rate_ctx *r = &st->rates[i];
    r->rate = k_rates[i];
    r->block = k_rates[i] / 100;
    if (r->rate != GX_NS_ENGINE_RATE) {
      r->up = gx_resampler_init(1, (spx_uint32_t)r->rate, GX_NS_ENGINE_RATE, st->cfg.resampler_quality, &err);
      r->down = gx_resampler_init(1, GX_NS_ENGINE_RATE, (spx_uint32_t)r->rate, st->cfg.resampler_quality, &err);
      if (!r->up || !r->down) goto fail;
      gx_resampler_reset_mem(r->up);
      gx_resampler_reset_mem(r->down);
      r->up_lat = gx_resampler_get_input_latency(r->up);
      r->down_lat = gx_resampler_get_output_latency(r->down);
    }
  }
  /* 48 kHz side: one call can bring maxf * 6 samples (8 kHz input) + a block. */
  st->scratch48_cap = maxf * 6 + 2 * GX_NS_BLOCK + 64;
  st->scratch_r_cap = maxf + 2 * GX_NS_BLOCK + 64;
  if (fifo_alloc(&st->in48, st->scratch48_cap) || fifo_alloc(&st->out_r, 2 * st->scratch_r_cap)) goto fail;
  st->scratch_in48 = (float *)calloc((size_t)st->scratch48_cap, sizeof(float));
  st->scratch_out_r = (float *)calloc((size_t)st->scratch_r_cap, sizeof(float));
  if (!st->scratch_in48 || !st->scratch_out_r) goto fail;
  dl_cap = st->cfg.max_external_latency + 3 * GX_NS_BLOCK; /* + RNNoise priming history */
  if (dl_alloc(&st->dl_dry, dl_cap) || dl_alloc(&st->dl_rnn, dl_cap) || dl_alloc(&st->dl_ext, dl_cap)) goto fail;

  st->rnn = rnnoise_create(NULL);
  if (!st->rnn) goto fail;
  /* Warm-up: RNNoise allocates its FFT tables lazily on the first frame. */
  memset(st->blk, 0, sizeof(st->blk));
  rnnoise_process_frame(st->rnn, st->b_tmp, st->blk);
  rnnoise_reset(st->rnn);
  (void)gx_timer_now_ns(); /* Apple: fills the timebase outside the audio thread */

  gx_timer_init(&st->timer, (uint32_t)st->cfg.watchdog_us);
  atomic_init(&st->req_engine, (int)st->cfg.initial_engine);
  atomic_init(&st->req_bypass, 0);
  atomic_init(&st->req_agc, st->cfg.agc_enabled ? 1 : 0);
  atomic_init(&st->req_agc_order, (int)st->cfg.agc_order);
  atomic_init(&st->req_reset, 0);
  atomic_init(&st->req_stats_reset, 0);
  atomic_init(&st->ext_ptr, NULL);
  atomic_init(&st->ext_gen, 0);
  atomic_init(&st->blocks, 0);
  atomic_init(&st->underflows, 0);
  atomic_init(&st->ext_errors, 0);
  atomic_init(&st->switches, 0);
  atomic_init(&st->pub_rate, 0);
  atomic_init(&st->pub_latency, 0);
  atomic_init(&st->pub_vad, 0.f);
  atomic_init(&st->pub_gain_db, 0.f);
  atomic_init(&st->pub_pregain_db, 0.f);
  atomic_init(&st->pub_pg_applied_db, 0.f);
  atomic_init(&st->pub_agc_applied_db, 0.f);
  atomic_init(&st->pub_pause_att_db, 0.f);
  atomic_init(&st->pub_talk, 0);
  atomic_init(&st->req_pregain, st->cfg.pregain_enabled ? 1 : 0);
  atomic_init(&st->pub_ext_suppress, 0);
  st->pg_prev_lin = 1.f;

  st->xf_len = st->cfg.crossfade_ms * GX_NS_ENGINE_RATE / 1000;
  st->L = GX_NS_RNNOISE_LATENCY;
  st->cur = st->next = (st->cfg.initial_engine == GX_NS_ENGINE_OFF) ? SRC_DRY : SRC_RNN;
  st->xf_pos = 0;
  st->fade_in_pos = st->xf_len; /* first stream start does its own fade-in only on reset */
  st->rc = NULL;
  st->need_reprime = 1;
  st->prev_gain_lin = 1.f;
  st->exp_prev_lin = 1.f;
  st->exp_lvl_db = -100.f;
  st->nf_db = -60.f;
  st->lim_ceil = 32768.f * db_to_lin(st->cfg.limiter_dbfs);
  st->lim_rel = expf(-1.f / (0.05f * GX_NS_ENGINE_RATE));
  atomic_init(&st->pub_active, st->cur);
  atomic_init(&st->pub_xfade, 0);
  atomic_init(&st->pub_reason, 0);
  if (st->cfg.ext_p95_window < 20) st->cfg.ext_p95_window = 20;
  if (st->cfg.ext_p95_window > GX_NS_EXT_P95_WINDOW_MAX) st->cfg.ext_p95_window = GX_NS_EXT_P95_WINDOW_MAX;
  atomic_init(&st->req_atten_db, st->cfg.ext_atten_lim_db > 0.f ? st->cfg.ext_atten_lim_db : 0.f);
  atomic_init(&st->req_p95_budget, st->cfg.ext_p95_budget_us > 0 ? st->cfg.ext_p95_budget_us : 0);
  atomic_init(&st->pub_ext_p95, 0);
  atomic_init(&st->pub_ext_slow, 0);
  return st;
fail:
  gx_ns_destroy(st);
  return NULL;
}

/* ---------- control ---------- */
void gx_ns_set_engine(gx_ns *st, gx_ns_engine e) { atomic_store(&st->req_engine, (int)e); }
void gx_ns_set_bypass(gx_ns *st, int b) { atomic_store(&st->req_bypass, b ? 1 : 0); }
void gx_ns_set_agc(gx_ns *st, int on) { atomic_store(&st->req_agc, on ? 1 : 0); }
void gx_ns_set_agc_order(gx_ns *st, gx_ns_agc_order o) { atomic_store(&st->req_agc_order, (int)o); }
void gx_ns_request_reset(gx_ns *st) { atomic_fetch_add(&st->req_reset, 1); }
void gx_ns_set_atten_limit(gx_ns *st, float db) { atomic_store(&st->req_atten_db, db > 0.f ? db : 0.f); }
void gx_ns_set_ext_p95_budget(gx_ns *st, int us) { atomic_store(&st->req_p95_budget, us > 0 ? us : 0); }
void gx_ns_reset_stats(gx_ns *st) { atomic_fetch_add(&st->req_stats_reset, 1); }
void gx_ns_set_pregain(gx_ns *st, int on) { atomic_store(&st->req_pregain, on ? 1 : 0); }
uint32_t gx_ns_blocks_processed(gx_ns *st) { return atomic_load(&st->blocks); }

int gx_ns_set_external_engine(gx_ns *st, const gx_ns_external_engine *eng) {
  gx_ns_external_engine *slot = NULL;
  if (eng) {
    if (!eng->process || eng->latency_samples < 0 || eng->latency_samples > st->cfg.max_external_latency) return -1;
    slot = &st->ext_slots[st->ext_slot_next];
    st->ext_slot_next ^= 1;
    *slot = *eng;
  }
  atomic_store(&st->ext_ptr, slot);
  atomic_fetch_add(&st->ext_gen, 1);
  return 0;
}

static rate_ctx *find_rate(gx_ns *st, int rate) {
  int i;
  for (i = 0; i < NB_RATES; i++)
    if (st->rates[i].rate == rate) return &st->rates[i];
  return NULL;
}

static int latency_for(gx_ns *st, const rate_ctx *r, int prefill) {
  if (r->rate == GX_NS_ENGINE_RATE) return prefill + st->L;
  return prefill + r->up_lat + r->down_lat + (int)((long)st->L * r->rate / GX_NS_ENGINE_RATE);
}

int gx_ns_latency_samples(gx_ns *st, int sample_rate) {
  rate_ctx *r = find_rate(st, sample_rate);
  if (!r) return -1;
  if (st->rc == r && !st->need_reprime) return latency_for(st, r, st->prefill);
  return latency_for(st, r, r->rate == GX_NS_ENGINE_RATE ? 0 : r->block + RESAMPLE_SLACK);
}

/* ---------- stream reset (no allocation) ---------- */
static void stream_reset(gx_ns *st, rate_ctx *r, int n, const gx_ns_external_engine *ext) {
  st->rc = r;
  fifo_clear(&st->in48);
  fifo_clear(&st->out_r);
  if (r->up) {
    gx_resampler_reset_mem(r->up);
    gx_resampler_reset_mem(r->down);
    st->prefill = r->block + RESAMPLE_SLACK;
  } else {
    st->prefill = (n % GX_NS_BLOCK == 0) ? 0 : GX_NS_BLOCK;
  }
  fifo_push(&st->out_r, NULL, st->prefill);
  dl_clear(&st->dl_dry);
  dl_clear(&st->dl_rnn);
  dl_clear(&st->dl_ext);
  rnnoise_reset(st->rnn);
  if (ext && ext->reset) ext->reset(ext->user);
  if (st->cur != st->next) { st->cur = st->next; st->xf_pos = 0; }
  st->fade_in_pos = 0; /* buffered audio was dropped: 20 ms fade-in from silence */
  st->lim_env = 0.f;
  st->need_reprime = 0;
  atomic_store_explicit(&st->pub_rate, r->rate, memory_order_relaxed);
  atomic_store_explicit(&st->pub_latency, latency_for(st, r, st->prefill), memory_order_relaxed);
}

/* ---------- AGC ---------- */
#define GX_NS_TALK_OVER_DB 15.f /* post-NS level over its 1 s minimum that counts as talk */
#define GX_NS_TALK_MIN_DB (-80.f) /* ... and over this absolute level (gain taken out; as low as the pre-gain
                                   * floor: a -66 dBFS phone mic must still count as talk, review 2026-10-21) */
#define GX_NS_TALK_KEEP_DB 8.f  /* ... and the NS kept most of it (noise loses more) */
#ifndef GX_NS_TALK_RECENT
#define GX_NS_TALK_RECENT 60 /* within 600 ms of talk, a talk test passes with the lower VAD */
#endif
#ifndef GX_NS_TALK_RISE_DB
#define GX_NS_TALK_RISE_DB 20.f /* a rise this far over the input floor: a word start, the lower VAD will do
                                 * (RNNoise's VAD lags at word starts; device 2026-10-21: 6-12 dB onset dips) */
#endif
#ifndef GX_NS_TALK_VAD_HOLD
#define GX_NS_TALK_VAD_HOLD 0.5f /* ... (hysteresis: talk going on needs less) */
#endif
#ifndef GX_NS_TALK_VAD
#define GX_NS_TALK_VAD 0.9f     /* ... and RNNoise is sure it is voice (2026-10-21 fan room:
                                 * sounds RNNoise is unsure of opened the gate 43% of the time) */
#endif
#define GX_NS_PAUSE_TARGET_DB (-56.f) /* pause expander: what the NS leaves of loud noise ... */
#define GX_NS_PAUSE_MAX_ATT_DB 15.f   /* ... is pulled down to here, by at most this */
#ifndef GX_NS_EXP_RISE
#define GX_NS_EXP_RISE 0.03f /* ... its level estimate rises slowly (~0.3 s), falls fast */
#endif
#ifndef GX_NS_EXP_WAIT
#define GX_NS_EXP_WAIT 40 /* ... after this many blocks without talk (400 ms), over 100 ms */
#endif
#define GX_NS_PAUSE_HANG 10     /* 100 ms of no talk before the gate closes ... */
#define GX_NS_PAUSE_RAMP 0.1f   /* ... then 100 ms to unity (a word's next syllable reopens it at once) */

/* A boost scaled by the pause gate; an attenuation always applies. */
static float gated_db(const gx_ns *st, float db) { return db > 0.f ? db * st->gate : db; }

static float energy_vad(gx_ns *st, float rms_db) {
  if (!st->nf_have) {
    if (rms_db < -90.f) return 0.f; /* digital silence (a mic starting up) is no floor */
    st->nf_db = rms_db; st->nf_have = 1;
  }
  if (rms_db < st->nf_db) st->nf_db = 0.5f * st->nf_db + 0.5f * rms_db;
  else st->nf_db += 0.02f; /* 2 dB/s upward drift */
  if (st->nf_db < -90.f) st->nf_db = -90.f;
  return (rms_db > st->nf_db + 10.f && rms_db > -60.f) ? 1.f : 0.f;
}

/* Measures x (pre-gain) and applies the smoothed gain in place. */
static void agc_block(gx_ns *st, float *x, float vad, int gated) {
  int i;
  float rms_db = block_rms_db(x, GX_NS_BLOCK), g_lin, step;
  if (vad >= 0.5f && rms_db > -65.f) {
    if (!st->have_level) { st->level_db = rms_db; st->have_level = 1; }
    else st->level_db += 0.05f * (rms_db - st->level_db);
    {
      float want = st->cfg.agc_target_dbfs - st->level_db;
      if (want > st->cfg.agc_max_gain_db) want = st->cfg.agc_max_gain_db;
      if (want < st->cfg.agc_min_gain_db) want = st->cfg.agc_min_gain_db;
      if (want > st->gain_db) { step = 0.1f; st->gain_db = (want - st->gain_db < step) ? want : st->gain_db + step; }  /* 10 dB/s up */
      else { step = 0.2f; st->gain_db = (st->gain_db - want < step) ? want : st->gain_db - step; } /* 20 dB/s down */
    }
  }
  g_lin = db_to_lin(gated ? gated_db(st, st->gain_db) : st->gain_db);
  for (i = 0; i < GX_NS_BLOCK; i++) {
    float a = (float)(i + 1) / GX_NS_BLOCK;
    x[i] *= st->prev_gain_lin + (g_lin - st->prev_gain_lin) * a;
  }
  st->prev_gain_lin = g_lin;
}

/* Pre-gain: boost-only speech-level normaliser ahead of every engine. Level
 * tracking on speech blocks only (previous block's RNNoise VAD + an energy check
 * against the noise floor), fast attack (louder speech pulls the gain down at
 * once) / slow release (gain rises at <= 15 dB/s); held in pauses, so noise is
 * never pumped up. The first speech block sets the gain directly (a quiet
 * phone mic must reach DFN3 at a usable level from the first words). Soft
 * limiter (tanh knee above -6 dBFS) after the gain. `on` = 0 ramps to unity. */
static void pregain_block(gx_ns *st, float *x, float rms_db, int on) {
  int i;
  float g_lin;
  if (!on) {
    st->pg_gain_db = 0.f;
  } else {
    /* learns on talk (post-NS detector, last block) that RNNoise also calls voice */
    int speech = st->talk_now && st->vad >= 0.5f && rms_db > -80.f;
    if (speech) {
      float want;
      int first = !st->pg_have;
      if (first) { st->pg_level_db = rms_db; st->pg_have = 1; }
      else if (rms_db > st->pg_level_db) st->pg_level_db += 0.3f * (rms_db - st->pg_level_db);  /* attack */
      else st->pg_level_db += 0.02f * (rms_db - st->pg_level_db);                              /* release */
      want = st->cfg.pregain_target_dbfs - st->pg_level_db;
      if (want > st->cfg.pregain_max_db) want = st->cfg.pregain_max_db;
      if (want < 0.f) want = 0.f;
      if (first) st->pg_gain_db = want; /* first speech: settle at once (ramped over the block) */
      else if (want < st->pg_gain_db) st->pg_gain_db = (st->pg_gain_db - want < 1.f) ? want : st->pg_gain_db - 1.f; /* <= 100 dB/s down */
      else st->pg_gain_db = (want - st->pg_gain_db < 0.15f) ? want : st->pg_gain_db + 0.15f;                       /* <= 15 dB/s up */
    }
  }
  st->pg_applied_db = gated_db(st, st->pg_gain_db);
  g_lin = db_to_lin(st->pg_applied_db);
  if (g_lin == 1.f && st->pg_prev_lin == 1.f) return;
  {
    const float T = 16384.f, C = 32000.f; /* knee -6 dBFS, ceiling ~-0.2 dBFS */
    for (i = 0; i < GX_NS_BLOCK; i++) {
      float a = (float)(i + 1) / GX_NS_BLOCK, y = x[i] * (st->pg_prev_lin + (g_lin - st->pg_prev_lin) * a), m = fabsf(y);
      if (m > T) y = (y > 0.f ? 1.f : -1.f) * (T + (C - T) * tanhf((m - T) / (C - T)));
      x[i] = y;
    }
  }
  st->pg_prev_lin = g_lin;
}

/* Studio guard: speech-gated power EMAs of the engine's input and output; a
 * collapse (output >= GX_NS_EXT_SUPPRESS_DB under input) over
 * GX_NS_EXT_SUPPRESS_BLOCKS consecutive speech blocks demotes the engine. */
static void ext_suppress_check(gx_ns *st, const float *in, const float *out, const float *rnn, float vad) {
  double pi = 0, po = 0, pr = 0;
  int i;
  float ratio_db, vs_rnn_db;
  if (vad < 0.5f || st->ext_suppress) return;
  for (i = 0; i < GX_NS_BLOCK; i++) {
    pi += (double)in[i] * in[i]; po += (double)out[i] * out[i];
    pr += (double)rnn[i] * rnn[i] * (1.0 / (32768.0 * 32768.0)); /* RNNoise runs on the int16 scale */
  }
  pi /= GX_NS_BLOCK; po /= GX_NS_BLOCK; pr /= GX_NS_BLOCK;
  if (pi < 1e-9) return; /* below -90 dBFS: nothing to judge */
  st->sup_in += 0.05f * ((float)pi - st->sup_in);
  st->sup_out += 0.05f * ((float)po - st->sup_out);
  st->sup_rnn += 0.05f * ((float)pr - st->sup_rnn);
  ratio_db = 10.f * log10f((st->sup_out + 1e-12f) / (st->sup_in + 1e-12f));
  /* 2026-10-21 iPhone quiet mic: DFN3 took ~19 dB off the speech, just short of
   * the 20 dB vs-input test, for up to 57 s, while RNNoise (its shadow, same
   * blocks) kept it. Far below RNNoise on speech = DFN3 erases it. */
  vs_rnn_db = 10.f * log10f((st->sup_out + 1e-12f) / (st->sup_rnn + 1e-12f));
  if (ratio_db < -(float)GX_NS_EXT_SUPPRESS_DB || vs_rnn_db < -(float)GX_NS_EXT_VS_RNN_DB) st->sup_run++;
  else st->sup_run = 0;
  if (st->sup_run >= GX_NS_EXT_SUPPRESS_BLOCKS) {
    st->ext_suppress = 1;
    atomic_store_explicit(&st->pub_ext_suppress, 1, memory_order_relaxed);
  }
}

static void limiter_block(gx_ns *st, float *x) {
  int i;
  for (i = 0; i < GX_NS_BLOCK; i++) {
    float a = fabsf(x[i]);
    float decayed = st->lim_env * st->lim_rel;
    st->lim_env = a > decayed ? a : decayed; /* env >= |x|, so |x| * ceil / env <= ceil */
    if (st->lim_env > st->lim_ceil) x[i] *= st->lim_ceil / st->lim_env;
    if (x[i] > 32767.f) x[i] = 32767.f;
    else if (x[i] < -32768.f) x[i] = -32768.f;
  }
}

/* k-th smallest of a[0..n) (quickselect, in place, no allocation). */
static uint16_t select_kth(uint16_t *a, int n, int k) {
  int lo = 0, hi = n - 1;
  while (lo < hi) {
    uint16_t piv = a[(lo + hi) / 2], t;
    int i = lo, j = hi;
    while (i <= j) {
      while (a[i] < piv) i++;
      while (a[j] > piv) j--;
      if (i <= j) { t = a[i]; a[i] = a[j]; a[j] = t; i++; j--; }
    }
    if (k <= j) hi = j; else if (k >= i) lo = i; else return a[k];
  }
  return a[k];
}

/* Studio frame time -> rolling p95 over the window; every 25 blocks once full. */
static void ext_time_add(gx_ns *st, uint64_t ns) {
  int win = st->cfg.ext_p95_window;
  uint32_t us = (uint32_t)(ns / 1000u), budget;
  st->ext_us[st->ext_us_w] = (uint16_t)(us > 65535u ? 65535u : us);
  st->ext_us_w = (st->ext_us_w + 1) % win;
  if (st->ext_us_n < win) st->ext_us_n++;
  if (++st->ext_us_since < 25 || st->ext_us_n < win) return;
  st->ext_us_since = 0;
  memcpy(st->ext_sel, st->ext_us, sizeof(uint16_t) * (size_t)win);
  us = select_kth(st->ext_sel, win, (int)((win * 95 + 99) / 100) - 1);
  atomic_store_explicit(&st->pub_ext_p95, us, memory_order_relaxed);
  budget = (uint32_t)atomic_load_explicit(&st->req_p95_budget, memory_order_relaxed);
  if (budget && us > budget && !st->ext_slow) {
    st->ext_slow = 1;
    atomic_store_explicit(&st->pub_ext_slow, 1, memory_order_relaxed);
  }
}

/* ---------- one 10 ms block at 48 kHz, in place ---------- */
static void process_block(gx_ns *st, float *blk) {
  const float *srcs[3];
  gx_ns_external_engine *ext;
  uint32_t g;
  int req, bypass, agc_on, agc_order, desired, i, want_L, run_rnn, run_ext, pg_on;
  float vad = 0.f, in_rms_db;

  /* control snapshot */
  req = atomic_load_explicit(&st->req_engine, memory_order_relaxed);
  bypass = atomic_load_explicit(&st->req_bypass, memory_order_relaxed);
  agc_on = atomic_load_explicit(&st->req_agc, memory_order_relaxed);
  agc_order = atomic_load_explicit(&st->req_agc_order, memory_order_relaxed);
  ext = atomic_load_explicit(&st->ext_ptr, memory_order_acquire);
  g = atomic_load_explicit(&st->ext_gen, memory_order_relaxed);
  if (g != st->ext_gen_seen) {
    st->ext_gen_seen = g; st->ext_failed = 0; st->ext_preroll = -1;
    st->ext_slow = 0; st->ext_us_n = st->ext_us_w = st->ext_us_since = 0; /* fresh engine, fresh window */
    atomic_store_explicit(&st->pub_ext_slow, 0, memory_order_relaxed);
    atomic_store_explicit(&st->pub_ext_p95, 0, memory_order_relaxed);
    st->ext_suppress = 0; st->sup_run = 0; st->sup_in = st->sup_out = st->sup_rnn = 0.f;
    atomic_store_explicit(&st->pub_ext_suppress, 0, memory_order_relaxed);
  }
  g = atomic_load_explicit(&st->req_reset, memory_order_relaxed);
  if (g != st->reset_seen) { st->reset_seen = g; st->reset_pending = 1; }
  /* Engine vanished under us (detached without switching away first): hard cut to RNNoise. */
  if (!ext && (st->cur == SRC_EXT || st->next == SRC_EXT)) {
    if (st->cur == SRC_EXT) st->cur = SRC_RNN;
    if (st->next == SRC_EXT) st->next = st->cur;
    st->xf_pos = 0;
  }

  /* delay compensation target */
  want_L = GX_NS_RNNOISE_LATENCY;
  if (ext && ext->latency_samples > want_L) want_L = ext->latency_samples;

  /* desired source */
  st->reason = GX_NS_REASON_OK;
  if (st->reset_pending) desired = SRC_DRY; /* fade out the old engine state first */
  else if (bypass) { desired = SRC_DRY; st->reason = GX_NS_REASON_BYPASS; }
  else if (req == GX_NS_ENGINE_OFF) desired = SRC_DRY;
  else if (req == GX_NS_ENGINE_DFN3) {
    if (!ext) { desired = SRC_RNN; st->reason = GX_NS_REASON_NO_EXTERNAL; }
    else if (st->ext_failed) { desired = SRC_RNN; st->reason = GX_NS_REASON_EXT_ERROR; }
    else if (st->ext_slow) { desired = SRC_RNN; st->reason = GX_NS_REASON_EXT_SLOW; }
    else if (st->ext_suppress) { desired = SRC_RNN; st->reason = GX_NS_REASON_EXT_SUPPRESS; }
    else if (st->L != want_L) { desired = SRC_RNN; st->reason = GX_NS_REASON_DELAY_PENDING; }
    else {
      if (st->ext_preroll < 0) /* fill its delay line + let it settle before it is heard */
        st->ext_preroll = 2 + (st->L - ext->latency_samples + GX_NS_BLOCK - 1) / GX_NS_BLOCK;
      desired = st->ext_preroll > 0 ? st->next : SRC_EXT; /* keep what plays during the pre-roll */
    }
  } else desired = SRC_RNN;

  if (st->cur == st->next) {
    if (desired != st->cur) { st->next = desired; st->xf_pos = 0; }
  } else if (desired == st->cur) { /* reverse a running fade */
    int t = st->cur; st->cur = st->next; st->next = t;
    st->xf_pos = st->xf_len - st->xf_pos;
  }

  /* Music bypass takes the WHOLE chain out (NS and our AGC; owner 2026-10-21):
   * the gain ramps back to unity like "AGC off" and returns after the bypass.
   * The peak limiter (-1 dBFS) stays: it only touches near-full-scale peaks.
   * Engine "off" (the SDK's off and kill switch) does the same, like pre-gain:
   * WebRTC's own AGC is back on there and two AGCs must never stack. */
  if (bypass || req == GX_NS_ENGINE_OFF) agc_on = 0;

  /* pre-gain (all engines), then the probe-only AGC before NS */
  in_rms_db = block_rms_db(blk, GX_NS_BLOCK);
  pg_on = atomic_load_explicit(&st->req_pregain, memory_order_relaxed) && !bypass && req != GX_NS_ENGINE_OFF;
  pregain_block(st, blk, in_rms_db, pg_on);

  if (agc_on && agc_order == GX_NS_AGC_BEFORE_NS) agc_block(st, blk, st->talk_now ? st->vad : 0.f, 0); /* probe-only order: not gated */

  dl_write(&st->dl_dry, blk, GX_NS_BLOCK);

  /* RNNoise: whenever audible, fading, wanted, or as the shadow of DFN3. */
  run_rnn = st->cur == SRC_RNN || st->next == SRC_RNN || desired == SRC_RNN || st->cur == SRC_EXT || st->next == SRC_EXT;
  if (run_rnn) {
    if (!st->rnn_running) {
      /* (Re)start from a clean state, primed with the two previous input
       * blocks so the overlap-add memory is filled: without it the first two
       * output blocks have a seam that clicks in the crossfade. */
      rnnoise_reset(st->rnn);
      dl_read(&st->dl_dry, st->b_tmp, GX_NS_BLOCK, 2 * GX_NS_BLOCK);
      rnnoise_process_frame(st->rnn, st->b_rnn, st->b_tmp);
      dl_read(&st->dl_dry, st->b_tmp, GX_NS_BLOCK, GX_NS_BLOCK);
      rnnoise_process_frame(st->rnn, st->b_rnn, st->b_tmp);
      st->rnn_running = 1;
    }
    vad = rnnoise_process_frame(st->rnn, st->b_rnn, blk);
    dl_write(&st->dl_rnn, st->b_rnn, GX_NS_BLOCK);
  } else {
    st->rnn_running = 0;
    vad = energy_vad(st, in_rms_db);
    dl_write(&st->dl_rnn, blk, GX_NS_BLOCK); /* keeps the line time-aligned; never audible */
  }
  if (run_rnn) (void)energy_vad(st, in_rms_db); /* keep the noise floor tracking */

  /* External engine ([-1, 1] scale). */
  run_ext = ext && !st->ext_failed && (st->cur == SRC_EXT || st->next == SRC_EXT || (st->ext_preroll > 0 && !st->ext_slow && !st->ext_suppress));
  if (run_ext) {
    const float k = 1.f / 32768.f;
    uint64_t te;
    int rc;
    for (i = 0; i < GX_NS_BLOCK; i++) st->b_tmp[i] = blk[i] * k;
    te = gx_timer_now_ns();
    rc = ext->process(ext->user, st->b_ext, st->b_tmp, GX_NS_BLOCK);
    ext_time_add(st, gx_timer_now_ns() - te);
    if (rc != 0) {
      st->ext_failed = 1;
      atomic_fetch_add_explicit(&st->ext_errors, 1, memory_order_relaxed);
      if (st->cur == SRC_EXT) st->cur = SRC_RNN;
      if (st->next == SRC_EXT) st->next = st->cur;
      st->xf_pos = 0;
      dl_write(&st->dl_ext, blk, GX_NS_BLOCK);
    } else {
      ext_suppress_check(st, st->b_tmp, st->b_ext, st->b_rnn, vad);
      for (i = 0; i < GX_NS_BLOCK; i++) st->b_ext[i] *= 32768.f;
      dl_write(&st->dl_ext, st->b_ext, GX_NS_BLOCK);
    }
    if (st->ext_preroll > 0) st->ext_preroll--;
  } else {
    dl_write(&st->dl_ext, blk, GX_NS_BLOCK);
    st->ext_preroll = -1; /* not running: its delay line is stale, pre-roll again before use */
  }

  /* aligned sources */
  dl_read(&st->dl_dry, st->s_dry, GX_NS_BLOCK, st->L);
  dl_read(&st->dl_rnn, st->s_rnn, GX_NS_BLOCK, st->L - GX_NS_RNNOISE_LATENCY);
  dl_read(&st->dl_ext, st->s_ext, GX_NS_BLOCK, ext ? st->L - ext->latency_samples : 0);
  /* Studio attenuation limit: mix back the delay-aligned dry signal (equals
   * DeepFilterNet's spectral atten_lim mix: STFT/ISTFT are linear). */
  {
    float lim = atomic_load_explicit(&st->req_atten_db, memory_order_relaxed);
    if (ext && lim > 0.f) {
      const float gd = db_to_lin(-lim), ge = 1.f - gd;
      for (i = 0; i < GX_NS_BLOCK; i++) st->s_ext[i] = ge * st->s_ext[i] + gd * st->s_dry[i];
    }
  }
  srcs[SRC_DRY] = st->s_dry;
  srcs[SRC_RNN] = st->s_rnn;
  srcs[SRC_EXT] = st->s_ext;

  /* complementary linear crossfade */
  if (st->cur == st->next) {
    memcpy(blk, srcs[st->cur], sizeof(float) * GX_NS_BLOCK);
  } else {
    const float *a = srcs[st->cur], *b = srcs[st->next];
    for (i = 0; i < GX_NS_BLOCK; i++) {
      float w = st->xf_pos >= st->xf_len ? 1.f : (float)st->xf_pos / (float)st->xf_len;
      blk[i] = a[i] + (b[i] - a[i]) * w;
      if (st->xf_pos < st->xf_len) st->xf_pos++;
    }
    if (st->xf_pos >= st->xf_len) {
      st->cur = st->next;
      st->xf_pos = 0;
      atomic_fetch_add_explicit(&st->switches, 1, memory_order_relaxed);
    }
  }

  /* Route change: the old engine has faded out to dry (continuous signal);
   * reset it now, it fades back in from the next block. ~40 ms in total. */
  if (st->reset_pending && st->cur == SRC_DRY && st->next == SRC_DRY) {
    st->rnn_running = 0; /* restarts primed on the next block */
    if (ext && ext->reset) ext->reset(ext->user);
    st->reset_pending = 0;
  }

  /* talk detector + pause gate on what the NS left (pre-gain taken out). With
   * DFN3 audible it judges the louder of DFN3 and RNNoise's shadow (same
   * alignment): DFN3 erases speech under ~-45 dBFS, so judged on its own output
   * a quiet mic never counted as talk and the pre-gain that would lift it to
   * DFN3 never learnt (iPhone 2026-10-21: up to 57 s of erased speech). Both
   * suppress noise, so the louder one stays low on noise. */
  {
    float post_db = block_rms_db(blk, GX_NS_BLOCK);
    if (run_rnn) {
      float rnn_db = block_rms_db(st->s_rnn, GX_NS_BLOCK);
      if (rnn_db > post_db) post_db = rnn_db;
    }
    post_db -= st->pg_applied_db;
    float mn = 1e9f;
    int k;
    if (post_db < -100.f) post_db = -100.f;
    {
      int w = st->pnf_have < GX_NS_TALK_WARM ? GX_NS_TALK_WIN0 : GX_NS_TALK_WIN;
      for (k = 1; k <= w; k++) {
        float v = st->post_hist[(st->post_pos + GX_NS_TALK_WIN - k) % GX_NS_TALK_WIN];
        if (v < mn) mn = v;
      }
    }
    {
      float in_ref = in_rms_db;
      for (k = 0; k < 3; k++) if (st->in_hist[k] > in_ref) in_ref = st->in_hist[k];
      st->in_hist[st->post_pos % 3] = in_rms_db;
      st->talk_now = st->pnf_have >= GX_NS_TALK_WIN0 && post_db > mn + GX_NS_TALK_OVER_DB && post_db > GX_NS_TALK_MIN_DB &&
                     post_db > in_ref - GX_NS_TALK_KEEP_DB &&
                     vad >= ((st->exp_quiet < GX_NS_TALK_RECENT || in_rms_db > st->nf_db + GX_NS_TALK_RISE_DB)
                                 ? GX_NS_TALK_VAD_HOLD : GX_NS_TALK_VAD);
    }
    st->post_hist[st->post_pos] = post_db;
    st->post_pos = (st->post_pos + 1) % GX_NS_TALK_WIN;
    if (st->pnf_have < GX_NS_TALK_WARM && in_rms_db > -90.f) st->pnf_have++; /* the mic's digital silence (start-up) does not count */
    st->exp_quiet = st->talk_now ? 0 : (st->exp_quiet < 1000 ? st->exp_quiet + 1 : 1000);
    if (st->talk_now) {
      st->talk_hang = GX_NS_PAUSE_HANG;
      st->gate = 1.f;
    } else if (st->talk_hang > 0) {
      st->talk_hang--;
    } else {
      st->gate = st->gate > GX_NS_PAUSE_RAMP ? st->gate - GX_NS_PAUSE_RAMP : 0.f;
    }
  }

  if (agc_on && agc_order == GX_NS_AGC_AFTER_NS) agc_block(st, blk, st->talk_now ? vad : 0.f, 1);
  else if (!agc_on) {
    /* keep the gain neutral and smooth when AGC goes off */
    st->gain_db = 0.f;
    if (st->prev_gain_lin != 1.f) {
      for (i = 0; i < GX_NS_BLOCK; i++) blk[i] *= st->prev_gain_lin + (1.f - st->prev_gain_lin) * (float)(i + 1) / GX_NS_BLOCK;
      st->prev_gain_lin = 1.f;
    }
  }

  /* Pause expander (DTX), part of our AGC stage (runs with it: off, the kill
   * switch, music bypass and webrtcBeforeNs leave the level alone): in pauses
   * (gate closed) what the NS leaves of loud noise is pulled down to
   * GX_NS_PAUSE_TARGET_DB, so Opus' DTX engages; talk reopens at once. Quiet
   * rooms are left alone (nothing over the target). */
  {
    float lvl = block_rms_db(blk, GX_NS_BLOCK), att = 0.f, g_lin;
    /* slow to rise (a word's onset must not pull itself down), quick to fall */
    st->exp_lvl_db += (lvl > st->exp_lvl_db ? GX_NS_EXP_RISE : 0.1f) * (lvl - st->exp_lvl_db);
    if (agc_on) {
      att = st->exp_lvl_db - GX_NS_PAUSE_TARGET_DB;
      if (att > GX_NS_PAUSE_MAX_ATT_DB) att = GX_NS_PAUSE_MAX_ATT_DB;
      if (att < 0.f) att = 0.f;
      att *= 1.f - st->gate;
      /* only in a real pause: never on a word's first syllable after a short gap */
      if (st->exp_quiet < GX_NS_EXP_WAIT) att = 0.f;
      else if (st->exp_quiet < GX_NS_EXP_WAIT + 10) att *= (float)(st->exp_quiet - GX_NS_EXP_WAIT) / 10.f;
    }
    atomic_store_explicit(&st->pub_pause_att_db, att, memory_order_relaxed);
    g_lin = db_to_lin(-att);
    if (g_lin != 1.f || st->exp_prev_lin != 1.f) {
      for (i = 0; i < GX_NS_BLOCK; i++) blk[i] *= st->exp_prev_lin + (g_lin - st->exp_prev_lin) * (float)(i + 1) / GX_NS_BLOCK;
      st->exp_prev_lin = g_lin;
    }
  }

  /* reset / rate-change fade-in from silence */
  if (st->fade_in_pos < st->xf_len) {
    for (i = 0; i < GX_NS_BLOCK; i++) {
      float w = st->fade_in_pos >= st->xf_len ? 1.f : (float)st->fade_in_pos / (float)st->xf_len;
      blk[i] *= w;
      if (st->fade_in_pos < st->xf_len) st->fade_in_pos++;
    }
  }

  /* delay-change fade-in (second half of a delay change) */
  if (st->delay_fade_in > 0) {
    for (i = 0; i < DELAY_FADE; i++) blk[i] *= (float)i / DELAY_FADE;
    st->delay_fade_in = 0;
  }

  /* apply a pending delay change in a quiet block, never while fading */
  if (st->L == want_L) {
    st->quiet_wait = 0;
  } else if (st->cur == st->next && st->cur != SRC_EXT) {
    st->quiet_wait++;
    if ((vad < 0.3f && in_rms_db < -40.f) || st->quiet_wait >= DELAY_FORCE_BLOCKS) {
      for (i = 0; i < DELAY_FADE; i++) blk[GX_NS_BLOCK - DELAY_FADE + i] *= 1.f - (float)(i + 1) / DELAY_FADE;
      st->L = want_L;
      st->quiet_wait = 0;
      st->delay_fade_in = 1;
      if (st->rc)
        atomic_store_explicit(&st->pub_latency, latency_for(st, st->rc, st->prefill), memory_order_relaxed);
    }
  }

  limiter_block(st, blk);

  st->vad = vad;
  atomic_store_explicit(&st->pub_vad, vad, memory_order_relaxed);
  atomic_store_explicit(&st->pub_gain_db, st->gain_db, memory_order_relaxed);
  atomic_store_explicit(&st->pub_pregain_db, st->pg_gain_db, memory_order_relaxed);
  atomic_store_explicit(&st->pub_pg_applied_db, st->pg_applied_db, memory_order_relaxed);
  atomic_store_explicit(&st->pub_agc_applied_db, !agc_on ? 0.f : agc_order == GX_NS_AGC_AFTER_NS ? gated_db(st, st->gain_db) : st->gain_db, memory_order_relaxed);
  atomic_store_explicit(&st->pub_talk, st->talk_now || st->talk_hang > 0, memory_order_relaxed);
  atomic_store_explicit(&st->pub_active, st->cur, memory_order_relaxed);
  atomic_store_explicit(&st->pub_xfade, st->cur != st->next, memory_order_relaxed);
  atomic_store_explicit(&st->pub_reason, (int)st->reason, memory_order_relaxed);
  atomic_fetch_add_explicit(&st->blocks, 1, memory_order_release);
}

static void process_chunk(gx_ns *st, float *x, int n) {
  rate_ctx *r = st->rc;
  int got;
  if (!r->up) {
    fifo_push(&st->in48, x, n);
  } else {
    spx_uint32_t in_len = (spx_uint32_t)n, out_len = (spx_uint32_t)st->scratch48_cap;
    gx_resampler_process_float(r->up, 0, x, &in_len, st->scratch_in48, &out_len);
    fifo_push(&st->in48, st->scratch_in48, (int)out_len);
  }
  while (st->in48.count >= GX_NS_BLOCK) {
    fifo_pop(&st->in48, st->blk, GX_NS_BLOCK);
    process_block(st, st->blk);
    if (!r->up) {
      fifo_push(&st->out_r, st->blk, GX_NS_BLOCK);
    } else {
      spx_uint32_t in_len = GX_NS_BLOCK, out_len = (spx_uint32_t)st->scratch_r_cap;
      gx_resampler_process_float(r->down, 0, st->blk, &in_len, st->scratch_out_r, &out_len);
      fifo_push(&st->out_r, st->scratch_out_r, (int)out_len);
    }
  }
  got = fifo_pop(&st->out_r, x, n);
  if (got < n) {
    memset(x + got, 0, sizeof(float) * (size_t)(n - got));
    atomic_fetch_add_explicit(&st->underflows, 1, memory_order_relaxed);
    st->need_reprime = 1; /* next call re-primes with a larger prefill and fades in */
  }
}

int gx_ns_process(gx_ns *st, float *samples, int n, int sample_rate) {
  uint64_t t0 = gx_timer_now_ns();
  rate_ctx *r;
  uint32_t sr;
  if (n <= 0) return 0;
  r = (st->rc && st->rc->rate == sample_rate) ? st->rc : find_rate(st, sample_rate);
  if (!r) return -1;
  sr = atomic_load_explicit(&st->req_stats_reset, memory_order_relaxed);
  if (sr != st->stats_reset_seen) {
    st->stats_reset_seen = sr;
    gx_timer_clear(&st->timer);
    atomic_store_explicit(&st->underflows, 0, memory_order_relaxed);
    atomic_store_explicit(&st->ext_errors, 0, memory_order_relaxed);
    atomic_store_explicit(&st->switches, 0, memory_order_relaxed);
  }
  if (r != st->rc || st->need_reprime) {
    int underflowed = (r == st->rc);
    stream_reset(st, r, n, atomic_load_explicit(&st->ext_ptr, memory_order_acquire));
    if (underflowed && !r->up && st->prefill == 0) {
      /* frame size changed to a non-multiple of 10 ms at 48 kHz */
      fifo_push(&st->out_r, NULL, GX_NS_BLOCK);
      st->prefill = GX_NS_BLOCK;
      atomic_store_explicit(&st->pub_latency, latency_for(st, r, st->prefill), memory_order_relaxed);
    }
  }
  while (n > 0) {
    int c = n < st->cfg.max_frame_samples ? n : st->cfg.max_frame_samples;
    process_chunk(st, samples, c);
    samples += c;
    n -= c;
  }
  gx_timer_add(&st->timer, (uint32_t)((gx_timer_now_ns() - t0) / 1000u));
  return 0;
}

void gx_ns_get_stats(gx_ns *st, gx_ns_stats *o) {
  memset(o, 0, sizeof(*o));
  o->frames = atomic_load_explicit(&st->timer.count, memory_order_relaxed);
  o->p50_us = gx_timer_percentile(&st->timer, 0.50);
  o->p95_us = gx_timer_percentile(&st->timer, 0.95);
  o->p99_us = gx_timer_percentile(&st->timer, 0.99);
  o->max_us = atomic_load_explicit(&st->timer.max_us, memory_order_relaxed);
  o->over_budget = atomic_load_explicit(&st->timer.over, memory_order_relaxed);
  o->consecutive_over = atomic_load_explicit(&st->timer.consecutive, memory_order_relaxed);
  o->underflows = atomic_load_explicit(&st->underflows, memory_order_relaxed);
  o->ext_errors = atomic_load_explicit(&st->ext_errors, memory_order_relaxed);
  o->engine_switches = atomic_load_explicit(&st->switches, memory_order_relaxed);
  o->ext_p95_us = atomic_load_explicit(&st->pub_ext_p95, memory_order_relaxed);
  o->ext_slow = atomic_load_explicit(&st->pub_ext_slow, memory_order_relaxed);
  o->ext_suppress = atomic_load_explicit(&st->pub_ext_suppress, memory_order_relaxed);
}

void gx_ns_get_status(gx_ns *st, gx_ns_status *o) {
  memset(o, 0, sizeof(*o));
  o->requested = (gx_ns_engine)atomic_load(&st->req_engine);
  o->active = src_engine(atomic_load_explicit(&st->pub_active, memory_order_relaxed));
  o->crossfading = atomic_load_explicit(&st->pub_xfade, memory_order_relaxed);
  o->reason = (gx_ns_reason)atomic_load_explicit(&st->pub_reason, memory_order_relaxed);
  o->rate = atomic_load_explicit(&st->pub_rate, memory_order_relaxed);
  o->latency_samples = atomic_load_explicit(&st->pub_latency, memory_order_relaxed);
  o->vad = atomic_load_explicit(&st->pub_vad, memory_order_relaxed);
  o->agc_gain_db = atomic_load_explicit(&st->pub_gain_db, memory_order_relaxed);
  o->pregain_db = atomic_load_explicit(&st->pub_pregain_db, memory_order_relaxed);
  o->pregain_applied_db = atomic_load_explicit(&st->pub_pg_applied_db, memory_order_relaxed);
  o->agc_applied_db = atomic_load_explicit(&st->pub_agc_applied_db, memory_order_relaxed);
  o->pause_att_db = atomic_load_explicit(&st->pub_pause_att_db, memory_order_relaxed);
  o->talk = atomic_load_explicit(&st->pub_talk, memory_order_relaxed);
}

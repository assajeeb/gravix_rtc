/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Pre-gain (before NS) and the studio_suppress guard (device run 2026-10-21:
 * DFN3 erased a quiet iPhone mic, -47 dBFS speech in -> silence out):
 * quiet speech is lifted to the target, loud speech is left alone, noise alone
 * never pumps the gain, the soft limiter holds, a collapsing studio engine is
 * demoted to RNNoise. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000

static int collapse_process(void *u, float *out, const float *in, int n) { /* -60 dB: "erases" speech */
  int i; (void)u;
  for (i = 0; i < n; i++) out[i] = in[i] * 0.001f;
  return 0;
}
static int pass_process(void *u, float *out, const float *in, int n) {
  int i; (void)u;
  for (i = 0; i < n; i++) out[i] = in[i] * 0.7f;
  return 0;
}

static int quiet_eraser(void *u, float *out, const float *in, int n) { /* DFN3 on a quiet iPhone mic: blocks under -45 dBFS erased */
  int i; double e = 0; (void)u;
  for (i = 0; i < n; i++) e += (double)in[i] * in[i];
  e = 10.0 * log10(e / n + 1e-20);
  for (i = 0; i < n; i++) out[i] = e < -45.0 ? in[i] * 0.001f : in[i];
  return 0;
}

static struct gx_ns *mk(int agc) {
  gx_ns_config c;
  gx_ns_default_config(&c);
  c.agc_enabled = agc;
  c.max_external_latency = 1440;
  return gx_ns_create(&c);
}

int main(void) {
  int len = SR * 12, i;
  float *x = malloc(sizeof(float) * len), *y = malloc(sizeof(float) * len);
  gx_ns_status s;
  gx_ns_stats t;

  CHECK(fabsf(gx_ns_pregain_for_level(-45.f) - 19.f) < 1e-4f, "for_level(-45) = %.2f", gx_ns_pregain_for_level(-45.f));
  CHECK(gx_ns_pregain_for_level(-10.f) == 0.f, "loud: no boost");
  CHECK(gx_ns_pregain_for_level(-90.f) == (float)GX_NS_DEFAULT_PREGAIN_MAX_DB, "capped at max");

  /* quiet speech: the gain settles near target - level (RNNoise path, AGC off) */
  {
    /* -66/-70: a very quiet phone mic route (review 2026-10-21: the talk floor
     * at -62 dB with the pre-gain out kept these from ever being lifted) */
    const double levels[] = {-70, -66, -50, -40, -30};
    int li;
    for (li = 0; li < 5; li++) {
      struct gx_ns *st = mk(0);
      double want = GX_NS_DEFAULT_PREGAIN_TARGET_DBFS - levels[li];
      if (want > GX_NS_DEFAULT_PREGAIN_MAX_DB) want = GX_NS_DEFAULT_PREGAIN_MAX_DB;
      gen_speechlike(x, len, SR, levels[li]);
      memcpy(y, x, sizeof(float) * len);
      run_frames(st, y, len, F, SR);
      gx_ns_get_status(st, &s);
      CHECK(fabs(s.pregain_db - want) <= 3.0, "speech %.0f dBFS: pregain %.2f dB (want %.1f)", levels[li], s.pregain_db, want);
      printf("pregain speech %6.1f dBFS -> %+.2f dB\n", levels[li], s.pregain_db);
      gx_ns_destroy(st);
    }
  }
  /* very quiet speech, pre-gain + AGC: lifted by at least 30 dB (pauses stay unboosted: pause gate) */
  {
    const double levels[] = {-70, -66};
    int li;
    for (li = 0; li < 2; li++) {
      struct gx_ns *st = mk(1);
      double out;
      gen_speechlike(x, len, SR, levels[li]);
      memcpy(y, x, sizeof(float) * len);
      run_frames(st, y, len, F, SR);
      out = active_rms_db(y + SR * 8, x + SR * 8, len - SR * 8, F); /* last 4 s, settled */
      CHECK(out - levels[li] >= 30.0, "speech %.0f dBFS + AGC: out %.1f dBFS", levels[li], out);
      printf("pregain+agc speech %6.1f dBFS -> out %.1f dBFS\n", levels[li], out);
      gx_ns_destroy(st);
    }
  }
  /* loud speech: never attenuated */
  {
    struct gx_ns *st = mk(0);
    gen_speechlike(x, len, SR, -12);
    run_frames(st, x, len, F, SR);
    gx_ns_get_status(st, &s);
    CHECK(s.pregain_db == 0.f, "loud speech: pregain %.2f", s.pregain_db);
    gx_ns_destroy(st);
  }
  /* noise only: the gain holds at unity (no pumping in pauses) */
  {
    struct gx_ns *st = mk(1);
    gen_noise(x, len, 32768.0 * pow(10, -55 / 20.0) * sqrt(3.0), 9);
    run_frames(st, x, len, F, SR);
    gx_ns_get_status(st, &s);
    CHECK(s.pregain_db <= 1.0, "noise-only pregain %.2f dB", s.pregain_db);
    gx_ns_destroy(st);
  }
  /* faint noise only (a quiet room at the lowered talk floor): no talk, no pumping */
  {
    struct gx_ns *st = mk(1);
    gen_noise(x, len, 32768.0 * pow(10, -72 / 20.0) * sqrt(3.0), 5);
    run_frames(st, x, len, F, SR);
    gx_ns_get_status(st, &s);
    CHECK(s.pregain_db <= 1.0 && s.agc_gain_db <= 1.0, "faint noise: pregain %.2f agc %.2f", s.pregain_db, s.agc_gain_db);
    gx_ns_destroy(st);
  }
  /* speech then a long pause of noise: the gain is held, not raised */
  {
    struct gx_ns *st = mk(0);
    float g0;
    gen_speechlike(x, SR * 6, SR, -45);
    gen_noise(x + SR * 6, len - SR * 6, 32768.0 * pow(10, -70 / 20.0) * sqrt(3.0), 3);
    run_frames(st, x, SR * 6, F, SR);
    gx_ns_get_status(st, &s);
    g0 = s.pregain_db;
    run_frames(st, x + SR * 6, len - SR * 6, F, SR);
    gx_ns_get_status(st, &s);
    CHECK(s.pregain_db <= g0 + 0.5f, "pause: pregain %.2f -> %.2f (held)", g0, s.pregain_db);
    gx_ns_destroy(st);
  }
  /* soft limiter: boosted peaks stay under full scale */
  {
    struct gx_ns *st = mk(0);
    double pk = 0;
    gen_speechlike(x, len, SR, -50);
    for (i = SR * 6; i < SR * 6 + 4800; i++) x[i] = ((i / 40) % 2) ? 8000.f : -8000.f; /* a loud burst at +30 dB gain */
    run_frames(st, x, len, F, SR);
    for (i = 0; i < len; i++) if (fabs(x[i]) > pk) pk = fabs(x[i]);
    CHECK(pk <= 32767.0, "peak %.1f", pk);
    gx_ns_destroy(st);
  }
  /* pre-gain off (engine off, or disabled): unity */
  {
    struct gx_ns *st = mk(0);
    gx_ns_set_pregain(st, 0);
    gen_speechlike(x, len, SR, -50);
    run_frames(st, x, len, F, SR);
    gx_ns_get_status(st, &s);
    CHECK(s.pregain_db == 0.f, "disabled: %.2f", s.pregain_db);
    gx_ns_destroy(st);
  }

  /* a studio engine that erases quiet speech (DFN3 under ~-45 dBFS, iPhone
   * 2026-10-21): talk is judged on the louder of it and RNNoise's shadow, so the
   * pre-gain still learns and lifts the speech over its threshold (it was judged
   * on the eraser's output alone: no talk, no pre-gain, speech erased for 57 s) */
  {
    struct gx_ns *st = mk(1);
    gx_ns_external_engine e;
    double out;
    memset(&e, 0, sizeof(e));
    e.process = quiet_eraser; e.latency_samples = 480;
    gx_ns_set_external_engine(st, &e);
    gx_ns_set_engine(st, GX_NS_ENGINE_DFN3);
    gen_speechlike(x, len, SR, -55);
    memcpy(y, x, sizeof(float) * len);
    run_frames(st, y, len, F, SR);
    gx_ns_get_status(st, &s);
    out = active_rms_db(y + SR * 1, x + SR * 1, SR * 3, F); /* seconds 1-4: no erased start */
    CHECK(s.pregain_db >= 15.f, "quiet speech under an eraser: pregain %.2f dB", s.pregain_db);
    CHECK(s.active == GX_NS_ENGINE_DFN3, "the engine stays (not demoted for erasing): %s %s", gx_ns_engine_name(s.active), gx_ns_reason_name(s.reason));
    CHECK(out > -30.0, "quiet speech under an eraser, seconds 1-4: out %.1f dBFS", out);
    printf("eraser: -55 dBFS speech -> pregain %+.1f, out %.1f dBFS, %s\n", s.pregain_db, out, gx_ns_engine_name(s.active));
    gx_ns_destroy(st);
  }
  /* studio_suppress: an engine that erases speech is demoted after ~2 s of speech;
   * a sane engine stays; re-attaching clears the flag */
  {
    struct gx_ns *st = mk(1);
    gx_ns_external_engine e;
    memset(&e, 0, sizeof(e));
    e.process = collapse_process; e.latency_samples = 480;
    gx_ns_set_external_engine(st, &e);
    gx_ns_set_engine(st, GX_NS_ENGINE_DFN3);
    gen_speechlike(x, len, SR, -40);
    run_frames(st, x, len, F, SR);
    gx_ns_get_status(st, &s);
    gx_ns_get_stats(st, &t);
    CHECK(s.active == GX_NS_ENGINE_RNNOISE && s.reason == GX_NS_REASON_EXT_SUPPRESS && !strcmp(gx_ns_reason_name(s.reason), "studio_suppress"),
          "collapsing engine: %s %s", gx_ns_engine_name(s.active), gx_ns_reason_name(s.reason));
    CHECK(t.ext_suppress == 1, "stats suppress=%u", t.ext_suppress);
    e.process = pass_process;
    gx_ns_set_external_engine(st, &e);
    gen_speechlike(x, len, SR, -40);
    run_frames(st, x, len, F, SR);
    gx_ns_get_status(st, &s);
    gx_ns_get_stats(st, &t);
    CHECK(s.active == GX_NS_ENGINE_DFN3 && t.ext_suppress == 0, "sane engine kept: %s suppress=%u", gx_ns_engine_name(s.active), t.ext_suppress);
    gx_ns_destroy(st);
  }
  free(x); free(y);
  return TEST_DONE();
}

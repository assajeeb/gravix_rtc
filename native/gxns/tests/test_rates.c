/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Fixed-latency FIFO + resampler: every rate x frame size gives N out per N in,
 * a constant latency equal to gx_ns_latency_samples(), unity gain on a tone and
 * no pitch shift (dry path, AGC off). */
#include <string.h>
#include "gx_ns.h"
#include "speex_resampler.h"
#include "test_util.h"

static const int rates[] = {8000, 16000, 24000, 32000, 44100, 48000};

static struct gx_ns *mk(gx_ns_engine e) {
  gx_ns_config c;
  gx_ns_default_config(&c);
  c.agc_enabled = 0;
  c.initial_engine = e;
  return gx_ns_create(&c);
}

int main(void) {
  int ri, fi;
  for (ri = 0; ri < 6; ri++) {
    int rate = rates[ri];
    int frames[] = {rate / 100, rate / 50, 128, 97};
    int len = rate * 2;
    for (fi = 0; fi < 4; fi++) {
      int frame = frames[fi], lat, lag, used = len - len % frame;
      float *x = malloc(sizeof(float) * len), *y = malloc(sizeof(float) * len);
      struct gx_ns *st = mk(GX_NS_ENGINE_OFF);
      gx_ns_stats s;
      gx_ns_status stt;
      double f = rate / 16.0 > 1000 ? 1000 : rate / 16.0, fo, li, lo;

      /* latency: broadband noise cross-correlation */
      gen_noise(x, len, 8000, 7 + ri);
      memcpy(y, x, sizeof(float) * len);
      run_frames(st, y, used, frame, rate);
      lat = gx_ns_latency_samples(st, rate);
      lag = best_lag(x, y, used, lat + 300);
      CHECK(abs(lag - lat) <= 1, "rate %d frame %d: measured lag %d vs reported %d", rate, frame, lag, lat);
      gx_ns_get_status(st, &stt);
      CHECK(stt.latency_samples == lat && stt.rate == rate, "status latency %d rate %d", stt.latency_samples, stt.rate);
      gx_ns_get_stats(st, &s);
      CHECK(s.underflows == 0, "rate %d frame %d: underflows %u", rate, frame, s.underflows);
      if (fi == 0) printf("rate %5d: latency %d samples (%.2f ms) at 10 ms frames\n", rate, lat, 1000.0 * lat / rate);
      gx_ns_destroy(st);

      /* tone: unity level, same pitch */
      st = mk(GX_NS_ENGINE_OFF);
      gen_tone(x, len, f, rate, 3277, 0.3);
      memcpy(y, x, sizeof(float) * len);
      run_frames(st, y, used, frame, rate);
      li = rms_db(x + rate / 2, rate);
      lo = rms_db(y + rate / 2, rate);
      fo = est_freq(y + rate / 2, rate, rate);
      CHECK(fabs(lo - li) < 0.3, "rate %d frame %d: tone level in %.2f out %.2f dB", rate, frame, li, lo);
      CHECK(fabs(fo - f) / f < 5e-4, "rate %d frame %d: tone %.2f Hz -> %.2f Hz", rate, frame, f, fo);
      gx_ns_get_stats(st, &s);
      CHECK(s.underflows == 0, "tone underflows %u", s.underflows);
      gx_ns_destroy(st);

      /* RNNoise path at this rate: runs, finite, no underflow */
      st = mk(GX_NS_ENGINE_RNNOISE);
      gen_noise(y, len, 3000, 99);
      { int i; for (i = 0; i < len; i++) y[i] += x[i]; }
      run_frames(st, y, used, frame, rate);
      { int i, bad = 0; for (i = 0; i < used; i++) if (!isfinite(y[i])) bad++; CHECK(bad == 0, "non-finite %d", bad); }
      gx_ns_get_stats(st, &s);
      CHECK(s.underflows == 0, "rnnoise rate %d frame %d underflows %u", rate, frame, s.underflows);
      gx_ns_destroy(st);
      free(x); free(y);
    }
  }

  /* the resampler alone: R -> 48 kHz keeps the pitch */
  for (ri = 0; ri < 5; ri++) {
    int rate = rates[ri], err, len = rate, olen = 48000 + 100;
    float *x = malloc(sizeof(float) * len), *y = malloc(sizeof(float) * olen);
    spx_uint32_t il = (spx_uint32_t)len, ol = (spx_uint32_t)olen;
    SpeexResamplerState *r = gx_resampler_init(1, (spx_uint32_t)rate, 48000, 5, &err);
    double f = 440, fo;
    gen_tone(x, len, f, rate, 10000, 0);
    gx_resampler_process_float(r, 0, x, &il, y, &ol);
    fo = est_freq(y + 2000, (int)ol - 2000, 48000);
    CHECK(fabs(fo - f) / f < 2e-4, "resampler %d->48000: %.3f Hz -> %.3f Hz", rate, f, fo);
    gx_resampler_destroy(r);
    free(x); free(y);
  }

  /* rate change mid-stream (Bluetooth HFP 48k -> 16k -> 48k): no crash, fade-in, level back */
  {
    struct gx_ns *st = mk(GX_NS_ENGINE_OFF);
    float buf[960];
    int k;
    gx_ns_stats s;
    for (k = 0; k < 100; k++) { gen_tone(buf, 480, 1000, 48000, 3277, k * 480 * 2 * M_PI * 1000 / 48000); gx_ns_process(st, buf, 480, 48000); }
    for (k = 0; k < 100; k++) { gen_tone(buf, 160, 1000, 16000, 3277, k * 160 * 2 * M_PI * 1000 / 16000); gx_ns_process(st, buf, 160, 16000); }
    CHECK(fabs(rms_db(buf, 160) + 23.01) < 0.5, "16k level %.2f", rms_db(buf, 160));
    for (k = 0; k < 100; k++) { gen_tone(buf, 480, 1000, 48000, 3277, k * 480 * 2 * M_PI * 1000 / 48000); gx_ns_process(st, buf, 480, 48000); }
    CHECK(fabs(rms_db(buf, 480) + 23.01) < 0.5, "48k level back %.2f", rms_db(buf, 480));
    CHECK(gx_ns_process(st, buf, 480, 22050) == -1, "unsupported rate rejected");
    gx_ns_get_stats(st, &s);
    CHECK(s.underflows == 0, "underflows %u", s.underflows);
    gx_ns_destroy(st);
  }
  return TEST_DONE();
}

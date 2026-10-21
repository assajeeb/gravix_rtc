/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* Noise suppression must not defeat Opus DTX (on by default since 2026-10-21):
 * in pauses the pre-gain holds (no boost) and our AGC does not lift the noise
 * floor, so the output stays under about -50 dBFS (Opus' VAD then sees
 * silence). Default chain: RNNoise + pre-gain + AGC after NS. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define F 480
#define SR 48000
#define LIMIT_DB (-50.0)

static struct gx_ns *mk(void) {
  gx_ns_config c;
  gx_ns_default_config(&c); /* RNNoise, pre-gain on, AGC on, after NS */
  return gx_ns_create(&c);
}

static double noise_amp(double dbfs) { return 32768.0 * pow(10, dbfs / 20.0) * sqrt(3.0); }

/* Pink-ish room noise (Paul Kellet's filter on white) scaled to dbfs RMS. */
static void gen_pink(float *x, int n, double dbfs, unsigned seed) {
  double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, acc = 0, g;
  int i;
  gen_noise(x, n, 1.0, seed);
  for (i = 0; i < n; i++) {
    double w = x[i], p;
    b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759;
    b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856;
    b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980;
    p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362; b6 = w * 0.115926;
    x[i] = (float)p; acc += p * p;
  }
  g = 32768.0 * pow(10, dbfs / 20.0) / sqrt(acc / n);
  for (i = 0; i < n; i++) x[i] *= (float)g;
}

int main(void) {
  const double floors[] = {-70, -60, -50, -45, -40};
  int len = SR * 5, fi;
  float *x = malloc(sizeof(float) * SR * 10);
  gx_ns_status s;
  /* 5 s of noise only, several room floors: pink-ish room noise at every
   * floor, white hiss up to -50 dBFS (louder white hiss passes RNNoise itself
   * with no gain of ours: not a gain question) */
  for (fi = 0; fi < 10; fi++) {
    struct gx_ns *st;
    double out;
    int pink = fi >= 5;
    if (!pink && floors[fi] > -50) continue;
    st = mk();
    if (pink) gen_pink(x, len, floors[fi - 5], 11 + fi);
    else gen_noise(x, len, noise_amp(floors[fi]), 11 + fi);
    run_frames(st, x, len, F, SR);
    out = rms_db(x + SR * 2, SR * 3);
    gx_ns_get_status(st, &s);
    printf("%s noise %5.1f dBFS -> out %6.1f dBFS (pregain %+.1f agc %+.1f)\n", pink ? "pink " : "white", floors[fi % 5], out,
           s.pregain_db, s.agc_gain_db);
    CHECK(out < LIMIT_DB, "%s noise %.0f dBFS: out %.1f dBFS >= %.0f", pink ? "pink" : "white", floors[fi % 5], out, LIMIT_DB);
    /* the held pre-gain value stays put; at a loud fluctuating floor it may
     * learn from a noise burst, but the pause gate keeps it off the output */
    if (floors[fi % 5] <= -45) CHECK(s.pregain_db <= 1.0f, "noise %.0f dBFS: pregain %.2f dB (must hold)", floors[fi % 5], s.pregain_db);
    gx_ns_destroy(st);
  }
  /* quiet speech over the room noise (gains raised), then a 5 s pause of that
   * noise alone: the held gains must not lift the pause over the DTX threshold.
   * Speech at least 10 dB over the floor (a talker the NS can tell apart). */
  {
    const double speech[] = {-50, -40, -30};
    float *sp = malloc(sizeof(float) * SR * 4);
    int si, i;
    for (si = 0; si < 3; si++) {
      for (fi = 0; fi < 5; fi++) {
        struct gx_ns *st;
        double out;
        if (floors[fi] > speech[si] - 10) continue;
        st = mk();
        gen_noise(x, SR * 4 + len, noise_amp(floors[fi]), 21 + fi);
        gen_speechlike(sp, SR * 4, SR, speech[si]);
        for (i = 0; i < SR * 4; i++) x[i] += sp[i];
        run_frames(st, x, SR * 4 + len, F, SR);
        out = rms_db(x + SR * 6, SR * 3);
        gx_ns_get_status(st, &s);
        printf("speech %5.1f then noise %5.1f -> pause out %6.1f dBFS (pregain %+.1f agc %+.1f)\n", speech[si], floors[fi], out,
               s.pregain_db, s.agc_gain_db);
        CHECK(out < LIMIT_DB, "speech %.0f + noise %.0f dBFS: pause out %.1f dBFS >= %.0f", speech[si], floors[fi], out, LIMIT_DB);
        gx_ns_destroy(st);
      }
    }
    free(sp);
  }
  /* onsets after a pause: the gains a quiet mic needs (pre-gain ~+20 dB, AGC)
   * must be there from the first words, not ramp in over a second.
   * -45 dBFS speech over -70 dBFS room noise, a 3 s pause, speech again: the
   * first 300 ms of the second talk spurt within 6 dB of steady speech. */
  {
    const double floors2[] = {-70, -60};
    int k;
    for (k = 0; k < 2; k++) {
      int talk = SR * 4, pause = SR * 3, n = talk + pause + talk, i, L, on = talk + pause, first;
      float *in = malloc(sizeof(float) * n), *ref = malloc(sizeof(float) * n), *sp = malloc(sizeof(float) * talk),
            *y = malloc(sizeof(float) * n);
      struct gx_ns *st = mk();
      double steady, onset;
      gen_pink(in, n, floors2[k], 31 + k);
      memset(ref, 0, sizeof(float) * n);
      gen_speechlike(sp, talk, SR, -45);
      for (i = 0; i < talk; i++) { in[i] += sp[i]; ref[i] = sp[i]; }
      gen_speechlike(sp, talk, SR, -45);
      for (i = 0; i < talk; i++) { in[on + i] += sp[i]; ref[on + i] = sp[i]; }
      memcpy(y, in, sizeof(float) * n);
      run_frames(st, y, n, F, SR);
      L = gx_ns_latency_samples(st, SR);
      /* the first active 300 ms of the second spurt */
      for (first = on; first < n && fabs(ref[first]) < 1.f; first++) {}
      onset = active_rms_db(y + first + L, ref + first, SR * 3 / 10, F);
      steady = active_rms_db(y + n - SR * 2, ref + n - SR * 2 - L, SR * 2 - L, F);
      printf("onset after 3 s pause (floor %.0f): first 300 ms %6.1f dBFS, steady %6.1f dBFS\n", floors2[k], onset, steady);
      CHECK(onset > steady - 6.0, "floor %.0f: onset %.1f dBFS vs steady %.1f dBFS (> 6 dB quieter)", floors2[k], onset, steady);
      gx_ns_destroy(st);
      free(in); free(ref); free(sp); free(y);
    }
  }
  free(x);
  return TEST_DONE();
}

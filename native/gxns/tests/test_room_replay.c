/* Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE. */
/* A real room (2026-10-21, Xiaomi raw mic before the pre-gain;
 * tools/gxns_replay.c replays the full 163 s recording): 2.5 s of the quiet
 * room, then 3.5 s of a speech clip played from a laptop ~1 m away, resampled
 * to 16 kHz (the core's 16 kHz path). The quiet room must stay DTX-quiet (no
 * gain of ours lifts it) and the speech must reach the AGC target.
 *
 * The recording is private (a real home) and never in the repository: the
 * test reads it from $GXNS_ROOM_FIXTURE (default: a local
 * path below) and is skipped (exit 0) when it is not there. */
#include <string.h>
#include "gx_ns.h"
#include "test_util.h"

#define SR 16000
#define ROOM_FIXTURE_DEFAULT "room_fixture.pcm"
#define F 160

int main(void) {
  float *x;
  const char *path = getenv("GXNS_ROOM_FIXTURE") ? getenv("GXNS_ROOM_FIXTURE") : ROOM_FIXTURE_DEFAULT;
  int n, i, L, a, act = 0;
  gx_ns_config c;
  struct gx_ns *st;
  gx_ns_status s;
  double quiet, acc = 0;
  {
    FILE *probe = fopen(path, "rb");
    if (!probe) {
      printf("room replay: SKIPPED (private recording not here: %s)\n", path);
      return 0;
    }
    fclose(probe);
  }
  n = read_pcm(path, &x);
  CHECK(n == SR * 6, "fixture: %d samples", n);
  gx_ns_default_config(&c);
  st = gx_ns_create(&c);
  for (i = 0; i + F <= n; i += F) gx_ns_process(st, x + i, F, SR);
  L = gx_ns_latency_samples(st, SR);
  quiet = rms_db(x + SR / 2 + L, SR * 2 - L); /* 0.5-2.5 s */
  for (a = SR * 4 + L; a + F <= n; a += F) { /* the last 2 s of speech: blocks over -45 dBFS */
    double r = rms_db(x + a, F);
    if (r > -45) { int k; for (k = 0; k < F; k++) acc += (double)x[a + k] * x[a + k]; act += F; }
  }
  gx_ns_get_status(st, &s);
  {
    double speech = act ? 10 * log10(acc / act / (32768.0 * 32768.0)) : -200;
    printf("room replay: quiet %.1f dBFS, speech %.1f dBFS over %d%% (pregain held %+.1f applied %+.1f, agc held %+.1f applied %+.1f)\n",
           quiet, speech, act * 100 / (SR * 2), s.pregain_db, s.pregain_applied_db, s.agc_gain_db, s.agc_applied_db);
    CHECK(quiet < -55.0, "quiet room %.1f dBFS (DTX)", quiet);
    CHECK(speech > -17.0 && speech < -11.0, "speech %.1f dBFS (AGC target %d)", speech, GX_NS_DEFAULT_AGC_TARGET_DBFS);
    CHECK(s.talk == 1 && s.agc_applied_db > 0.f, "talk %d, agc applied %.1f", s.talk, s.agc_applied_db);
  }
  gx_ns_destroy(st);
  free(x);
  return TEST_DONE();
}

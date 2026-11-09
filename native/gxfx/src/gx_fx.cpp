// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.
//
// Voice effects chain: pitch/formant (Signalsmith Stretch) -> ring modulation ->
// drive -> echo -> tone -> compressor -> reverb (Freeverb structure, public
// domain design by Jezar at Dreampoint, delays scaled to the sample rate) ->
// soft limiter.
//
// A chain is built on the control thread and handed over with atomics; the
// audio thread never allocates or frees one. Every preset is one row of
// kPresets, so tuning does not touch the code.
#include "gx_fx.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include "../third_party/signalsmith-stretch.h"

namespace {

const int kMaxFrames = 4096;
const int kDefaultRate = 48000;
const int kPitchWindowMs = 40;
const int kPitchIntervalMs = 10;
const float kTwoPi = 6.28318530717958647692f;

struct Preset {
  float pitch, formant;           // semitones; formant relative to the original voice
  float room, damp, wet, dry;     // reverb; wet 0 = no reverb
  float ringHz, ringMix;
  float drive;                    // 1 = none
  float echoMs, echoFeedback, echoMix;
  float highPassHz;               // 0 = none
  float peakHz, peakDb;
  bool compress;
  float lowPassHz, peak2Hz, peak2Db;
  int scale;                      // 0 none, or a kScales index + 1: snap the voice to the scale
};

// Semitones of each scale (0 = C).
const bool kScales[3][12] = {
    {1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1},  // C major
    {1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1},  // A minor: the same notes as C major
    {1, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1},  // A harmonic minor
};

const Preset kPresets[GX_FX_PRESET_COUNT] = {
    //       pitch formant room  damp  wet   dry   ringHz ringMix drive echoMs fb    mix   hp   peakHz peakDb comp
    /*none*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*stud*/ {0, 0, 0.30f, 0.60f, 0.30f, 0.95f, 0, 0, 1, 0, 0, 0, 90, 3000, 2.5f, true},
    /*hall*/ {0, 0, 0.88f, 0.30f, 0.90f, 0.80f, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*robo*/ {0, 0, 0, 0, 0, 1, 110, 0.90f, 1, 18, 0.35f, 0.30f, 0, 0, 0, false},
    /*girl*/ {5, 3, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*tran*/ {-7, -4, 0.30f, 0.50f, 0.45f, 0.90f, 70, 0.50f, 1.6f, 12, 0.30f, 0.25f, 0, 0, 0, false},
    // Voice change. The numbers are starting points, tuned by ear.
    /*boy */ {6, 5, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*chld*/ {3, 3, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*womn*/ {3, 2, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*man */ {-4, -2.5f, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*forn*/ {1, 1.5f, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1800, 2.5f, false},
    /*ethr*/ {2, 0, 0.92f, 0.20f, 1.10f, 0.70f, 0, 0, 1, 120, 0.45f, 0.35f, 0, 0, 0, false},
    // Voice character: tone only, so no added delay (falsetto excepted).
    /*magn*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 150, 3.5f, true, 0, 3000, 1.5f},
    /*frsh*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 120, 6000, 3, false},
    /*enrg*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 100, 2500, 3, true},
    /*rich*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 200, 3, false, 0, 4000, 1.5f},
    /*mufl*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false, 1800},
    /*rond*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 300, 3, false, 0, 5000, -2},
    /*fals*/ {5, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 120, 3000, 2, false},
    /*full*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 120, 3, true},
    /*cler*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 150, 4000, 4, false},
    /*resn*/ {0, 0, 0.20f, 0.40f, 0.15f, 0.95f, 0, 0, 1, 0, 0, 0, 0, 1000, 4, false},
    /*loud*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 100, 3000, 3, true},
    // Rooms.
    /*soft*/ {0, 0, 0.20f, 0.75f, 0.25f, 0.95f, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*larg*/ {0, 0, 0.65f, 0.45f, 0.50f, 0.85f, 0, 0, 1, 0, 0, 0, 0, 0, 0, false},
    /*vall*/ {0, 0, 0.75f, 0.40f, 0.50f, 0.80f, 0, 0, 1, 300, 0.40f, 0.35f, 0, 0, 0, false},
    /*base*/ {0, 0, 0.40f, 0.85f, 0.40f, 0.85f, 0, 0, 1, 0, 0, 0, 0, 0, 0, false, 3000},
    /*ktv */ {0, 0, 0.55f, 0.50f, 0.55f, 0.90f, 0, 0, 1, 80, 0.20f, 0.15f, 0, 0, 0, false},
    /*ektv*/ {0, 0, 0.60f, 0.45f, 0.65f, 0.90f, 0, 0, 1, 90, 0.25f, 0.20f, 90, 3500, 2.5f, true},
    /*popl*/ {0, 0, 0.45f, 0.55f, 0.35f, 0.95f, 0, 0, 1, 0, 0, 0, 90, 5000, 2, true},
    /*rock*/ {0, 0, 0.50f, 0.40f, 0.40f, 0.90f, 0, 0, 1.3f, 60, 0.15f, 0.15f, 100, 2500, 3, true},
    /*vcon*/ {0, 0, 0.80f, 0.35f, 0.75f, 0.85f, 0, 0, 1, 0, 0, 0, 90, 3000, 1.5f, false},
    /*gram*/ {0, 0, 0, 0, 0, 1, 0, 0, 1.3f, 0, 0, 0, 300, 1500, 3, false, 3400},
    // Scale snapping: no fixed shift, the pitch detector drives it.
    /*atC */ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false, 0, 0, 0, 1},
    /*atAm*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false, 0, 0, 0, 2},
    /*atHm*/ {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, false, 0, 0, 0, 3},
};

inline float flushDenormal(float v) { return std::fabs(v) < 1e-15f ? 0.f : v; }

struct Comb {
  std::vector<float> d; int i = 0; float store = 0, fb = 0, damp = 0;
  void init(int n, float feedback, float dampening) { d.assign(std::max(n, 1), 0.f); fb = feedback; damp = dampening; }
  inline float tick(float x) {
    float y = d[i];
    store = flushDenormal(y * (1 - damp) + store * damp);
    d[i] = x + store * fb;
    if (++i >= (int)d.size()) i = 0;
    return y;
  }
};

struct Allpass {
  std::vector<float> d; int i = 0;
  void init(int n) { d.assign(std::max(n, 1), 0.f); }
  inline float tick(float x) {
    float b = flushDenormal(d[i]);
    d[i] = x + b * 0.5f;
    if (++i >= (int)d.size()) i = 0;
    return b - x;
  }
};

struct Biquad {
  float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
  inline float tick(float x) {
    float y = b0 * x + z1;
    z1 = flushDenormal(b1 * x - a1 * y + z2);
    z2 = flushDenormal(b2 * x - a2 * y);
    return y;
  }
  void highPass(float hz, int rate) {
    float w = kTwoPi * hz / rate, c = std::cos(w), al = std::sin(w) / 1.414f, a0 = 1 + al;
    b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0;
  }
  void lowPass(float hz, int rate) {
    float w = kTwoPi * hz / rate, c = std::cos(w), al = std::sin(w) / 1.414f, a0 = 1 + al;
    b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0;
  }
  void peak(float hz, float db, int rate) {
    float A = std::pow(10.f, db / 40), w = kTwoPi * hz / rate, c = std::cos(w), al = std::sin(w) / 2.f, a0 = 1 + al / A;
    b0 = (1 + al * A) / a0; b1 = -2 * c / a0; b2 = (1 - al * A) / a0; a1 = b1; a2 = (1 - al / A) / a0;
  }
};

class Chain {
 public:
  Chain(int preset, int rate) : preset_(preset), rate_(rate), p_(kPresets[preset]) {
    dry_.assign(kMaxFrames, 0.f);
    if (p_.pitch != 0 || p_.scale != 0) {
      in_.assign(kMaxFrames, 0.f);
      stretch_.reset(new signalsmith::stretch::SignalsmithStretch<float>());
      stretch_->configure(1, rate * kPitchWindowMs / 1000, rate * kPitchIntervalMs / 1000);
      stretch_->setTransposeSemitones(p_.pitch);
      stretch_->setFormantSemitones(p_.formant, true);
      stretch_->setFormantBase(150.f / rate);
      latencyMs_ = (stretch_->inputLatency() + stretch_->outputLatency()) * 1000 / rate;
    }
    if (p_.scale != 0) {
      decim_ = std::max(1, rate / 12000);
      int effective = rate / decim_;
      window_ = effective * 30 / 1000;
      minLag_ = std::max(2, effective / 800);
      maxLag_ = effective / 60;
      yinRate_ = (float)effective;
      history_.assign(window_ + maxLag_ + 2, 0.f);
      yin_.assign(maxLag_ + 2, 0.f);
    }
    if (p_.wet > 0) {
      static const int combs[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
      static const int alls[4] = {556, 441, 341, 225};
      float scale = rate / 44100.f, fb = p_.room * 0.28f + 0.7f, damp = p_.damp * 0.4f;
      for (int i = 0; i < 8; i++) comb_[i].init((int)(combs[i] * scale), fb, damp);
      for (int i = 0; i < 4; i++) all_[i].init((int)(alls[i] * scale));
    }
    if (p_.echoMs > 0) echo_.assign(std::max(1, (int)(rate * p_.echoMs / 1000)), 0.f);
    if (p_.highPassHz > 0) hp_.highPass(p_.highPassHz, rate);
    if (p_.peakDb != 0 && p_.peakHz * 2 < rate) peak_.peak(p_.peakHz, p_.peakDb, rate);
    if (p_.peak2Db != 0 && p_.peak2Hz * 2 < rate) peak2_.peak(p_.peak2Hz, p_.peak2Db, rate);
    useLowPass_ = p_.lowPassHz > 0 && p_.lowPassHz * 2 < rate;
    if (useLowPass_) lowPass_.lowPass(p_.lowPassHz, rate);
    ringInc_ = kTwoPi * p_.ringHz / rate;
    attack_ = 1 - std::exp(-1000.f / (5.f * rate));
    release_ = 1 - std::exp(-1000.f / (120.f * rate));
  }

  int preset() const { return preset_; }
  int rate() const { return rate_; }
  int latencyMs() const { return latencyMs_; }
  float *dry() { return dry_.data(); }

  void process(float *x, int n) {
    if (p_.scale != 0) detectAndSnap(x, n);
    if (stretch_) {
      std::memcpy(in_.data(), x, sizeof(float) * n);
      const float *inputs[1] = {in_.data()};
      float *outputs[1] = {x};
      stretch_->process(inputs, n, outputs, n);
    }
    for (int i = 0; i < n; i++) {
      float s = x[i];
      if (p_.ringMix > 0) {
        s *= (1 - p_.ringMix) + p_.ringMix * std::sin(ringPhase_);
        ringPhase_ += ringInc_;
        if (ringPhase_ > kTwoPi) ringPhase_ -= kTwoPi;
      }
      if (p_.drive > 1) s = std::tanh(s * p_.drive) / std::tanh(p_.drive);
      if (!echo_.empty()) {
        float d = echo_[echoAt_];
        echo_[echoAt_] = flushDenormal(s + d * p_.echoFeedback);
        if (++echoAt_ >= (int)echo_.size()) echoAt_ = 0;
        s += d * p_.echoMix;
      }
      if (p_.highPassHz > 0) s = hp_.tick(s);
      if (p_.peakDb != 0) s = peak_.tick(s);
      if (p_.peak2Db != 0) s = peak2_.tick(s);
      if (useLowPass_) s = lowPass_.tick(s);
      if (p_.compress) s = compress(s);
      if (p_.wet > 0) {
        float in = s * 0.015f, sum = 0;
        for (auto &c : comb_) sum += c.tick(in);
        for (auto &a : all_) sum = a.tick(sum);
        s = s * p_.dry + sum * p_.wet;
      }
      x[i] = limit(s);
    }
  }

 private:
  inline float compress(float s) {
    float a = std::fabs(s);
    env_ += (a - env_) * (a > env_ ? attack_ : release_);
    env_ = flushDenormal(env_);
    const float threshold = 0.126f;  // -18 dB
    float g = 1.f;
    if (env_ > threshold) g = std::pow(threshold / env_, 2.f / 3.f);  // 3:1
    return s * g * 1.41f;                                            // +3 dB make-up
  }
  // YIN pitch detection on the input, then a smoothed shift to the nearest note of the scale.
  void detectAndSnap(const float *x, int n) {
    int size = (int)history_.size();
    for (int i = 0; i < n; i++) {
      decimSum_ += x[i];
      if (++decimCount_ < decim_) continue;
      std::memmove(history_.data(), history_.data() + 1, sizeof(float) * (size - 1));
      history_[size - 1] = decimSum_ / decim_;
      decimSum_ = 0;
      decimCount_ = 0;
    }
    float f0 = detectPitch();
    float target = 0;
    if (f0 > 0) {
      float midi = 69 + 12 * std::log2(f0 / 440.f);
      int base = (int)std::lround(midi);
      float best = 1000;
      const bool *scale = kScales[p_.scale - 1];
      for (int d = -2; d <= 2; d++) {
        int note = base + d;
        if (!scale[((note % 12) + 12) % 12]) continue;
        float shift = note - midi;
        if (std::fabs(shift) < std::fabs(best)) best = shift;
      }
      target = best;
    }
    shift_ += (target - shift_) * 0.35f;
    stretch_->setTransposeSemitones(shift_);
  }

  float detectPitch() {
    const float *h = history_.data();
    double energy = 0;
    for (int i = 0; i < window_; i++) energy += h[i] * h[i];
    if (energy / window_ < 1e-5) return 0;
    float *d = yin_.data();
    double running = 0;
    d[0] = 1;
    for (int tau = 1; tau <= maxLag_; tau++) {
      double sum = 0;
      for (int i = 0; i < window_; i++) { double v = h[i] - h[i + tau]; sum += v * v; }
      running += sum;
      d[tau] = running > 0 ? (float)(sum * tau / running) : 1.f;
    }
    for (int tau = minLag_; tau < maxLag_; tau++) {
      if (d[tau] >= 0.15f) continue;
      while (tau + 1 < maxLag_ && d[tau + 1] < d[tau]) tau++;
      float a = d[tau - 1], b = d[tau], c = d[tau + 1], denom = a - 2 * b + c;
      float refined = tau + (std::fabs(denom) > 1e-6f ? 0.5f * (a - c) / denom : 0);
      return yinRate_ / refined;
    }
    return 0;
  }

  static inline float limit(float s) {
    if (std::isnan(s)) return 0.f;
    float a = std::fabs(s);
    if (a <= 0.8f) return s;
    float o = 0.8f + 0.2f * std::tanh((a - 0.8f) / 0.2f);
    return s < 0 ? -o : o;
  }

  int preset_, rate_, latencyMs_ = 0;
  Preset p_;
  std::vector<float> dry_, in_, echo_;
  std::unique_ptr<signalsmith::stretch::SignalsmithStretch<float>> stretch_;
  Comb comb_[8];
  Allpass all_[4];
  Biquad hp_, peak_, peak2_, lowPass_;
  bool useLowPass_ = false;
  std::vector<float> history_, yin_;
  int decim_ = 1, decimCount_ = 0, window_ = 0, minLag_ = 0, maxLag_ = 0;
  float decimSum_ = 0, shift_ = 0, yinRate_ = 0;
  int echoAt_ = 0;
  float ringPhase_ = 0, ringInc_ = 0, env_ = 0, attack_ = 0, release_ = 0;
};

Chain *noneToken() {
  static Chain *t = new Chain(GX_FX_NONE, kDefaultRate);
  return t;
}

inline void ramp(float *x, int n, float from, float to) {
  float step = (to - from) / n, g = from;
  for (int i = 0; i < n; i++) { g += step; x[i] *= g; }
}

}  // namespace

struct gx_fx {
  // control -> audio
  std::atomic<Chain *> pending{nullptr};
  std::atomic<int> bypass{0};
  std::atomic<int> budgetUs{0};
  std::atomic<int> consecutive{0};
  std::atomic<unsigned> epoch{0};  // set_preset clears the watchdog through this
  // audio -> control
  std::atomic<Chain *> retired{nullptr};
  std::atomic<int> wantedRate{0};
  std::atomic<int> activePreset{GX_FX_NONE};
  std::atomic<int> activeRate{0};
  std::atomic<int> activeLatency{0};
  std::atomic<int> watchdog{0};
  std::atomic<unsigned> frames{0};
  std::atomic<unsigned> over{0};
  std::atomic<unsigned> maxUs{0};
  // audio thread only
  Chain *chain = nullptr;
  unsigned seenEpoch = 0;
  int overRun = 0;
  bool fadeIn = false;
  float wetGain = 1;
  // control thread only
  std::mutex control;
  int requested = GX_FX_NONE;
};

static void reapLocked(gx_fx *fx) {
  Chain *r = fx->retired.exchange(nullptr, std::memory_order_acq_rel);
  if (r) delete r;
}

static void publishLocked(gx_fx *fx, int preset) {
  reapLocked(fx);
  int rate = fx->wantedRate.load(std::memory_order_acquire);
  if (rate <= 0) rate = kDefaultRate;
  Chain *c = preset == GX_FX_NONE ? noneToken() : new Chain(preset, rate);
  Chain *old = fx->pending.exchange(c, std::memory_order_acq_rel);
  if (old && old != noneToken()) delete old;
}

extern "C" {

gx_fx *gx_fx_create(void) {
  noneToken();
  return new gx_fx();
}

void gx_fx_destroy(gx_fx *fx) {
  if (!fx) return;
  Chain *p = fx->pending.exchange(nullptr);
  if (p && p != noneToken()) delete p;
  reapLocked(fx);
  delete fx->chain;
  delete fx;
}

int gx_fx_set_preset(gx_fx *fx, int preset) {
  if (!fx || preset < 0 || preset >= GX_FX_PRESET_COUNT) return -1;
  std::lock_guard<std::mutex> l(fx->control);
  fx->requested = preset;
  publishLocked(fx, preset);
  fx->epoch.fetch_add(1, std::memory_order_release);
  fx->watchdog.store(0, std::memory_order_relaxed);
  return 0;
}

void gx_fx_rebuild(gx_fx *fx) {
  if (!fx) return;
  std::lock_guard<std::mutex> l(fx->control);
  if (fx->requested != GX_FX_NONE) publishLocked(fx, fx->requested);
  else reapLocked(fx);
}

void gx_fx_set_bypass(gx_fx *fx, int on) { if (fx) fx->bypass.store(on ? 1 : 0, std::memory_order_relaxed); }

void gx_fx_set_watchdog(gx_fx *fx, int budget_us, int consecutive) {
  if (!fx) return;
  fx->budgetUs.store(budget_us, std::memory_order_relaxed);
  fx->consecutive.store(consecutive, std::memory_order_relaxed);
}

void gx_fx_get_status(gx_fx *fx, gx_fx_status *o) {
  if (!fx || !o) return;
  std::lock_guard<std::mutex> l(fx->control);
  reapLocked(fx);
  o->requested = fx->requested;
  o->active = fx->activePreset.load(std::memory_order_relaxed);
  o->rate = fx->activeRate.load(std::memory_order_relaxed);
  o->bypass = fx->bypass.load(std::memory_order_relaxed);
  o->watchdog = fx->watchdog.load(std::memory_order_relaxed);
  o->latency_ms = fx->activeLatency.load(std::memory_order_relaxed);
  o->frames = fx->frames.load(std::memory_order_relaxed);
  o->over = fx->over.load(std::memory_order_relaxed);
  o->max_us = fx->maxUs.load(std::memory_order_relaxed);
}

int gx_fx_process_int16_scale(gx_fx *fx, float *pcm, int n, int rate) {
  if (!pcm || n <= 0 || n > kMaxFrames) return GX_FX_PASSTHROUGH;
  for (int i = 0; i < n; i++) pcm[i] *= 1.f / 32768.f;  // a power of two: an untouched block comes back exact
  int rc = gx_fx_process(fx, pcm, n, rate);
  for (int i = 0; i < n; i++) pcm[i] *= 32768.f;
  return rc;
}

int gx_fx_process(gx_fx *fx, float *pcm, int n, int rate) {
  Chain *next = fx->pending.load(std::memory_order_acquire);
  Chain *c = fx->chain;
  if (!next && !c) return GX_FX_PASSTHROUGH;
  if (!pcm || n <= 0 || n > kMaxFrames || rate <= 0) return GX_FX_PASSTHROUGH;

  // A new chain waits for the retired slot, so the audio thread never frees one.
  if (next && !fx->retired.load(std::memory_order_acquire)) {
    if (c && c->rate() == rate) {
      std::memcpy(c->dry(), pcm, sizeof(float) * n);
      c->process(pcm, n);
    }
    ramp(pcm, n, 1.f, 0.f);
    Chain *taken = fx->pending.exchange(nullptr, std::memory_order_acq_rel);
    fx->retired.store(c, std::memory_order_release);
    c = taken == noneToken() ? nullptr : taken;
    fx->chain = c;
    fx->fadeIn = true;
    fx->overRun = 0;
    fx->activePreset.store(c ? c->preset() : GX_FX_NONE, std::memory_order_relaxed);
    fx->activeRate.store(c ? c->rate() : 0, std::memory_order_relaxed);
    fx->activeLatency.store(c ? c->latencyMs() : 0, std::memory_order_relaxed);
    return GX_FX_OK;
  }
  if (!c) {
    if (fx->fadeIn) { ramp(pcm, n, 0.f, 1.f); fx->fadeIn = false; return GX_FX_OK; }
    return GX_FX_PASSTHROUGH;
  }
  if (fx->seenEpoch != fx->epoch.load(std::memory_order_acquire)) {
    fx->seenEpoch = fx->epoch.load(std::memory_order_relaxed);
    fx->overRun = 0;
  }
  if (c->rate() != rate) {
    if (fx->wantedRate.exchange(rate, std::memory_order_acq_rel) != rate) return GX_FX_NEED_REBUILD;
    return GX_FX_PASSTHROUGH;
  }
  if (fx->watchdog.load(std::memory_order_relaxed)) return GX_FX_PASSTHROUGH;

  auto t0 = std::chrono::steady_clock::now();
  float *dry = c->dry();
  std::memcpy(dry, pcm, sizeof(float) * n);
  c->process(pcm, n);  // keeps running in bypass, so the chain is primed when music stops

  float target = fx->bypass.load(std::memory_order_relaxed) ? 0.f : 1.f;
  float g = fx->wetGain, step = (target - g) / n;
  for (int i = 0; i < n; i++) { g += step; pcm[i] = pcm[i] * g + dry[i] * (1 - g); }
  fx->wetGain = target;
  if (fx->fadeIn) { ramp(pcm, n, 0.f, 1.f); fx->fadeIn = false; }

  auto us = (unsigned)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0).count();
  fx->frames.fetch_add(1, std::memory_order_relaxed);
  if (us > fx->maxUs.load(std::memory_order_relaxed)) fx->maxUs.store(us, std::memory_order_relaxed);
  int budget = fx->budgetUs.load(std::memory_order_relaxed);
  if (budget > 0 && (int)us > budget) {
    fx->over.fetch_add(1, std::memory_order_relaxed);
    int limit = fx->consecutive.load(std::memory_order_relaxed);
    if (limit > 0 && ++fx->overRun >= limit) {
      fx->watchdog.store(1, std::memory_order_relaxed);
      return GX_FX_WATCHDOG;
    }
  } else {
    fx->overRun = 0;
  }
  return GX_FX_OK;
}

int gx_fx_benchmark(int preset, int rate, int seconds, gx_fx_bench *o) {
  if (!o || preset < 0 || preset >= GX_FX_PRESET_COUNT || rate < 8000 || rate > 48000 || seconds <= 0 || seconds > 60) return -1;
  Chain chain(preset, rate);
  int n = rate / 100, blocks = seconds * 100;
  std::vector<float> x(n);
  std::vector<int> t;
  t.reserve(blocks);
  float phase = 0;
  for (int b = 0; b < blocks; b++) {
    float env = 0.15f + 0.1f * std::sin(b * 0.07f);
    for (int i = 0; i < n; i++) {
      phase += kTwoPi * 140.f / rate;
      if (phase > kTwoPi) phase -= kTwoPi;
      float s = 0;
      for (int h = 1; h <= 12; h++) s += std::sin(phase * h) / h;
      x[i] = s * env;
    }
    auto t0 = std::chrono::steady_clock::now();
    chain.process(x.data(), n);
    t.push_back((int)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0).count());
  }
  std::sort(t.begin(), t.end());
  o->blocks = blocks;
  o->p50_us = t[blocks / 2];
  o->p95_us = t[blocks * 95 / 100];
  o->max_us = t.back();
  o->latency_ms = chain.latencyMs();
  return 0;
}

}  // extern "C"

// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// On-device noise suppression: modes and options (plan 2026-10-15 §3).
// Same shape in the JS SDK (src/core/noise/options.ts).

import 'gravix_noise_policy.dart';
import 'gravix_noise_report.dart';

/// What the app asks for.
enum GravixNoiseSuppressionMode {
  /// No Gravix NS. WebRTC's own NS stays as configured today.
  off,

  /// RNNoise (bundled everywhere).
  standard,

  /// DeepFilterNet3 when its pack is available; RNNoise otherwise
  /// (reason `studio_unavailable`).
  studio,

  /// Default: RNNoise everywhere, DeepFilterNet3 on devices that pass the
  /// static check, the policy and the first-run benchmark.
  auto,
}

/// The engine actually producing the audio.
enum GravixNsEngine {
  /// No Gravix processing.
  none,

  /// RNNoise.
  rnnoise,

  /// DeepFilterNet3.
  dfn3,

  /// Web only: the browser's built-in `noiseSuppression` (no AudioWorklet/WASM).
  browser,
}

/// Where the small digital AGC sits relative to our NS.
enum GravixNsAgcOrder {
  /// AEC -> our NS -> our AGC + limiter; WebRTC software NS and AGC off
  /// (Agora/ZEGO style, plan option A).
  ownAfterNs,

  /// AEC -> WebRTC AGC -> our NS (plan option B).
  webrtcBeforeNs,

  /// AEC -> our NS, no AGC at all (neither ours nor WebRTC's). Agora ChatRoom
  /// runs without AGC; an AGC after the platform AEC lifts its echo residual
  /// (Xiaomi 2026-10-22: +10 dB on a gift sound). The default under
  /// [GravixAudioScenario.chatRoom].
  none,
}

/// THE default processing order (owner 2026-10-21: target = [GravixNsAgcOrder.ownAfterNs];
/// final value after the device loudness probe, +-2 dB). Flip it here; the JS
/// SDK (`GRAVIX_NS_DEFAULT_AGC_ORDER`) and the C core (`GX_NS_DEFAULT_AGC_ORDER`)
/// mirror it, and test/fixtures/ns_policy_cases.json pins all three.
const GravixNsAgcOrder kGravixNsDefaultAgcOrder = GravixNsAgcOrder.ownAfterNs;

/// Studio (DFN3) attenuation limit in dB (DeepFilterNet's `atten_lim`): noise is
/// attenuated by at most this much; 0 = no limit. 40 dB from the 2026-10-21 sweep
/// (speech level and PESQ unchanged vs no limit, pauses still >= 20 dB quieter).
/// The C core (`GX_NS_DEFAULT_ATTEN_LIM_DB`) and the JS SDK
/// (`GRAVIX_NS_DEFAULT_STUDIO_ATTEN_LIMIT_DB`) mirror it; the shared fixture pins all three.
const double kGravixNsDefaultStudioAttenLimitDb = 40;

/// Mid-call studio fallback: rolling p95 of the DFN3 frame time over
/// [kGravixNsDefaultStudioP95Window] above this budget -> RNNoise
/// (reason `studio_slow`). Mirrors `GX_NS_DEFAULT_EXT_P95_BUDGET_US` / `_WINDOW`.
const Duration kGravixNsDefaultStudioP95Budget = Duration(microseconds: 3000);
const Duration kGravixNsDefaultStudioP95Window = Duration(seconds: 2);

/// Android hardware (platform effect) noise suppressor.
enum GravixHwNs {
  /// Off while ours runs (default; avoids double processing).
  off,

  /// Leave the platform NS on as well.
  on,
}

/// When a Bluetooth headset reports its own NS/AEC.
enum GravixHeadsetNs {
  /// Keep ours on (default).
  keepOurs,

  /// Trust the headset: our NS goes to `none` on that route.
  preferHeadset,
}

/// When the studio (DeepFilterNet3) pack may be downloaded.
enum GravixStudioDownload {
  /// Never download; studio only if the pack is already present.
  never,

  /// On an unmetered network while idle (default).
  unmeteredIdle,

  /// Any network, on first need.
  any,
}

/// Where the studio pack comes from.
enum GravixStudioSource {
  /// Play asset pack on Play installs, the CDN otherwise, bundled on iOS/web.
  auto,

  /// Play Feature Delivery / asset pack only.
  playAssetPack,

  /// Our CDN only (never for Play installs).
  cdn,

  /// The app provides the files (its own asset base).
  app,
}

/// Options for on-device noise suppression. Style of GravixRecoveryOptions:
/// every field has a safe default. The SDK entry points use
/// `GravixNoiseSuppressionOptions()` (mode auto) by default; [off] (= [legacy])
/// opts out (WebRTC's own NS).
class GravixNoiseSuppressionOptions {
  const GravixNoiseSuppressionOptions({
    this.mode = GravixNoiseSuppressionMode.auto,
    this.disableWebRtcNs = true,
    this.hardwareNs = GravixHwNs.off,
    this.headsetNs = GravixHeadsetNs.keepOurs,
    this.agcOrder = kGravixNsDefaultAgcOrder,
    this.musicBypass = true,
    this.studioDownload = GravixStudioDownload.unmeteredIdle,
    this.studioSource = GravixStudioSource.auto,
    this.studioPackUrl,
    this.policyUrl,
    this.policy,
    this.benchmarkP95 = const Duration(microseconds: 3000),
    this.watchdogFrame = const Duration(milliseconds: 8),
    this.watchdogConsecutive = 3,
    this.thermalFallback = true,
    this.batterySaverFallback = true,
    this.studioAttenLimitDb = kGravixNsDefaultStudioAttenLimitDb,
    this.studioP95Budget = kGravixNsDefaultStudioP95Budget,
    this.studioP95Window = kGravixNsDefaultStudioP95Window,
    this.studioLowLatency = false,
    this.onReport,
  });

  /// Requested mode; `auto` by default.
  final GravixNoiseSuppressionMode mode;

  /// Turn WebRTC's software NS off while ours is active (avoids double NS).
  final bool disableWebRtcNs;

  /// Android platform noise suppressor while ours is active.
  final GravixHwNs hardwareNs;

  /// Bluetooth headset with its own NS.
  final GravixHeadsetNs headsetNs;

  /// AGC position; default [kGravixNsDefaultAgcOrder].
  final GravixNsAgcOrder agcOrder;

  /// Crossfade to dry while room music plays (RNNoise treats music as noise).
  final bool musicBypass;

  /// When the studio pack may be downloaded.
  final GravixStudioDownload studioDownload;

  /// Where the studio pack comes from.
  final GravixStudioSource studioSource;

  /// CDN folder holding the low-latency studio pack (`dfn3_ll_int8.ort`), for
  /// non-Play installs. Null = no CDN download (the standard studio model is
  /// bundled). The file is SHA-256 verified against the SDK's compiled-in hash.
  final String? studioPackUrl;

  /// Remote policy (`ns/v1/policy.json`); fetched at most daily, cached, never
  /// blocks a join. Null = the SDK default URL (set by the platform integration).
  final String? policyUrl;

  /// An app-injected policy; wins over [policyUrl].
  final GravixNsPolicy? policy;

  /// Studio only if the first-run benchmark p95 frame time is below this.
  final Duration benchmarkP95;

  /// Watchdog: a frame longer than this counts as over budget ...
  final Duration watchdogFrame;

  /// ... and this many in a row fall back to RNNoise mid-call.
  final int watchdogConsecutive;

  /// Fall back to RNNoise on thermal throttling (Android >= MODERATE, iOS >= serious).
  final bool thermalFallback;

  /// Fall back to RNNoise in battery saver / Low Power Mode.
  final bool batterySaverFallback;

  /// Studio attenuation limit (dB); 0 = no limit. See [kGravixNsDefaultStudioAttenLimitDb].
  final double studioAttenLimitDb;

  /// Mid-call studio fallback: the rolling p95 DFN3 frame time over
  /// [studioP95Window] above this switches to RNNoise (reason `studio_slow`,
  /// logged). Zero disables it.
  final Duration studioP95Budget;

  /// Window of the rolling p95 (10 ms frames; 2 s by default).
  final Duration studioP95Window;

  /// Allow the downloaded low-latency (LL) studio model. Off by default: LL
  /// over-suppresses speech in babble (2026-10-21 sweep, an attenuation limit
  /// does not fix it), so studio uses the bundled standard model unless the app
  /// opts in. When on, LL is picked if its pack is present and its benchmark
  /// p95 is under [benchmarkP95].
  final bool studioLowLatency;

  /// Telemetry callback (engine changes, benchmark, summary).
  final void Function(GravixNsReport report)? onReport;

  /// No Gravix NS: WebRTC's own noise suppression (the sound before
  /// 2026-10-21). Same as [off].
  static const legacy = GravixNoiseSuppressionOptions(mode: GravixNoiseSuppressionMode.off);

  /// Noise suppression off, for apps that opt out of the default (which is on,
  /// mode auto): `RoomOptions(noiseSuppression: GravixNoiseSuppressionOptions.off)`.
  static const off = legacy;

  GravixNoiseSuppressionOptions copyWith({
    GravixNoiseSuppressionMode? mode,
    bool? disableWebRtcNs,
    GravixHwNs? hardwareNs,
    GravixHeadsetNs? headsetNs,
    GravixNsAgcOrder? agcOrder,
    bool? musicBypass,
    GravixStudioDownload? studioDownload,
    GravixStudioSource? studioSource,
    String? studioPackUrl,
    String? policyUrl,
    GravixNsPolicy? policy,
    Duration? benchmarkP95,
    Duration? watchdogFrame,
    int? watchdogConsecutive,
    bool? thermalFallback,
    bool? batterySaverFallback,
    double? studioAttenLimitDb,
    Duration? studioP95Budget,
    Duration? studioP95Window,
    bool? studioLowLatency,
    void Function(GravixNsReport report)? onReport,
  }) => GravixNoiseSuppressionOptions(
    mode: mode ?? this.mode,
    disableWebRtcNs: disableWebRtcNs ?? this.disableWebRtcNs,
    hardwareNs: hardwareNs ?? this.hardwareNs,
    headsetNs: headsetNs ?? this.headsetNs,
    agcOrder: agcOrder ?? this.agcOrder,
    musicBypass: musicBypass ?? this.musicBypass,
    studioDownload: studioDownload ?? this.studioDownload,
    studioSource: studioSource ?? this.studioSource,
    studioPackUrl: studioPackUrl ?? this.studioPackUrl,
    policyUrl: policyUrl ?? this.policyUrl,
    policy: policy ?? this.policy,
    benchmarkP95: benchmarkP95 ?? this.benchmarkP95,
    watchdogFrame: watchdogFrame ?? this.watchdogFrame,
    watchdogConsecutive: watchdogConsecutive ?? this.watchdogConsecutive,
    thermalFallback: thermalFallback ?? this.thermalFallback,
    batterySaverFallback: batterySaverFallback ?? this.batterySaverFallback,
    studioAttenLimitDb: studioAttenLimitDb ?? this.studioAttenLimitDb,
    studioP95Budget: studioP95Budget ?? this.studioP95Budget,
    studioP95Window: studioP95Window ?? this.studioP95Window,
    studioLowLatency: studioLowLatency ?? this.studioLowLatency,
    onReport: onReport ?? this.onReport,
  );
}

/// Wire names shared with the JS SDK and the logs.
String gravixNsModeName(GravixNoiseSuppressionMode m) => m.name;

GravixNoiseSuppressionMode? gravixNsModeFromName(String? s) {
  for (final m in GravixNoiseSuppressionMode.values) {
    if (m.name == s) return m;
  }
  return null;
}

/// `off` | `rnnoise` | `dfn3` | `browser` (the `eng=` log field).
String gravixNsEngineName(GravixNsEngine e) => e == GravixNsEngine.none ? 'off' : e.name;

GravixNsEngine? gravixNsEngineFromName(String? s) {
  if (s == 'off' || s == 'none') return GravixNsEngine.none;
  for (final e in GravixNsEngine.values) {
    if (e.name == s) return e;
  }
  return null;
}

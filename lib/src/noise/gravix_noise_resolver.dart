// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// Engine resolver (plan §4): static device facts + policy + benchmark cache ->
// engine + reason. Pure; the platform integrations gather the facts. The JS SDK
// (src/core/noise/resolver.ts) resolves test/fixtures/ns_policy_cases.json to
// the same results.

import 'gravix_noise_options.dart';
import 'gravix_noise_policy.dart';

/// Static facts about the device / browser. Unknown = null.
class GravixNsDeviceFacts {
  const GravixNsDeviceFacts({
    required this.platform,
    this.model,
    this.manufacturer,
    this.soc,
    this.osVersion,
    this.abi,
    this.ramMb,
    this.isLowRamDevice,
    this.mediaPerformanceClass,
    this.cpuMaxFreqMhz,
    this.hardwareConcurrency,
    this.deviceMemoryGb,
    this.wasmSimd,
    this.audioWorklet,
    this.userAgent,
    this.narrowbandRoute = false,
  });

  /// android | ios | web | other
  final String platform;

  /// Android Build.MODEL; iOS machine id (`iPhone14,2`); web: null.
  final String? model;
  final String? manufacturer;

  /// Android Build.SOC_MODEL (API 31+).
  final String? soc;
  final String? osVersion;

  /// Android first supported ABI (`arm64-v8a`).
  final String? abi;
  final int? ramMb;
  final bool? isLowRamDevice;

  /// Android Build.VERSION.MEDIA_PERFORMANCE_CLASS (0 = none).
  final int? mediaPerformanceClass;

  /// Fastest core's cpuinfo_max_freq.
  final int? cpuMaxFreqMhz;

  /// Web navigator.hardwareConcurrency.
  final int? hardwareConcurrency;

  /// Web navigator.deviceMemory (absent in Safari/Firefox).
  final double? deviceMemoryGb;
  final bool? wasmSimd;
  final bool? audioWorklet;
  final String? userAgent;

  /// Current route is narrowband (Bluetooth SCO / HFP): auto stays on RNNoise.
  final bool narrowbandRoute;

  static GravixNsDeviceFacts fromJson(Map<String, dynamic> j) => GravixNsDeviceFacts(
    platform: (j['platform'] as String?) ?? 'other',
    model: j['model'] as String?,
    manufacturer: j['manufacturer'] as String?,
    soc: j['soc'] as String?,
    osVersion: j['osVersion'] as String?,
    abi: j['abi'] as String?,
    ramMb: (j['ramMb'] as num?)?.toInt(),
    isLowRamDevice: j['isLowRamDevice'] as bool?,
    mediaPerformanceClass: (j['mediaPerformanceClass'] as num?)?.toInt(),
    cpuMaxFreqMhz: (j['cpuMaxFreqMhz'] as num?)?.toInt(),
    hardwareConcurrency: (j['hardwareConcurrency'] as num?)?.toInt(),
    deviceMemoryGb: (j['deviceMemoryGb'] as num?)?.toDouble(),
    wasmSimd: j['wasmSimd'] as bool?,
    audioWorklet: j['audioWorklet'] as bool?,
    userAgent: j['userAgent'] as String?,
    narrowbandRoute: j['narrowbandRoute'] == true,
  );

  bool _matches(GravixNsRule r) => r.matches(
    platform: platform,
    model: model,
    manufacturer: manufacturer,
    soc: soc,
    userAgent: userAgent,
    osVersion: osVersion,
  );
}

/// A cached first-run benchmark of the studio engine on this device.
class GravixNsBenchmark {
  const GravixNsBenchmark({required this.key, required this.p95Us, this.outputOk = true});

  /// [gravixNsBenchmarkKey] at the time of the run; a different key = stale.
  final String key;
  final int p95Us;

  /// The output RMS bound check passed (a corrupt model fails it).
  final bool outputOk;

  static GravixNsBenchmark fromJson(Map<String, dynamic> j) => GravixNsBenchmark(
    key: j['key'] as String,
    p95Us: (j['p95Us'] as num).toInt(),
    outputOk: j['outputOk'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {'key': key, 'p95Us': p95Us, 'outputOk': outputOk};
}

/// Benchmark cache key: re-run after an SDK, model, runtime or OS/build change.
/// Field order and separators are part of the contract with the JS SDK.
String gravixNsBenchmarkKey({
  required String sdkVersion,
  required String modelSha256,
  required String runtimeVersion,
  required String osBuild,
}) {
  String esc(String s) => s.replaceAll('%', '%25').replaceAll('|', '%7C');
  final sha = modelSha256.toLowerCase();
  return 'ns-bench/v1|sdk=${esc(sdkVersion)}|model=${esc(sha.length > 16 ? sha.substring(0, 16) : sha)}'
      '|rt=${esc(runtimeVersion)}|os=${esc(osBuild)}';
}

/// iOS machine id -> A-chip generation (`iPhone11,2` -> 12 = A12). Null when unknown
/// (simulator, Mac, unknown family).
int? gravixIosChipFromModel(String? model) {
  if (model == null) return null;
  final m = RegExp(r'^(iPhone|iPad|iPod)(\d+),\d+$').firstMatch(model);
  if (m == null) return null;
  final n = int.parse(m.group(2)!);
  switch (m.group(1)) {
    case 'iPhone':
      return n + 1; // iPhone11,x = A12 ... iPhone17,x = A18
    case 'iPad':
      // iPad8 = A12X, iPad11 = A12, iPad12 = A13, iPad13 = A14/M1, iPad14 = A15/M2 ...
      if (n >= 8) return 12 + (n >= 11 ? n - 11 : 0);
      return n + 3; // iPad7 = A10 class
    default:
      return n >= 9 ? 10 : 8; // iPod9,1 = A10
  }
}

/// Why the resolver picked the engine. Wire names are shared with JS and logs.
class GravixNsReason {
  static const modeOff = 'mode_off';
  static const killSwitch = 'kill_switch';
  static const killSwitchStudio = 'kill_switch_studio';
  static const policyDenyStandard = 'policy_deny_standard';
  static const policyDenyStudio = 'policy_deny_studio';
  static const noAudioWorklet = 'no_audio_worklet';
  static const modeStandard = 'mode_standard';
  static const modeStudio = 'mode_studio';
  static const studioUnavailable = 'studio_unavailable';
  static const narrowbandRoute = 'narrowband_route';
  static const staticAbi = 'static_abi';
  static const staticLowRam = 'static_low_ram';
  static const staticLowRamDevice = 'static_low_ram_device';
  static const staticSlowCpu = 'static_slow_cpu';
  static const staticOldChip = 'static_old_chip';
  static const staticFewCores = 'static_few_cores';
  static const staticLowMemory = 'static_low_memory';
  static const staticNoSimd = 'static_no_simd';
  static const staticPlatform = 'static_platform';
  static const benchmarkPending = 'benchmark_pending';
  static const benchmarkSlow = 'benchmark_slow';
  static const benchmarkBadOutput = 'benchmark_bad_output';

  /// Explicit studio, but the (cached) benchmark p95 is over the budget.
  static const studioTooSlow = 'studio_too_slow';

  /// Mid-call: the studio engine's rolling p95 frame time went over
  /// [GravixNoiseSuppressionOptions.studioP95Budget] (thermal) -> RNNoise.
  static const studioSlow = 'studio_slow';

  /// Mid-call: the studio engine's output speech collapsed vs its input for
  /// 2 s of speech (gx_ns live guard, e.g. a model erasing quiet speech) -> RNNoise.
  static const studioSuppress = 'studio_suppress';

  /// No native processor on this platform yet (iOS / web are later phases).
  static const platformUnsupported = 'platform_unsupported';

  /// The native processor could not be installed (library missing, old plugin).
  static const nativeUnavailable = 'native_unavailable';
  static const autoCapable = 'auto_capable';
}

/// The resolver's answer.
class GravixNsResolution {
  const GravixNsResolution({
    required this.engine,
    required this.reason,
    this.needsBenchmark = false,
    this.studioEligible = false,
  });

  final GravixNsEngine engine;
  final String reason;

  /// auto: run (or re-run) the studio benchmark in the background; RNNoise meanwhile.
  final bool needsBenchmark;

  /// Static check + policy passed (benchmark aside).
  final bool studioEligible;

  Map<String, dynamic> toJson() => {
    'engine': gravixNsEngineName(engine),
    'reason': reason,
    'needsBenchmark': needsBenchmark,
    'studioEligible': studioEligible,
  };

  @override
  String toString() => 'GravixNsResolution(${toJson()})';
}

/// Static capability for studio; null = capable, else a [GravixNsReason].
String? gravixNsStaticCheck(GravixNsDeviceFacts f, GravixNsThresholds t) {
  switch (f.platform) {
    case 'android':
      if (f.abi != null && f.abi != 'arm64-v8a') return GravixNsReason.staticAbi;
      if ((f.mediaPerformanceClass ?? 0) >= t.minPerformanceClass!) return null;
      if (f.isLowRamDevice == true) return GravixNsReason.staticLowRamDevice;
      if (f.ramMb != null && f.ramMb! < t.minRamMb!) return GravixNsReason.staticLowRam;
      if (f.cpuMaxFreqMhz != null && f.cpuMaxFreqMhz! < t.minCpuMaxFreqMhz!) return GravixNsReason.staticSlowCpu;
      return null;
    case 'ios':
      final chip = gravixIosChipFromModel(f.model);
      if (chip != null && chip < t.minIosChip!) return GravixNsReason.staticOldChip;
      return null;
    case 'web':
      if (f.wasmSimd == false) return GravixNsReason.staticNoSimd;
      if (f.hardwareConcurrency != null && f.hardwareConcurrency! < t.minCores!) return GravixNsReason.staticFewCores;
      if (f.deviceMemoryGb != null && f.deviceMemoryGb! < t.minDeviceMemoryGb!) return GravixNsReason.staticLowMemory;
      return null;
    default:
      return GravixNsReason.staticPlatform;
  }
}

/// Resolves the engine. Order (first hit wins): mode off, kill switch, web
/// without AudioWorklet, standard deny, mode standard; then for studio/auto:
/// studio kill switch, studio deny, (studio) pack unavailable, benchmark
/// missing/stale, bad output, slow (studio_too_slow) -> mode_studio;
/// (auto) static check unless allow-listed, narrowband route, pack unavailable,
/// benchmark missing/stale, slow, bad output -> auto_capable.
GravixNsResolution gravixResolveNs({
  required GravixNoiseSuppressionMode mode,
  required GravixNsDeviceFacts facts,
  GravixNsPolicy? policy,
  GravixNsBenchmark? benchmark,
  String? benchmarkKey,
  bool studioAvailable = false,
  Duration benchmarkP95 = const Duration(microseconds: 3000),
}) {
  final p = policy ?? GravixNsPolicy.empty;
  final t = GravixNsThresholds.defaults
      .merge(GravixNsThresholds(benchmarkP95Us: benchmarkP95.inMicroseconds))
      .merge(p.thresholds);
  final web = facts.platform == 'web';
  final fallback = web ? GravixNsEngine.browser : GravixNsEngine.none;

  if (mode == GravixNoiseSuppressionMode.off) {
    return const GravixNsResolution(engine: GravixNsEngine.none, reason: GravixNsReason.modeOff);
  }
  if (p.killAll) return GravixNsResolution(engine: fallback, reason: GravixNsReason.killSwitch);
  if (web && facts.audioWorklet == false) {
    return const GravixNsResolution(engine: GravixNsEngine.browser, reason: GravixNsReason.noAudioWorklet);
  }
  if (p.standardDeny.any(facts._matches)) {
    return GravixNsResolution(engine: fallback, reason: GravixNsReason.policyDenyStandard);
  }
  if (mode == GravixNoiseSuppressionMode.standard) {
    return const GravixNsResolution(engine: GravixNsEngine.rnnoise, reason: GravixNsReason.modeStandard);
  }
  if (p.killStudio) {
    return const GravixNsResolution(engine: GravixNsEngine.rnnoise, reason: GravixNsReason.killSwitchStudio);
  }
  if (p.studioDeny.any(facts._matches)) {
    return const GravixNsResolution(engine: GravixNsEngine.rnnoise, reason: GravixNsReason.policyDenyStudio);
  }
  if (mode == GravixNoiseSuppressionMode.studio) {
    // An explicit request skips the static check (and the narrowband rule) but
    // still needs the cached benchmark (owner 2026-10-21); the watchdog guards it live.
    if (!studioAvailable) {
      return const GravixNsResolution(engine: GravixNsEngine.rnnoise, reason: GravixNsReason.studioUnavailable);
    }
    return _byBenchmark(benchmark, benchmarkKey, t, GravixNsReason.modeStudio, GravixNsReason.studioTooSlow);
  }
  // auto
  final allowListed = p.studioAllow.any(facts._matches);
  final staticFail = allowListed ? null : gravixNsStaticCheck(facts, t);
  if (staticFail != null) return GravixNsResolution(engine: GravixNsEngine.rnnoise, reason: staticFail);
  if (facts.narrowbandRoute) {
    return const GravixNsResolution(
      engine: GravixNsEngine.rnnoise,
      reason: GravixNsReason.narrowbandRoute,
      studioEligible: true,
    );
  }
  if (!studioAvailable) {
    return const GravixNsResolution(
      engine: GravixNsEngine.rnnoise,
      reason: GravixNsReason.studioUnavailable,
      studioEligible: true,
    );
  }
  return _byBenchmark(benchmark, benchmarkKey, t, GravixNsReason.autoCapable, GravixNsReason.benchmarkSlow);
}

GravixNsResolution _byBenchmark(
  GravixNsBenchmark? benchmark,
  String? benchmarkKey,
  GravixNsThresholds t,
  String okReason,
  String slowReason,
) {
  if (benchmark == null || (benchmarkKey != null && benchmark.key != benchmarkKey)) {
    return const GravixNsResolution(
      engine: GravixNsEngine.rnnoise,
      reason: GravixNsReason.benchmarkPending,
      needsBenchmark: true,
      studioEligible: true,
    );
  }
  if (!benchmark.outputOk) {
    return const GravixNsResolution(
      engine: GravixNsEngine.rnnoise,
      reason: GravixNsReason.benchmarkBadOutput,
      studioEligible: true,
    );
  }
  if (benchmark.p95Us >= t.benchmarkP95Us!) {
    return GravixNsResolution(engine: GravixNsEngine.rnnoise, reason: slowReason, studioEligible: true);
  }
  return GravixNsResolution(engine: GravixNsEngine.dfn3, reason: okReason, studioEligible: true);
}

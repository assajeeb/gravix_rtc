// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// `[GravixNS]` log lines and the telemetry report (plan §3). Format, shared with
// the JS SDK (src/core/noise/log.ts):
//   [GravixNS] <step> eng=<off|rnnoise|dfn3|browser> route=<route> rate=<apmHz|?> [+<ms>ms] [detail]

import 'gravix_noise_options.dart';

/// Log steps.
class GravixNsStep {
  static const install = 'install';
  static const init = 'init';
  static const policy = 'policy';
  static const static_ = 'static';
  static const bench = 'bench';
  static const pack = 'pack';
  static const switch_ = 'switch';
  static const routeReset = 'routeReset';
  static const musicBypass = 'musicBypass';
  static const summary = 'summary';
}

/// Audio route as it appears in logs / telemetry.
enum GravixNsRoute { speaker, earpiece, wired, btSco, btA2dp, btLe, usb, unknown }

String gravixNsRouteName(GravixNsRoute r) => switch (r) {
  GravixNsRoute.btSco => 'bt-sco',
  GravixNsRoute.btA2dp => 'bt-a2dp',
  GravixNsRoute.btLe => 'bt-le',
  _ => r.name,
};

GravixNsRoute gravixNsRouteFromName(String? s) {
  for (final r in GravixNsRoute.values) {
    if (gravixNsRouteName(r) == s) return r;
  }
  return GravixNsRoute.unknown;
}

/// One `[GravixNS]` line. [elapsed] is printed as `+<ms>ms` (whole ms); [detail]
/// is appended as-is (keep it `key=value` pairs, no secrets).
String gravixNsLogLine(
  String step, {
  required GravixNsEngine engine,
  GravixNsRoute route = GravixNsRoute.unknown,
  int? rate,
  Duration? elapsed,
  String? detail,
}) {
  final b = StringBuffer('[GravixNS] ')
    ..write(step)
    ..write(' eng=')
    ..write(gravixNsEngineName(engine))
    ..write(' route=')
    ..write(gravixNsRouteName(route))
    ..write(' rate=')
    ..write(rate == null || rate <= 0 ? '?' : '$rate');
  if (elapsed != null) b.write(' +${elapsed.inMilliseconds}ms');
  if (detail != null && detail.isNotEmpty) b.write(' $detail');
  return b.toString();
}

/// `switch` detail: `from=<eng> to=<eng> reason=<reason>`.
String gravixNsSwitchDetail(GravixNsEngine from, GravixNsEngine to, String reason) =>
    'from=${gravixNsEngineName(from)} to=${gravixNsEngineName(to)} reason=$reason';

/// `summary` detail: `p50=.. p95=.. p99=.. max=.. over=.. [cpu=..]` (frame times in us).
String gravixNsSummaryDetail({
  required int p50Us,
  required int p95Us,
  required int p99Us,
  required int maxUs,
  required int overBudget,
  double? cpuPercent,
}) {
  final s = 'p50=$p50Us p95=$p95Us p99=$p99Us max=$maxUs over=$overBudget';
  return cpuPercent == null ? s : '$s cpu=${cpuPercent.toStringAsFixed(1)}';
}

/// Telemetry handed to `GravixNoiseSuppressionOptions.onReport` (later uploaded
/// as `kind:"ns"`). Fields are optional: each report carries what its step knows.
class GravixNsReport {
  const GravixNsReport({
    required this.step,
    required this.mode,
    required this.engine,
    required this.reason,
    this.platform,
    this.osVersion,
    this.model,
    this.browser,
    this.performanceClass,
    this.route = GravixNsRoute.unknown,
    this.inputRate,
    this.apmRate,
    this.p50Us,
    this.p95Us,
    this.p99Us,
    this.maxUs,
    this.framesOverBudget,
    this.fallbacks,
    this.benchmarkP95Us,
    this.benchmarkCached,
    this.packSource,
    this.packBytes,
    this.packMs,
    this.headsetNs,
    this.musicBypassMs,
    this.cpuPercent,
  });

  final String step;
  final GravixNoiseSuppressionMode mode;
  final GravixNsEngine engine;
  final String reason;
  final String? platform;
  final String? osVersion;
  final String? model;
  final String? browser;
  final int? performanceClass;
  final GravixNsRoute route;
  final int? inputRate;
  final int? apmRate;
  final int? p50Us;
  final int? p95Us;
  final int? p99Us;
  final int? maxUs;
  final int? framesOverBudget;
  final int? fallbacks;
  final int? benchmarkP95Us;
  final bool? benchmarkCached;
  final String? packSource;
  final int? packBytes;
  final int? packMs;
  final bool? headsetNs;
  final int? musicBypassMs;
  final double? cpuPercent;

  Map<String, dynamic> toJson() => {
    'step': step,
    'mode': gravixNsModeName(mode),
    'engine': gravixNsEngineName(engine),
    'reason': reason,
    'route': gravixNsRouteName(route),
    if (platform != null) 'platform': platform,
    if (osVersion != null) 'osVersion': osVersion,
    if (model != null) 'model': model,
    if (browser != null) 'browser': browser,
    if (performanceClass != null) 'performanceClass': performanceClass,
    if (inputRate != null) 'inputRate': inputRate,
    if (apmRate != null) 'apmRate': apmRate,
    if (p50Us != null) 'p50Us': p50Us,
    if (p95Us != null) 'p95Us': p95Us,
    if (p99Us != null) 'p99Us': p99Us,
    if (maxUs != null) 'maxUs': maxUs,
    if (framesOverBudget != null) 'framesOverBudget': framesOverBudget,
    if (fallbacks != null) 'fallbacks': fallbacks,
    if (benchmarkP95Us != null) 'benchmarkP95Us': benchmarkP95Us,
    if (benchmarkCached != null) 'benchmarkCached': benchmarkCached,
    if (packSource != null) 'packSource': packSource,
    if (packBytes != null) 'packBytes': packBytes,
    if (packMs != null) 'packMs': packMs,
    if (headsetNs != null) 'headsetNs': headsetNs,
    if (musicBypassMs != null) 'musicBypassMs': musicBypassMs,
    if (cpuPercent != null) 'cpuPercent': cpuPercent,
  };
}

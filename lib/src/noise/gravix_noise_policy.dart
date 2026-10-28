// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// Remote NS policy (`ns/v1/policy.json`, plan §3): kill switches, studio
// allow/deny and standard deny lists, thresholds. The parser never throws: a
// malformed document yields `policy == null` + an error, a malformed rule or
// threshold is skipped. Same rules in the JS SDK (src/core/noise/policy.ts).

import 'dart:convert';

/// Thresholds for the static check and the benchmark. Null field = default.
class GravixNsThresholds {
  const GravixNsThresholds({
    this.benchmarkP95Us,
    this.minRamMb,
    this.minCpuMaxFreqMhz,
    this.minPerformanceClass,
    this.minIosChip,
    this.minCores,
    this.minDeviceMemoryGb,
  });

  final int? benchmarkP95Us;
  final int? minRamMb;
  final int? minCpuMaxFreqMhz;
  final int? minPerformanceClass;
  final int? minIosChip;
  final int? minCores;
  final double? minDeviceMemoryGb;

  static const defaults = GravixNsThresholds(
    benchmarkP95Us: 3000,
    minRamMb: 4096,
    minCpuMaxFreqMhz: 2000,
    minPerformanceClass: 31,
    minIosChip: 12,
    minCores: 4,
    minDeviceMemoryGb: 4,
  );

  /// Fields of [over] win.
  GravixNsThresholds merge(GravixNsThresholds? over) => over == null
      ? this
      : GravixNsThresholds(
          benchmarkP95Us: over.benchmarkP95Us ?? benchmarkP95Us,
          minRamMb: over.minRamMb ?? minRamMb,
          minCpuMaxFreqMhz: over.minCpuMaxFreqMhz ?? minCpuMaxFreqMhz,
          minPerformanceClass: over.minPerformanceClass ?? minPerformanceClass,
          minIosChip: over.minIosChip ?? minIosChip,
          minCores: over.minCores ?? minCores,
          minDeviceMemoryGb: over.minDeviceMemoryGb ?? minDeviceMemoryGb,
        );

  static GravixNsThresholds fromJson(Map<String, dynamic> j) => GravixNsThresholds(
    benchmarkP95Us: _int(j['benchmarkP95Us']),
    minRamMb: _int(j['minRamMb']),
    minCpuMaxFreqMhz: _int(j['minCpuMaxFreqMhz']),
    minPerformanceClass: _int(j['minPerformanceClass']),
    minIosChip: _int(j['minIosChip']),
    minCores: _int(j['minCores']),
    minDeviceMemoryGb: _num(j['minDeviceMemoryGb'])?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    if (benchmarkP95Us != null) 'benchmarkP95Us': benchmarkP95Us,
    if (minRamMb != null) 'minRamMb': minRamMb,
    if (minCpuMaxFreqMhz != null) 'minCpuMaxFreqMhz': minCpuMaxFreqMhz,
    if (minPerformanceClass != null) 'minPerformanceClass': minPerformanceClass,
    if (minIosChip != null) 'minIosChip': minIosChip,
    if (minCores != null) 'minCores': minCores,
    if (minDeviceMemoryGb != null) 'minDeviceMemoryGb': minDeviceMemoryGb,
  };
}

/// One allow/deny rule. Every field that is set must match.
/// - `platform`: android | ios | web | * (required)
/// - `model`, `manufacturer`, `soc`: case-insensitive; a trailing `*` = prefix
/// - `uaRegex`: regular expression on the user agent (web)
/// - `osMin` / `osMax`: inclusive dotted versions (`"12"`, `"17.4"`)
class GravixNsRule {
  const GravixNsRule({required this.platform, this.model, this.manufacturer, this.soc, this.uaRegex, this.osMin, this.osMax});

  final String platform;
  final String? model;
  final String? manufacturer;
  final String? soc;
  final String? uaRegex;
  final String? osMin;
  final String? osMax;

  /// Null when the rule is malformed (no platform, bad regex, bad version).
  static GravixNsRule? fromJson(Object? o) {
    if (o is! Map) return null;
    final p = o['platform'];
    if (p is! String || p.isEmpty) return null;
    final ua = _str(o['uaRegex']);
    if (ua != null) {
      try {
        RegExp(ua);
      } on FormatException {
        return null;
      }
    }
    final osMin = _str(o['osMin']), osMax = _str(o['osMax']);
    if ((osMin != null && _version(osMin) == null) || (osMax != null && _version(osMax) == null)) return null;
    return GravixNsRule(
      platform: p.toLowerCase(),
      model: _str(o['model']),
      manufacturer: _str(o['manufacturer']),
      soc: _str(o['soc']),
      uaRegex: ua,
      osMin: osMin,
      osMax: osMax,
    );
  }

  Map<String, dynamic> toJson() => {
    'platform': platform,
    if (model != null) 'model': model,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (soc != null) 'soc': soc,
    if (uaRegex != null) 'uaRegex': uaRegex,
    if (osMin != null) 'osMin': osMin,
    if (osMax != null) 'osMax': osMax,
  };

  /// Whether the device described by these fields matches.
  bool matches({
    required String platform,
    String? model,
    String? manufacturer,
    String? soc,
    String? userAgent,
    String? osVersion,
  }) {
    if (this.platform != '*' && this.platform != platform.toLowerCase()) return false;
    if (this.model != null && !_glob(this.model!, model)) return false;
    if (this.manufacturer != null && !_glob(this.manufacturer!, manufacturer)) return false;
    if (this.soc != null && !_glob(this.soc!, soc)) return false;
    if (uaRegex != null && (userAgent == null || !RegExp(uaRegex!).hasMatch(userAgent))) return false;
    if (osMin != null || osMax != null) {
      final v = osVersion == null ? null : _version(osVersion);
      if (v == null) return false;
      if (osMin != null && _cmp(v, _version(osMin!)!) < 0) return false;
      if (osMax != null && _cmp(v, _version(osMax!)!) > 0) return false;
    }
    return true;
  }
}

/// The parsed policy.
class GravixNsPolicy {
  const GravixNsPolicy({
    this.version = 1,
    this.killAll = false,
    this.killStudio = false,
    this.studioAllow = const [],
    this.studioDeny = const [],
    this.standardDeny = const [],
    this.thresholds,
  });

  final int version;

  /// Everything off (remote kill switch).
  final bool killAll;

  /// Studio off; standard stays.
  final bool killStudio;

  /// Devices that skip the static check for studio (benchmark still runs).
  final List<GravixNsRule> studioAllow;

  /// Devices that never get studio.
  final List<GravixNsRule> studioDeny;

  /// Devices that get no Gravix NS at all (web: the browser's NS).
  final List<GravixNsRule> standardDeny;

  final GravixNsThresholds? thresholds;

  static const empty = GravixNsPolicy();

  Map<String, dynamic> toJson() => {
    'version': version,
    'killSwitch': {'all': killAll, 'studio': killStudio},
    'studio': {
      'allow': [for (final r in studioAllow) r.toJson()],
      'deny': [for (final r in studioDeny) r.toJson()],
    },
    'standard': {
      'deny': [for (final r in standardDeny) r.toJson()],
    },
    if (thresholds != null) 'thresholds': thresholds!.toJson(),
  };
}

/// Result of [gravixParseNsPolicy]: exactly one of [policy] / [error] is set.
class GravixNsPolicyParse {
  const GravixNsPolicyParse._(this.policy, this.error, this.skippedRules);
  final GravixNsPolicy? policy;
  final String? error;

  /// Malformed rules that were dropped.
  final int skippedRules;
}

/// Supported policy schema version.
const int kGravixNsPolicyVersion = 1;

/// Parses a policy document (a JSON string or an already decoded map).
GravixNsPolicyParse gravixParseNsPolicy(Object? source) {
  Object? root = source;
  if (source is String) {
    try {
      root = json.decode(source);
    } on FormatException catch (e) {
      return GravixNsPolicyParse._(null, 'bad_json: ${e.message}', 0);
    }
  }
  if (root is! Map) return const GravixNsPolicyParse._(null, 'not_an_object', 0);
  final version = _int(root['version']) ?? 1;
  if (version > kGravixNsPolicyVersion) {
    return GravixNsPolicyParse._(null, 'unsupported_version: $version', 0);
  }
  var skipped = 0;
  List<GravixNsRule> rules(Object? list) {
    if (list is! List) return const [];
    final out = <GravixNsRule>[];
    for (final o in list) {
      final r = GravixNsRule.fromJson(o);
      if (r == null) {
        skipped++;
      } else {
        out.add(r);
      }
    }
    return out;
  }

  final kill = root['killSwitch'] is Map ? root['killSwitch'] as Map : const {};
  final studio = root['studio'] is Map ? root['studio'] as Map : const {};
  final standard = root['standard'] is Map ? root['standard'] as Map : const {};
  final th = root['thresholds'] is Map ? GravixNsThresholds.fromJson(Map<String, dynamic>.from(root['thresholds'] as Map)) : null;
  final policy = GravixNsPolicy(
    version: version,
    killAll: kill['all'] == true,
    killStudio: kill['studio'] == true,
    studioAllow: rules(studio['allow']),
    studioDeny: rules(studio['deny']),
    standardDeny: rules(standard['deny']),
    thresholds: th,
  );
  return GravixNsPolicyParse._(policy, null, skipped);
}

String? _str(Object? o) => o is String && o.isNotEmpty ? o : null;
num? _num(Object? o) => o is num && o.isFinite ? o : null;
int? _int(Object? o) => o is int ? o : (o is double && o.isFinite && o == o.roundToDouble() ? o.toInt() : null);

bool _glob(String pattern, String? value) {
  if (value == null) return false;
  final p = pattern.toLowerCase(), v = value.toLowerCase();
  if (p.endsWith('*')) return v.startsWith(p.substring(0, p.length - 1));
  return p == v;
}

/// `"17.4.1"` -> [17, 4, 1]; null when not a dotted number.
List<int>? _version(String s) {
  final parts = s.trim().split('.');
  final out = <int>[];
  for (final p in parts) {
    final v = int.tryParse(p);
    if (v == null || v < 0) return null;
    out.add(v);
  }
  return out.isEmpty ? null : out;
}

int _cmp(List<int> a, List<int> b) {
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Exposed for the resolver and tests: dotted version compare (-1/0/1), null if unparsable.
int? gravixNsCompareVersions(String a, String b) {
  final x = _version(a), y = _version(b);
  if (x == null || y == null) return null;
  return _cmp(x, y);
}

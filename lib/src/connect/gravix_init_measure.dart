// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.
//
// Region choice at start-up, like Agora (parity with the React SDK's
// src/core/room/region/initMeasure.ts, 0.4.0 + 0.5.0; 2026-09-27).
//
// The app calls [gravixStartRegionMeasurement] once when it starts -- before any
// room or token exists. Each region is measured one after another (concurrent
// probes bias each other at 3+ regions): [kGravixMeasureSamples] requests, the
// FIRST dropped (it pays DNS + TCP + TLS), the minimum of the rest kept. A region
// stops at its first failure. The answer lives [kGravixRegionMeasurementTtl] and is
// re-measured periodically and when the network changes.
//
// `connect()` then goes straight to the measured region: a lookup, nothing sent,
// nothing awaited. With a token minted by the app's own backend (Gravix token
// libraries) there is usually no region list: the measured regions are the list
// then, as long as the connect url is one of them.
import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rtc_core/src/support/http_client.dart';
import 'gravix_region_cache.dart';
import 'gravix_region_prober.dart';
import 'gravix_region_report.dart';

const kGravixMeasureSamples = 4;
const kGravixRegionMeasurementTtl = Duration(minutes: 10);
const kGravixRegionMeasurementRefresh = Duration(minutes: 5);
const kGravixMeasureTimeout = Duration(milliseconds: 1500);

class GravixRegionMeasurement {
  const GravixRegionMeasurement({required this.entry, required this.rttMs, required this.samplesMs});
  final GravixRegionUrl entry;
  String get region => entry.region;
  String get url => entry.url;

  /// Minimum of the warm samples, ms; null when the region did not answer.
  final int? rttMs;
  bool get ok => rttMs != null;

  /// Every sample taken, the dropped first one included.
  final List<int> samplesMs;
}

class GravixRegionMeasurementResult {
  const GravixRegionMeasurementResult({required this.measuredAt, required this.regions, this.best, this.error});
  final DateTime measuredAt;

  /// Reachable regions fastest first, then the unreachable ones.
  final List<GravixRegionMeasurement> regions;

  /// The region joins should use: the fastest, unless the held one is within the
  /// switch margin of it. Null when nothing answered.
  final GravixRegionMeasurement? best;

  /// Why nothing was measured (the list could not be had), when that is the case.
  final String? error;
}

/// One timed request to a region; null when it failed.
typedef GravixRegionSampler = Future<Duration?> Function(GravixRegionUrl region);

/// Fetches the region list from the gateway's `GET /v1/regions`.
typedef GravixRegionListFetcher = Future<List<GravixRegionUrl>> Function(String regionsUrl);

/// Where the last region list is kept, so a start-up with the gateway unreachable
/// still measures. [gravixStartRegionMeasurement] uses
/// [GravixSharedPrefsRegionListStore] (kept across launches) by default, and
/// falls back to [GravixMemoryRegionListStore] (this process only) when
/// shared_preferences is unavailable.
abstract class GravixRegionListStore {
  String? read(String key);
  void write(String key, String value);
}

class GravixMemoryRegionListStore implements GravixRegionListStore {
  final _m = <String, String>{};
  @override
  String? read(String key) => _m[key];
  @override
  void write(String key, String value) => _m[key] = value;
}

/// A [GravixRegionListStore] backed by shared_preferences, so the region list
/// survives an app restart: a cold start with the gateway unreachable still
/// measures the regions it saw last time.
///
/// Reads are synchronous (shared_preferences keeps a cache); writes are
/// written through in the background and never throw.
class GravixSharedPrefsRegionListStore implements GravixRegionListStore {
  GravixSharedPrefsRegionListStore(this._prefs);

  /// With the app's shared preferences instance.
  static Future<GravixSharedPrefsRegionListStore> create() async =>
      GravixSharedPrefsRegionListStore(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  @override
  String? read(String key) {
    try {
      return _prefs.getString(key);
    } catch (_) {
      return null; // a non-string value under our key: treat as absent
    }
  }

  @override
  void write(String key, String value) {
    unawaited(
      _prefs.setString(key, value).then((_) {}, onError: (Object e) => debugPrint('region list not persisted: $e')),
    );
  }
}

final GravixRegionListStore _defaultStore = GravixMemoryRegionListStore();
Future<GravixRegionListStore>? _defaultPersistentStore;

/// The store [gravixStartRegionMeasurement] uses when none is passed: shared
/// preferences when the plugin answers, else the in-process store.
Future<GravixRegionListStore> _persistentStore() =>
    _defaultPersistentStore ??= GravixSharedPrefsRegionListStore.create()
        .timeout(const Duration(seconds: 2))
        .then<GravixRegionListStore>(
          (s) => s,
          onError: (Object e) {
            debugPrint('shared_preferences unavailable ($e): region list kept for this process only');
            return _defaultStore;
          },
        );

@visibleForTesting
void gravixResetDefaultRegionListStore() => _defaultPersistentStore = null;
GravixRegionMeasurementResult? _held;

@visibleForTesting
void gravixClearRegionMeasurement() => _held = null;

/// The current answer, when fresh.
GravixRegionMeasurementResult? gravixRegionMeasurement({DateTime? now}) {
  final held = _held;
  if (held == null || (now ?? DateTime.now()).difference(held.measuredAt) > kGravixRegionMeasurementTtl) {
    return null;
  }
  return held;
}

List<GravixRegionUrl> _parseList(Object? body) {
  final list = body is Map ? body['regions'] : null;
  if (list is! List) return const [];
  return [
    for (final r in list)
      if (r is Map && r['region'] is String && r['url'] is String)
        GravixRegionUrl(
          region: r['region'] as String,
          url: r['url'] as String,
          probeUrl: r['probe_url'] is String ? r['probe_url'] as String : null,
        ),
  ];
}

String _encodeList(List<GravixRegionUrl> list) => json.encode({
  'regions': [
    for (final r in list) {'region': r.region, 'url': r.url, if (r.probeUrl != null) 'probe_url': r.probeUrl},
  ],
});

Future<List<GravixRegionUrl>> _defaultFetchList(String regionsUrl) async {
  final response = await sdkHttpGet(Uri.parse(regionsUrl)).timeout(const Duration(seconds: 5));
  if (response.statusCode == 404) return const []; // no list configured: nothing to measure
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('region list answered ${response.statusCode}');
  }
  return _parseList(json.decode(response.body));
}

Future<Duration?> _defaultSampler(GravixRegionUrl r) async {
  final watch = Stopwatch()..start();
  try {
    final probeUrl = r.probeUrl;
    if (probeUrl != null) {
      final named = await GravixRegionProber.defaultVerifiedProbe(probeUrl).timeout(kGravixMeasureTimeout);
      if (named != null && named != r.region) return null; // a misrouted region never wins
    } else {
      await GravixRegionProber.defaultProbe(r.url).timeout(kGravixMeasureTimeout);
    }
    return watch.elapsed;
  } catch (_) {
    return null;
  }
}

GravixRegionMeasurement? _chooseBest(List<GravixRegionMeasurement> regions) {
  final fastest = regions.where((r) => r.ok).firstOrNull;
  if (fastest == null) return null;
  final previous = _held?.best;
  if (previous != null && previous.region != fastest.region) {
    final now = regions.where((r) => r.region == previous.region).firstOrNull;
    if (now != null && now.ok) {
      final needed = [
        GravixRegionDecisionCache.switchMinGain.inMilliseconds.toDouble(),
        now.rttMs! * GravixRegionDecisionCache.switchMinGainRatio,
      ].reduce((a, b) => a > b ? a : b);
      if (now.rttMs! - fastest.rttMs! <= needed) return now;
    }
  }
  return fastest;
}

/// Measures every region, one after another, and remembers the answer for
/// `connect()`. Never throws. A run with no list, or in which no region answered,
/// returns a result with no `best` and keeps the previous answer until its TTL.
Future<GravixRegionMeasurementResult> gravixMeasureRegions({
  String? regionsUrl,
  List<GravixRegionUrl>? regionUrls,
  GravixRegionSampler? sampler,
  GravixRegionListFetcher? fetchList,
  GravixRegionListStore? store,
}) async {
  final sample = sampler ?? _defaultSampler;
  List<GravixRegionUrl> candidates;
  try {
    if (regionUrls != null) {
      candidates = regionUrls;
    } else if (regionsUrl != null) {
      final st = store ?? _defaultStore;
      final key = 'gravix.regions:$regionsUrl';
      try {
        candidates = await (fetchList ?? _defaultFetchList)(regionsUrl);
        if (candidates.isNotEmpty) st.write(key, _encodeList(candidates));
      } catch (e) {
        // Gateway unreachable: the list this device saw last. Never on the join path.
        final saved = st.read(key);
        final list = saved == null ? const <GravixRegionUrl>[] : _parseList(json.decode(saved));
        if (list.isEmpty) rethrow;
        candidates = list;
      }
    } else {
      throw ArgumentError('gravixMeasureRegions needs regionUrls or regionsUrl');
    }
  } catch (e) {
    final msg = e.toString();
    return GravixRegionMeasurementResult(
      measuredAt: DateTime.now(),
      regions: const [],
      error: msg.length > 200 ? msg.substring(0, 200) : msg,
    );
  }

  final measured = <GravixRegionMeasurement>[];
  for (final c in candidates) {
    final samples = <int>[];
    for (var i = 0; i < kGravixMeasureSamples; i++) {
      final d = await sample(c);
      if (d == null) break; // stop a region at its first failure
      samples.add(d.inMilliseconds);
    }
    final warm = samples.length > 1 ? samples.sublist(1) : const <int>[];
    measured.add(
      GravixRegionMeasurement(
        entry: c,
        rttMs: warm.isEmpty ? null : warm.reduce((a, b) => a < b ? a : b),
        samplesMs: samples,
      ),
    );
  }
  measured.sort((a, b) {
    if (a.ok != b.ok) return a.ok ? -1 : 1;
    if (!a.ok) return 0;
    return a.rttMs!.compareTo(b.rttMs!);
  });
  final best = _chooseBest(measured);
  final result = GravixRegionMeasurementResult(measuredAt: DateTime.now(), regions: measured, best: best);
  if (best != null) _held = result;
  return result;
}

/// The join path's choice: the measured best region if [candidates] offers it,
/// else the fastest measured region it does offer. A lookup, never a probe.
/// Null -- and `connect()` does what it did before -- when nothing fresh is
/// measured or no measured region is offered. Matched by url, else by region.
GravixRegionUrl? gravixPickMeasuredRegion(String pinnedUrl, List<GravixRegionUrl> candidates, {DateTime? now}) {
  final m = gravixRegionMeasurement(now: now);
  if (m == null || m.best == null || candidates.isEmpty) return null;
  final order = [m.best!, ...m.regions.where((r) => r.region != m.best!.region)];
  for (final r in order) {
    if (!r.ok) continue;
    final offered =
        candidates.where((c) => c.url == r.url).firstOrNull ??
        candidates.where((c) => c.region == r.region).firstOrNull;
    if (offered != null) return offered;
  }
  return null;
}

/// The measured regions as join candidates, for a connect whose token came with
/// no region list -- only when [connectUrl] is itself a measured region (a url
/// outside them, e.g. the app's own server, is never redirected). Else empty.
List<GravixRegionUrl> gravixMeasuredCandidates(String connectUrl, {DateTime? now}) {
  final m = gravixRegionMeasurement(now: now);
  String norm(String u) => u.replaceAll(RegExp(r'/+$'), '');
  if (m == null || !m.regions.any((r) => norm(r.url) == norm(connectUrl))) return const [];
  return [for (final r in m.regions) r.entry];
}

/// Measure now, then every [refresh] and whenever the network changes. Call once
/// when the app starts, e.g. with `https://<console host>/v1/regions`. Never throws.
class GravixRegionMeasurementHandle {
  GravixRegionMeasurementHandle._(this._run, this._timer, this._sub);
  final Future<GravixRegionMeasurementResult> Function() _run;
  final Timer? _timer;
  final StreamSubscription<Object?>? _sub;
  late final Future<GravixRegionMeasurementResult> ready;

  /// Measure again now.
  Future<GravixRegionMeasurementResult> refresh() => _run();

  /// Stop re-measuring. The last answer stays until its TTL.
  void stop() {
    _timer?.cancel();
    _sub?.cancel();
  }
}

///
/// [store] keeps the fetched list for a start-up with the gateway unreachable;
/// default [GravixSharedPrefsRegionListStore] (see [GravixRegionListStore]).
/// [sampler] and [fetchList] replace the network steps, as in
/// [gravixMeasureRegions].
GravixRegionMeasurementHandle gravixStartRegionMeasurement({
  String? regionsUrl,
  List<GravixRegionUrl>? regionUrls,
  Duration refresh = kGravixRegionMeasurementRefresh,
  GravixRegionListStore? store,
  bool watchNetwork = true,
  GravixRegionSampler? sampler,
  GravixRegionListFetcher? fetchList,
}) {
  Future<GravixRegionMeasurementResult>? running;
  // The list store matters only when the list is fetched.
  Future<GravixRegionListStore?> resolveStore() async =>
      store ?? (regionUrls == null && regionsUrl != null ? await _persistentStore() : null);
  Future<GravixRegionMeasurementResult> run() => running ??= resolveStore()
      .then(
        (st) => gravixMeasureRegions(
          regionsUrl: regionsUrl,
          regionUrls: regionUrls,
          store: st,
          sampler: sampler,
          fetchList: fetchList,
        ),
      )
      .whenComplete(() => running = null);
  final timer = refresh > Duration.zero ? Timer.periodic(refresh, (_) => run()) : null;
  StreamSubscription<Object?>? sub;
  if (watchNetwork) {
    try {
      sub = Connectivity().onConnectivityChanged.listen((_) => run());
    } catch (_) {
      // no connectivity plugin on this platform: the periodic refresh still runs
    }
  }
  final handle = GravixRegionMeasurementHandle._(run, timer, sub);
  handle.ready = run();
  return handle;
}

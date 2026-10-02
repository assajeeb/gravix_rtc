// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.
//
// Region choice at start-up, like Agora (parity with the React SDK's
// src/core/room/region/initMeasure.ts, 0.4.0 + 0.5.0 + 0.6.4; 2026-09-27).
//
// The app calls [gravixStartRegionMeasurement] once when it starts -- before any
// room or token exists. Each region gets up to [kGravixMeasureSamples] requests on
// ONE keep-alive connection ([GravixRegionProbeClient]): the FIRST opens it (DNS +
// TCP + TLS, dropped), the rest reuse it and each measures one round trip; the
// minimum of those is the region's RTT. A region stops at its first failure.
//
// 0.4.6 (field 2026-10-01, Bangladesh, one phone on one Wi-Fi): the samples used
// to go through `sdkHttpGet`, a new client per request, so every "warm" sample was
// a full cold handshake (sgp1 190-265 / blr1 200-333 ms, flip-flopping, joined
// blr1) while the web SDK on the same phone measured sgp1 61 / blr1 ~120. And the
// regions went one after another: 5 regions x 4 cold samples = 13-15 s per
// measurement on Wi-Fi. Now the regions are measured in PARALLEL, each on its own
// connection, samples sequential within a region. The reason they were sequential
// -- concurrent TLS handshakes contend for the uplink and bias each other --
// applies to the cold sample, which is dropped; the warm samples are ~45-byte
// requests.
//
// 0.4.6, second change (owner 2026-10-02, "scale to 20-50 servers / 10-20
// regions"): which regions are measured is planned by gravix_region_shortlist.dart
// (the gateway's `shortlist`, else `est_rtt_ms`, else a rotating exploration of a
// long list), at most [kGravixMeasureConcurrency] at a time, 1 cold + up to 2 warm
// samples, stopped early once the best clearly wins, and bounded by a TOTAL budget
// (`probe_budget_ms`, default 1.5 s Wi-Fi / 3 s cellular). At the budget the best
// so far is the answer; a region that had not answered is `unmeasured`, not
// failed. Nothing measured: `shortlist[0]`, else the lowest `est_rtt_ms`, else
// nothing -- a guess that only feeds the token's region hint and never moves a
// join. The answer is cached PER NETWORK (type, plus a hashed SSID / carrier the
// app may supply) for `shortlist_ttl_s` (default 10 min): a start-up or network
// change on a known network has its answer at once, the measurement runs behind it.
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
import 'gravix_analytics.dart' show gravixNetworkTypeFrom;
import 'gravix_region_cache.dart';
import 'gravix_region_probe_client.dart';
import 'gravix_region_report.dart';
import 'gravix_region_shortlist.dart';

/// Requests per region: one cold (dropped) + up to two warm. Was 4 until the
/// shortlist change (2026-10-02): the third warm sample rarely moved the minimum
/// and cost a round trip per region. Same as React 0.6.4.
const kGravixMeasureSamples = 3;
const kGravixRegionMeasurementTtl = Duration(minutes: 10);
const kGravixRegionMeasurementRefresh = Duration(minutes: 5);

/// Per-request ceiling of the default sampler. Each request is also cut when the
/// run's total budget ends.
const kGravixMeasureTimeout = Duration(milliseconds: 1500);

/// `ok` = measured (has a warm sample); `failed` = answered with an error, or not
/// at all within its request timeout; `unmeasured` = cut off by the budget, the
/// early exit or a stop before it had a warm sample -- no evidence either way.
enum GravixRegionMeasurementStatus { ok, failed, unmeasured }

/// Where [GravixRegionMeasurementResult.best] came from. `kept` = the held region,
/// within the switch margin of the fastest; `cache` = this network's cached answer
/// (no new measurement yet); `shortlist`/`est` = nothing measured, the gateway's
/// guess. Wire names = [name].
enum GravixRegionBestSource { measured, kept, cache, shortlist, est }

class GravixRegionMeasurement {
  const GravixRegionMeasurement({
    required this.entry,
    required this.rttMs,
    required this.samplesMs,
    this.connections,
    this.status,
    this.source = GravixRegionCandidateSource.all,
    this.budgetHit = false,
    this.retried = false,
  });
  final GravixRegionUrl entry;
  String get region => entry.region;
  String get url => entry.url;

  /// Minimum of the warm samples, ms; null when the region has none.
  final int? rttMs;
  bool get ok => rttMs != null;

  /// Every sample taken, the dropped first one included.
  final List<int> samplesMs;

  /// Sockets the region's probe client opened (1 = every warm sample reused the
  /// first one's connection). Null when a custom stateless [GravixRegionSampler]
  /// measured, or on web.
  final int? connections;

  final GravixRegionMeasurementStatus? status;

  /// [status], or derived from [ok] when constructed without one.
  GravixRegionMeasurementStatus get state =>
      status ?? (ok ? GravixRegionMeasurementStatus.ok : GravixRegionMeasurementStatus.failed);

  /// Why this region was probed.
  final GravixRegionCandidateSource source;

  /// Still being measured when the total budget ran out.
  final bool budgetHit;

  /// The first request got no answer and the region was asked again.
  final bool retried;
}

class GravixRegionMeasurementResult {
  const GravixRegionMeasurementResult({
    required this.measuredAt,
    required this.regions,
    this.best,
    this.error,
    this.elapsed,
    this.bestSource,
    this.mode,
    this.budget,
    this.budgetHit = false,
    this.earlyExit = false,
    this.networkKey,
    this.ttl = kGravixRegionMeasurementTtl,
  });
  final DateTime measuredAt;

  /// How long sampling took (the list fetch excluded). Null when nothing was sampled.
  final Duration? elapsed;

  /// The probed regions: measured fastest first, then unmeasured, then failed.
  final List<GravixRegionMeasurement> regions;

  /// The region joins should use: the fastest, unless the held one is within the
  /// switch margin of it. With nothing measured, the gateway's guess (not [ok],
  /// see [bestSource]). Null when there is none.
  final GravixRegionMeasurement? best;
  final GravixRegionBestSource? bestSource;

  /// Why nothing was measured (the list could not be had), when that is the case.
  final String? error;

  /// How the candidates were chosen.
  final GravixRegionPlanMode? mode;

  /// The total budget this run had.
  final Duration? budget;

  /// The budget ran out with regions still being measured.
  final bool budgetHit;

  /// Stopped early: the remaining samples could not change the choice.
  final bool earlyExit;

  /// The per-network cache key this answer belongs to.
  final String? networkKey;

  /// How long this answer is trusted (`shortlist_ttl_s`, default 10 min).
  final Duration ttl;
}

/// One timed request to a region; null when it failed.
typedef GravixRegionSampler = Future<Duration?> Function(GravixRegionUrl region);

/// Makes the sampler for ONE region's samples, sending them on [client] -- the
/// region's keep-alive connection, closed by the measurement when the region is
/// done. Wrap [GravixRegionProbeClient.probe] / [GravixRegionProbeClient.verifiedProbe]
/// to change the timeout or retries without losing the connection reuse.
typedef GravixRegionSamplerFactory = GravixRegionSampler Function(GravixRegionProbeClient client);

/// Fetches the region list from the gateway's `GET /v1/regions` (regions only;
/// the pre-shortlist hook).
typedef GravixRegionListFetcher = Future<List<GravixRegionUrl>> Function(String regionsUrl);

/// Fetches the gateway's whole `GET /v1/regions` answer (shortlist, budget, ttl).
typedef GravixRegionDirectoryFetcher = Future<GravixRegionDirectory> Function(String regionsUrl);

/// Where the last region list (and the per-network answers) are kept, so a
/// start-up with the gateway unreachable still measures and a start-up on a known
/// network has an answer at once. [gravixStartRegionMeasurement] uses
/// [GravixSharedPrefsRegionListStore] (kept across launches) by default, and falls
/// back to [GravixMemoryRegionListStore] (this process only) when
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

/// Per-network state (in memory, and in the store when there is one).
class _NetworkState {
  _NetworkState({required this.known, required this.cursor, required this.measuredAt, required this.ttl, this.best});
  final List<String> known;
  final int cursor;
  final DateTime measuredAt;
  final Duration ttl;
  final ({String region, String url, int rttMs})? best;

  bool freshAt(DateTime now) => now.difference(measuredAt) <= ttl;

  String encode() => json.encode({
    'known': known,
    'cursor': cursor,
    'measuredAtMs': measuredAt.millisecondsSinceEpoch,
    'ttlMs': ttl.inMilliseconds,
    if (best != null) 'best': {'region': best!.region, 'url': best!.url, 'rttMs': best!.rttMs},
  });

  static _NetworkState? decode(String raw) {
    try {
      final m = json.decode(raw);
      if (m is! Map || m['measuredAtMs'] is! int || m['known'] is! List) return null;
      final b = m['best'];
      return _NetworkState(
        known: [
          for (final k in m['known'] as List)
            if (k is String) k,
        ],
        cursor: m['cursor'] is int ? m['cursor'] as int : 0,
        measuredAt: DateTime.fromMillisecondsSinceEpoch(m['measuredAtMs'] as int),
        ttl: Duration(milliseconds: m['ttlMs'] is int ? m['ttlMs'] as int : kGravixRegionMeasurementTtl.inMilliseconds),
        best: b is Map && b['region'] is String && b['url'] is String && b['rttMs'] is int
            ? (region: b['region'] as String, url: b['url'] as String, rttMs: b['rttMs'] as int)
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

final _memoryStates = <String, _NetworkState>{};

@visibleForTesting
void gravixClearRegionMeasurement() {
  _held = null;
  _memoryStates.clear();
}

/// The current answer, when fresh.
GravixRegionMeasurementResult? gravixRegionMeasurement({DateTime? now}) {
  final held = _held;
  if (held == null || (now ?? DateTime.now()).difference(held.measuredAt) > held.ttl) {
    return null;
  }
  return held;
}

Future<GravixRegionDirectory> _defaultFetchDirectory(String regionsUrl) async {
  final response = await sdkHttpGet(Uri.parse(regionsUrl)).timeout(const Duration(seconds: 5));
  if (response.statusCode == 404) {
    return const GravixRegionDirectory(regions: []); // no list configured: nothing to measure
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('region list answered ${response.statusCode}');
  }
  return GravixRegionDirectory.fromJson(json.decode(response.body));
}

/// The default sampler: one request on [client], timed; null when it failed,
/// timed out ([timeout]) or the probe endpoint named another region.
GravixRegionSampler gravixDefaultRegionSampler(
  GravixRegionProbeClient client, {
  Duration timeout = kGravixMeasureTimeout,
}) => (GravixRegionUrl r) async {
  final watch = Stopwatch()..start();
  try {
    final probeUrl = r.probeUrl;
    if (probeUrl != null) {
      final named = await client.verifiedProbe(probeUrl).timeout(timeout);
      if (named != null && named != r.region) return null; // a misrouted region never wins
    } else {
      await client.probe(r.url).timeout(timeout);
    }
    return watch.elapsed;
  } catch (_) {
    return null;
  }
};

/// The network type for the default budget and cache key: `wifi`, `cellular`,
/// `ethernet` or `unknown`.
typedef GravixRegionNetworkReader = Future<String?> Function();

Future<String?> _defaultNetworkType() async {
  try {
    return gravixNetworkTypeFrom(await Connectivity().checkConnectivity().timeout(const Duration(seconds: 1)));
  } catch (_) {
    return 'unknown';
  }
}

({GravixRegionMeasurement best, bool kept})? _chooseBest(List<GravixRegionMeasurement> regions, String? current) {
  final fastest = regions.where((r) => r.ok).firstOrNull;
  if (fastest == null) return null;
  if (current != null && current != fastest.region) {
    final now = regions.where((r) => r.region == current).firstOrNull;
    if (now != null && now.ok) {
      final needed = [
        GravixRegionDecisionCache.switchMinGain.inMilliseconds.toDouble(),
        now.rttMs! * GravixRegionDecisionCache.switchMinGainRatio,
      ].reduce((a, b) => a > b ? a : b);
      if (now.rttMs! - fastest.rttMs! <= needed) return (best: now, kept: true);
    }
  }
  return (best: fastest, kept: false);
}

GravixRegionMeasurementResult? _resultFromState(_NetworkState s, String networkKey) {
  final b = s.best;
  if (b == null) return null;
  final m = GravixRegionMeasurement(
    entry: GravixRegionUrl(region: b.region, url: b.url),
    rttMs: b.rttMs,
    samplesMs: const [],
    status: GravixRegionMeasurementStatus.ok,
    source: GravixRegionCandidateSource.cache,
  );
  return GravixRegionMeasurementResult(
    measuredAt: s.measuredAt,
    regions: [m],
    best: m,
    bestSource: GravixRegionBestSource.cache,
    networkKey: networkKey,
    ttl: s.ttl,
  );
}

class _Track {
  _Track(this.entry, this.source);
  final GravixRegionUrl entry;
  final GravixRegionCandidateSource source;
  final samples = <int>[];
  bool failed = false;
  bool done = false;
  bool retried = false;
  GravixRegionProbeClient? client;
}

/// Measures the planned regions in parallel within the total budget (each on its
/// own keep-alive connection, its samples one after another), and remembers the
/// answer for `connect()`. Never throws. A run with no list, or in which no region
/// answered, keeps a fresh MEASURED answer for this network until its TTL; a
/// gateway guess (`bestSource` shortlist/est) is held only when there is none.
///
/// [samplerFor] (default [gravixDefaultRegionSampler]) makes each region's sampler
/// on that region's [GravixRegionProbeClient]. [sampler], when given, is used
/// instead for every sample with no client (the pre-0.4.6 stateless hook: it gets
/// no connection reuse unless it keeps its own).
///
/// [budget]: total time, default the gateway's `probe_budget_ms`, else
/// [kGravixMeasureBudget] ([kGravixMeasureBudgetCellular] on cellular).
/// [currentRegion]: the region joins use now when the app holds one (its own
/// cache); default this network's cached answer. Probed even when the plan leaves
/// it out. [networkKey]: the per-network cache key, default the network type; use
/// [gravixRegionNetworkKey] to add an SSID / carrier (hashed). [shortlist]: with
/// [regionUrls], the regions to probe.
Future<GravixRegionMeasurementResult> gravixMeasureRegions({
  String? regionsUrl,
  List<GravixRegionUrl>? regionUrls,
  List<String>? shortlist,
  GravixRegionSampler? sampler,
  GravixRegionSamplerFactory? samplerFor,
  GravixRegionListFetcher? fetchList,
  GravixRegionDirectoryFetcher? fetchDirectory,
  GravixRegionListStore? store,
  Duration? budget,
  String? currentRegion,
  GravixRegionNetworkReader? networkKey,
  GravixRegionNetworkReader? networkType,
}) async {
  final netTypeF = (networkType ?? _defaultNetworkType)().then((v) => v, onError: (Object _) => null);
  final netKeyF = networkKey == null ? netTypeF : networkKey().then((v) => v, onError: (Object _) => null);

  GravixRegionDirectory dir;
  try {
    if (regionUrls != null) {
      dir = GravixRegionDirectory(regions: regionUrls, shortlist: shortlist);
    } else if (regionsUrl != null) {
      final st = store ?? _defaultStore;
      final key = 'gravix.regions:$regionsUrl';
      try {
        if (fetchList != null && fetchDirectory == null) {
          dir = GravixRegionDirectory(regions: await fetchList(regionsUrl));
        } else {
          dir = await (fetchDirectory ?? _defaultFetchDirectory)(regionsUrl);
        }
        // The whole answer (shortlist, budget, ttl), so an offline start plans the same way.
        if (dir.regions.isNotEmpty) st.write(key, json.encode(dir.toJson()));
      } catch (e) {
        // Gateway unreachable: the list this device saw last. Never on the join path.
        final saved = st.read(key);
        final d = saved == null ? null : GravixRegionDirectory.fromJson(json.decode(saved));
        if (d == null || d.regions.isEmpty) rethrow;
        dir = d;
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

  final netType = (await netTypeF) ?? 'unknown';
  final rawKey = await netKeyF;
  final netKey = rawKey == null || rawKey.isEmpty ? netType : rawKey;
  final sKey = 'gravix.regionState:${regionsUrl ?? 'app'}:$netKey';
  // Per-network answers live in memory, and in [store] when the app (or
  // gravixStartRegionMeasurement's shared-preferences default) gave one.
  final savedState = store?.read(sKey);
  final state = _memoryStates[sKey] ?? (savedState == null ? null : _NetworkState.decode(savedState));
  final ttl = dir.shortlistTtl ?? kGravixRegionMeasurementTtl;
  final stateFresh = state != null && state.freshAt(DateTime.now());

  // Never block a join on this run: a fresh answer for THIS network is used now.
  final heldNow = gravixRegionMeasurement();
  if (stateFresh && (heldNow == null || heldNow.networkKey != netKey)) {
    final seeded = _resultFromState(state, netKey);
    if (seeded != null) _held = seeded;
  }
  final heldSame = gravixRegionMeasurement();
  final current =
      currentRegion ??
      (stateFresh ? state.best?.region : null) ??
      (heldSame?.networkKey == netKey ? heldSame?.best?.region : null);

  final plan = gravixPlanRegionCandidates(
    dir,
    state: state == null ? null : GravixRegionPlanState(known: state.known, cursor: state.cursor),
    currentRegion: current,
  );
  final runBudget =
      budget ?? dir.probeBudget ?? (netType == 'cellular' ? kGravixMeasureBudgetCellular : kGravixMeasureBudget);

  final tracks = [for (final c in plan.candidates) _Track(c.entry, c.source)];
  final sw = Stopwatch()..start();
  final end = Completer<String>();
  void finish(String why) {
    if (!end.isCompleted) end.complete(why);
  }

  final budgetTimer = Timer(runBudget, () => finish('budget'));
  List<GravixMeasureProgress> progress() => [
    for (final t in tracks) GravixMeasureProgress(warm: t.samples.skip(1).toList(), done: t.done || t.failed),
  ];

  const cut = Duration(days: -1); // sentinel: the run ended while this sample was out
  Future<void> measureOne(_Track t) async {
    final client = sampler == null ? GravixRegionProbeClient() : null;
    t.client = client;
    try {
      final sample = sampler ?? (samplerFor ?? gravixDefaultRegionSampler)(client!);
      for (var i = 0; i < kGravixMeasureSamples && !end.isCompleted; i++) {
        if (sw.elapsed >= runBudget) return;
        Duration? d;
        try {
          d = await Future.any<Duration?>([sample(t.entry), end.future.then((_) => cut)]);
        } catch (_) {
          d = null;
        }
        if (end.isCompleted || d == cut) return; // an answer after the end is not part of this run
        if (d == null) {
          if (t.samples.isEmpty && !t.retried) {
            // A lost SYN or TLS flight on a lossy link is the common cause; the retry
            // starts with DNS cached.
            t.retried = true;
            i--;
            continue;
          }
          t.failed = true;
          break;
        }
        t.samples.add(d.inMilliseconds);
        if (t.samples.length >= 2 && gravixShouldStopMeasuring(progress())) {
          finish('early');
          return;
        }
      }
      t.done = true;
      if (gravixShouldStopMeasuring(progress())) finish('early');
    } catch (_) {
      t.failed = true;
    }
  }

  var next = 0;
  Future<void> worker() async {
    while (!end.isCompleted && next < tracks.length) {
      await measureOne(tracks[next++]);
    }
  }

  final workers = [for (var i = 0; i < tracks.length && i < kGravixMeasureConcurrency; i++) worker()];
  unawaited(Future.wait(workers).then((_) => finish('complete')));
  final why = await end.future;
  budgetTimer.cancel();
  final elapsed = sw.elapsed;
  for (final t in tracks) {
    t.client?.close(); // aborts a request still in flight
  }

  final measured = <GravixRegionMeasurement>[
    for (final t in tracks)
      () {
        final warm = t.samples.skip(1).toList();
        final status = warm.isNotEmpty
            ? GravixRegionMeasurementStatus.ok
            : t.failed
            ? GravixRegionMeasurementStatus.failed
            : GravixRegionMeasurementStatus.unmeasured;
        return GravixRegionMeasurement(
          entry: t.entry,
          rttMs: warm.isEmpty ? null : warm.reduce((a, b) => a < b ? a : b),
          samplesMs: List.unmodifiable(t.samples),
          connections: t.client?.connections,
          status: status,
          source: t.source,
          budgetHit: why == 'budget' && !t.done && !t.failed,
          retried: t.retried,
        );
      }(),
  ];
  measured.sort((a, b) {
    if (a.state != b.state) return a.state.index.compareTo(b.state.index);
    if (!a.ok) return 0;
    return a.rttMs!.compareTo(b.rttMs!);
  });

  final choice = _chooseBest(measured, current);
  GravixRegionMeasurement? best = choice?.best;
  GravixRegionBestSource? bestSource = choice == null
      ? null
      : choice.kept
      ? GravixRegionBestSource.kept
      : GravixRegionBestSource.measured;
  if (choice == null) {
    final fb = gravixFallbackRegion(dir);
    if (fb != null) {
      best =
          measured.where((m) => m.region == fb.entry.region).firstOrNull ??
          GravixRegionMeasurement(
            entry: fb.entry,
            rttMs: null,
            samplesMs: const [],
            status: GravixRegionMeasurementStatus.unmeasured,
            source: fb.source,
          );
      bestSource = fb.source == GravixRegionCandidateSource.shortlist
          ? GravixRegionBestSource.shortlist
          : GravixRegionBestSource.est;
    }
  }

  final result = GravixRegionMeasurementResult(
    measuredAt: DateTime.now(),
    regions: List.unmodifiable(measured),
    best: best,
    bestSource: bestSource,
    elapsed: elapsed,
    mode: plan.mode,
    budget: runBudget,
    budgetHit: why == 'budget',
    earlyExit: why == 'early',
    networkKey: netKey,
    ttl: ttl,
  );

  final measuredBest = best != null && best.ok ? best : null;
  final newState = _NetworkState(
    known: gravixNextKnown(
      [
        for (final m in measured)
          if (m.ok) m.region,
      ],
      [for (final m in measured) m.region],
      state?.known ?? const [],
    ),
    cursor: plan.cursor,
    measuredAt: measuredBest != null ? DateTime.now() : (state?.measuredAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
    ttl: measuredBest != null ? ttl : (state?.ttl ?? ttl),
    best: measuredBest != null
        ? (region: measuredBest.region, url: measuredBest.url, rttMs: measuredBest.rttMs!)
        : (stateFresh ? state.best : null),
  );
  _memoryStates[sKey] = newState;
  try {
    store?.write(sKey, newState.encode());
  } catch (_) {
    // the memory copy still serves this process
  }

  final currentHeld = gravixRegionMeasurement();
  final currentIsMeasured = currentHeld?.networkKey == netKey && (currentHeld?.best?.ok ?? false);
  if (best != null && best.ok) {
    _held = result;
  } else if (!currentIsMeasured) {
    // A guess (or nothing) for this network: never over a fresh measured answer.
    _held = best != null ? result : (currentHeld?.networkKey == netKey ? currentHeld : null);
  }
  return result;
}

/// The measurement as the analytics / connection reports carry it (wire names,
/// shared with the React SDK and the tester's `regions_measured`): per probed
/// region its samples, connections, why it was probed and whether the budget cut
/// it. The backend learns its latency map (`est_rtt_ms`, shortlists) from these.
/// Null when nothing was sampled (e.g. only a cached answer).
Map<String, Object?>? gravixRegionsMeasuredReport([GravixRegionMeasurementResult? result]) {
  final r = result ?? gravixRegionMeasurement();
  if (r == null || !r.regions.any((m) => m.samplesMs.isNotEmpty)) return null;
  return {
    'measured_at': gravixIsoMs(r.measuredAt),
    'mode': (r.mode ?? GravixRegionPlanMode.all).name,
    'network': r.networkKey ?? 'unknown',
    'budget_ms': r.budget?.inMilliseconds ?? 0,
    'budget_hit': r.budgetHit,
    'early_exit': r.earlyExit,
    'elapsed_ms': r.elapsed?.inMilliseconds ?? 0,
    'best': r.best?.region,
    'best_source': r.bestSource?.name,
    'regions': [
      for (final m in r.regions)
        {
          'region': m.region,
          'rtt_ms': m.rttMs,
          'status': m.state.name,
          'samples_ms': m.samplesMs,
          'conns': m.connections,
          'source': m.source.name,
          'budget_hit': m.budgetHit,
        },
    ],
  };
}

/// The join path's choice: the measured best region if [candidates] offers it,
/// else the fastest measured region it does offer. A lookup, never a probe.
/// Null -- and `connect()` does what it did before -- when nothing fresh is
/// measured or no measured region is offered. Matched by url, else by region.
///
/// The pinned url (the token's region: the app's own choice) is kept unless the
/// pick is clearly faster in the same measurement -- the decision cache's rule,
/// more than [GravixRegionDecisionCache.switchMinGain] AND more than
/// [GravixRegionDecisionCache.switchMinGainRatio] lower. Field 2026-09-30: the
/// tester kept sgp1 (180 ms) over blr1 (167 ms), minted its token and opened its
/// standby for sgp1, and this lookup moved the join to blr1 anyway: a cold dial
/// (wsOpen 200-1300 ms instead of ~80) to another region than the token named,
/// and the region flip-flop the app was avoiding.
GravixRegionUrl? gravixPickMeasuredRegion(String pinnedUrl, List<GravixRegionUrl> candidates, {DateTime? now}) {
  final m = gravixRegionMeasurement(now: now);
  if (m == null || m.best == null || candidates.isEmpty) return null;
  final order = [m.best!, ...m.regions.where((r) => r.region != m.best!.region)];
  GravixRegionMeasurement? pickedM;
  GravixRegionUrl? picked;
  for (final r in order) {
    if (!r.ok) continue;
    final offered =
        candidates.where((c) => c.url == r.url).firstOrNull ??
        candidates.where((c) => c.region == r.region).firstOrNull;
    if (offered != null) {
      pickedM = r;
      picked = offered;
      break;
    }
  }
  if (picked == null || pickedM == null) return null;
  String norm(String u) => u.replaceAll(RegExp(r'/+$'), '');
  if (norm(picked.url) == norm(pinnedUrl)) return picked;
  final pinnedM = m.regions.where((r) => r.ok && norm(r.url) == norm(pinnedUrl)).firstOrNull;
  final pinned = candidates.where((c) => norm(c.url) == norm(pinnedUrl)).firstOrNull;
  if (pinnedM == null || pinned == null) return picked;
  final gain = pinnedM.rttMs! - pickedM.rttMs!;
  final needed = [
    GravixRegionDecisionCache.switchMinGain.inMilliseconds.toDouble(),
    pinnedM.rttMs! * GravixRegionDecisionCache.switchMinGainRatio,
  ].reduce((a, b) => a > b ? a : b);
  return gain > needed ? picked : pinned;
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
/// [sampler], [samplerFor], [fetchList] and [fetchDirectory] replace the network
/// steps, and [shortlist], [budget], [networkKey] and [networkType] are passed
/// through, as in [gravixMeasureRegions]. [currentRegion] is read at every run
/// (the app's region in use may change between runs).
GravixRegionMeasurementHandle gravixStartRegionMeasurement({
  String? regionsUrl,
  List<GravixRegionUrl>? regionUrls,
  Duration refresh = kGravixRegionMeasurementRefresh,
  GravixRegionListStore? store,
  bool watchNetwork = true,
  GravixRegionSampler? sampler,
  GravixRegionSamplerFactory? samplerFor,
  GravixRegionListFetcher? fetchList,
  GravixRegionDirectoryFetcher? fetchDirectory,
  List<String>? shortlist,
  Duration? budget,
  String? Function()? currentRegion,
  GravixRegionNetworkReader? networkKey,
  GravixRegionNetworkReader? networkType,
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
          samplerFor: samplerFor,
          fetchList: fetchList,
          fetchDirectory: fetchDirectory,
          shortlist: shortlist,
          budget: budget,
          currentRegion: currentRegion?.call(),
          networkKey: networkKey,
          networkType: networkType,
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

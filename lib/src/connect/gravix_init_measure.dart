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
import 'gravix_region_failover.dart' show gravixNormalizeRegionUrl;
import 'gravix_region_media.dart';
import 'gravix_region_probe_client.dart';
import 'gravix_region_report.dart';
import 'gravix_region_selection.dart';
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
    this.selectReason,
    this.challenger,
    this.bestByMedia = const {},
    this.mediaSelectReason = const {},
    this.mediaChallenger = const {},
  });
  final DateTime measuredAt;

  /// Per-region media (2026-10-21): for a medium some measured region does not
  /// take, the region joins of that medium use -- the same hysteresis as [best]
  /// (an anchor per medium, a rival must win twice by the keep margin), over the
  /// regions that take it. Absent: [best] serves (it takes the medium, or no
  /// region was filtered). See [GravixRegionMeasurementResult.bestFor].
  final Map<GravixRoomMedia, GravixRegionMeasurement> bestByMedia;

  /// How [bestByMedia] was chosen, per medium.
  final Map<GravixRoomMedia, GravixRegionSelectReason> mediaSelectReason;

  /// A rival not yet confirmed, per medium.
  final Map<GravixRoomMedia, GravixRegionChallenger> mediaChallenger;

  /// The region a [media] join should prefer: [bestByMedia], else [best].
  GravixRegionMeasurement? bestFor(GravixRoomMedia? media) => (media == null ? null : bestByMedia[media]) ?? best;

  /// How the hysteresis chose [best] (gravix_region_selection.dart). Null when
  /// nothing was measured `ok`, or for an answer seeded from the cache.
  final GravixRegionSelectReason? selectReason;

  /// A rival that beat the held region in this measurement but is not yet
  /// confirmed (with [selectReason] `confirming`).
  final GravixRegionChallenger? challenger;

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

typedef _RegionRtt = ({String region, String url, int rttMs});

Map<String, Object?> _rttJson(_RegionRtt r) => {'region': r.region, 'url': r.url, 'rttMs': r.rttMs};

_RegionRtt? _rttFrom(Object? b) => b is Map && b['region'] is String && b['url'] is String && b['rttMs'] is int
    ? (region: b['region'] as String, url: b['url'] as String, rttMs: b['rttMs'] as int)
    : null;

/// Per-network state (in memory, and in the store when there is one).
class _NetworkState {
  _NetworkState({
    required this.known,
    required this.cursor,
    required this.measuredAt,
    required this.ttl,
    this.best,
    this.regions = const [],
    this.anchor,
    this.anchorAt,
    this.challenger,
    this.mediaAnchors = const {},
    this.mediaChallengers = const {},
  });
  final List<String> known;

  /// Per-medium anchors (2026-10-21): wire `mediaAnchors: {video: {region, url,
  /// rttMs, atMs}}`, and `mediaChallengers: {video: {region, wins}}` -- the same
  /// keys in every SDK (the shared fixture seeds them).
  final Map<GravixRoomMedia, ({_RegionRtt rtt, DateTime at})> mediaAnchors;
  final Map<GravixRoomMedia, GravixRegionChallenger> mediaChallengers;

  _RegionRtt? liveMediaAnchor(GravixRoomMedia m, DateTime now) {
    final a = mediaAnchors[m];
    return a != null && now.difference(a.at) <= kGravixRegionAnchorLife ? a.rtt : null;
  }

  final int cursor;
  final DateTime measuredAt;
  final Duration ttl;
  final _RegionRtt? best;

  /// Every region the last measuring run measured `ok`, fastest first: a start-up
  /// seeded from this cache has the whole picture, so the join's keep-pinned and
  /// home-region rules can compare (with only [best] they could not, and the
  /// lookup moved to [best] whatever the pinned / home region measured).
  final List<_RegionRtt> regions;

  /// The last good region, kept for [kGravixRegionAnchorLife] (see
  /// gravix_region_selection.dart), and when it was last confirmed.
  final _RegionRtt? anchor;
  final DateTime? anchorAt;

  /// A rival that beat the anchor in the previous measurement(s).
  final GravixRegionChallenger? challenger;

  bool freshAt(DateTime now) => now.difference(measuredAt) <= ttl;

  /// The anchor, while it is within its life.
  _RegionRtt? liveAnchor(DateTime now) =>
      anchor != null && anchorAt != null && now.difference(anchorAt!) <= kGravixRegionAnchorLife ? anchor : null;

  String encode() => json.encode({
    'known': known,
    'cursor': cursor,
    'measuredAtMs': measuredAt.millisecondsSinceEpoch,
    'ttlMs': ttl.inMilliseconds,
    if (best != null) 'best': _rttJson(best!),
    if (regions.isNotEmpty) 'regions': [for (final r in regions) _rttJson(r)],
    if (anchor != null && anchorAt != null) 'anchor': {..._rttJson(anchor!), 'atMs': anchorAt!.millisecondsSinceEpoch},
    if (challenger != null) 'challenger': challenger!.toJson(),
    if (mediaAnchors.isNotEmpty)
      'mediaAnchors': {
        for (final e in mediaAnchors.entries)
          e.key.name: {..._rttJson(e.value.rtt), 'atMs': e.value.at.millisecondsSinceEpoch},
      },
    if (mediaChallengers.isNotEmpty)
      'mediaChallengers': {for (final e in mediaChallengers.entries) e.key.name: e.value.toJson()},
  });

  static _NetworkState? decode(String raw) {
    try {
      final m = json.decode(raw);
      if (m is! Map || m['measuredAtMs'] is! int || m['known'] is! List) return null;
      final a = m['anchor'];
      final anchor = _rttFrom(a);
      final regs = m['regions'];
      return _NetworkState(
        known: [
          for (final k in m['known'] as List)
            if (k is String) k,
        ],
        cursor: m['cursor'] is int ? m['cursor'] as int : 0,
        measuredAt: DateTime.fromMillisecondsSinceEpoch(m['measuredAtMs'] as int),
        ttl: Duration(milliseconds: m['ttlMs'] is int ? m['ttlMs'] as int : kGravixRegionMeasurementTtl.inMilliseconds),
        best: _rttFrom(m['best']),
        regions: [
          if (regs is List)
            for (final r in regs)
              if (_rttFrom(r) != null) _rttFrom(r)!,
        ],
        anchor: anchor != null && a is Map && a['atMs'] is int ? anchor : null,
        anchorAt: anchor != null && a is Map && a['atMs'] is int
            ? DateTime.fromMillisecondsSinceEpoch(a['atMs'] as int)
            : null,
        challenger: GravixRegionChallenger.fromJson(m['challenger']),
        mediaAnchors: {
          if (m['mediaAnchors'] is Map)
            for (final e in (m['mediaAnchors'] as Map).entries)
              if (GravixRoomMedia.values.asNameMap()[e.key] != null &&
                  _rttFrom(e.value) != null &&
                  (e.value as Map)['atMs'] is int)
                GravixRoomMedia.values.asNameMap()[e.key]!: (
                  rtt: _rttFrom(e.value)!,
                  at: DateTime.fromMillisecondsSinceEpoch((e.value as Map)['atMs'] as int),
                ),
        },
        mediaChallengers: {
          if (m['mediaChallengers'] is Map)
            for (final e in (m['mediaChallengers'] as Map).entries)
              if (GravixRoomMedia.values.asNameMap()[e.key] != null && GravixRegionChallenger.fromJson(e.value) != null)
                GravixRoomMedia.values.asNameMap()[e.key]!: GravixRegionChallenger.fromJson(e.value)!,
        },
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
  gravixClearRegionMedia();
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

Future<List<ConnectivityResult>?> _connectivity() async {
  try {
    return await Connectivity().checkConnectivity().timeout(const Duration(seconds: 1));
  } catch (_) {
    return null;
  }
}

/// The per-network cache key for a connectivity reading: the network type, plus
/// `+vpn` while a VPN is up.
///
/// Field 2026-10-04: a tester in Saudi Arabia on mobile data measured doh1 for
/// five sessions, then turned a VPN on (exit: a hosting network in Canada). The
/// measurement through the VPN correctly picked nyc1 -- the packets left from
/// Canada -- but VPN on and VPN off were both `cellular`, so after the VPN went
/// off the nyc1 answer (~300 ms from Saudi) was still this network's cached
/// answer for up to 10 minutes and the anchor the next measurement had to beat.
/// Android reports a VPN as its own transport next to the underlying one
/// (connectivity_plus: `[mobile, vpn]`), so the two now cache apart.
String gravixRegionNetworkKeyFrom(List<ConnectivityResult> results) {
  final type = gravixNetworkTypeFrom(results);
  return results.contains(ConnectivityResult.vpn) ? '$type+vpn' : type;
}

GravixRegionMeasurementResult? _resultFromState(_NetworkState s, String networkKey) {
  final b = s.best;
  if (b == null) return null;
  GravixRegionMeasurement toM(_RegionRtt r) => GravixRegionMeasurement(
    entry: GravixRegionUrl(region: r.region, url: r.url),
    rttMs: r.rttMs,
    samplesMs: const [],
    status: GravixRegionMeasurementStatus.ok,
    source: GravixRegionCandidateSource.cache,
  );
  final m = toM(b);
  // Every region measured last time (fastest first), [best] first: the join's
  // keep-pinned and home-region rules need the others' numbers too.
  final others = [
    for (final r in s.regions)
      if (r.region != b.region) toM(r),
  ];
  return GravixRegionMeasurementResult(
    measuredAt: s.measuredAt,
    regions: [m, ...others],
    best: m,
    bestByMedia: {for (final e in s.mediaAnchors.entries) e.key: toM(e.value.rtt)},
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
  // One connectivity reading serves both the type (budget) and the cache key,
  // unless the app supplied either.
  final connF = networkType != null && networkKey != null ? Future.value(null) : _connectivity();
  final netTypeF = networkType != null
      ? networkType().then((v) => v, onError: (Object _) => null)
      : connF.then((c) => c == null ? 'unknown' : gravixNetworkTypeFrom(c));
  final netKeyF = networkKey != null
      ? networkKey().then((v) => v, onError: (Object _) => null)
      : networkType != null
      ? netTypeF // an app that names the type keys by it (pre-VPN behaviour)
      : connF.then((c) => c == null ? 'unknown' : gravixRegionNetworkKeyFrom(c));

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

  // What each region allows (`media`), for the join's media filter: a lookup
  // there, never a fetch (gravix_region_media.dart).
  gravixNoteRegionDirectory(dir.regions, shortlist: dir.shortlist);
  final mediaLimited = [
    for (final r in dir.regions)
      if (r.media != null) '${r.region}(${r.media!.join('+')})',
  ];
  if (mediaLimited.isNotEmpty) GravixRegionLog.step('directory', 'media-limited ${mediaLimited.join(' ')}');

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
  // The anchor: the region joins use now on this network. Kept for hours, not
  // just while the answer is fresh (gravix_region_selection.dart).
  final nowAtStart = DateTime.now();
  final liveAnchor = state?.liveAnchor(nowAtStart);
  final current =
      currentRegion ??
      liveAnchor?.region ??
      (stateFresh ? state.best?.region : null) ??
      (heldSame?.networkKey == netKey && (heldSame?.best?.ok ?? false) ? heldSame?.best?.region : null);

  final plan = gravixPlanRegionCandidates(
    dir,
    state: state == null ? null : GravixRegionPlanState(known: state.known, cursor: state.cursor),
    currentRegion: current,
  );
  // On cellular the SDK's own 3 s is a FLOOR under the gateway's budget: the
  // console answers `probe_budget_ms: 1500` for every caller (a Wi-Fi-sized
  // number), which used to replace the cellular default outright, so a cellular
  // start-up never had more than 1.5 s for a cold TLS handshake plus two samples.
  // An app's explicit [budget] still wins.
  final Duration runBudget;
  if (budget != null) {
    runBudget = budget;
  } else if (netType == 'cellular') {
    final b = dir.probeBudget;
    runBudget = b != null && b > kGravixMeasureBudgetCellular ? b : kGravixMeasureBudgetCellular;
  } else {
    runBudget = dir.probeBudget ?? kGravixMeasureBudget;
  }

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
        // the budget is spent: END the run as a budget stop. Returning alone let
        // every worker skip its remaining regions at once and the run end as
        // 'complete' before a delayed budget Timer fired (busy event loop), so a
        // run that ran out of budget reported budgetHit=false (2026-10-11, the
        // flaky "scale: 50 regions" test; region_budget_race_test.dart).
        if (sw.elapsed >= runBudget) {
          finish('budget');
          return;
        }
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

  // The last-known RTT of the anchor, for keeping it through a run in which it
  // got no answer within the budget (`unmeasured`, not failed).
  _RegionRtt? lastKnown(String region) =>
      (liveAnchor?.region == region ? liveAnchor : null) ??
      state?.regions.where((r) => r.region == region).firstOrNull ??
      (state?.best?.region == region ? state?.best : null);
  final anchorLast = current == null ? null : lastKnown(current);
  final selection = gravixSelectRegion(
    [for (final m in measured) GravixRegionSample(region: m.region, status: m.state.name, rttMs: m.rttMs)],
    anchor: current,
    // The votes belong to the anchor they were cast against.
    challenger: current != null && (liveAnchor == null || current == liveAnchor.region) ? state?.challenger : null,
    anchorKnown: anchorLast != null,
  );
  GravixRegionMeasurement? best;
  GravixRegionBestSource? bestSource;
  if (selection != null) {
    final m = measured.where((m) => m.region == selection.region).first;
    if (m.ok) {
      best = m;
    } else {
      // `confirming` with an unmeasured anchor: its last-known number stands in.
      best = GravixRegionMeasurement(
        entry: m.entry,
        rttMs: anchorLast!.rttMs,
        samplesMs: m.samplesMs,
        connections: m.connections,
        status: GravixRegionMeasurementStatus.ok,
        source: GravixRegionCandidateSource.cache,
        budgetHit: m.budgetHit,
        retried: m.retried,
      );
    }
    bestSource =
        selection.reason == GravixRegionSelectReason.kept || selection.reason == GravixRegionSelectReason.confirming
        ? GravixRegionBestSource.kept
        : GravixRegionBestSource.measured;
  }
  if (selection == null) {
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

  // Per-region media (2026-10-21): for each medium some measured region does
  // not take, the same hysteresis over the regions that do, with its own anchor,
  // so joins of that medium do not flip between two close regions either.
  final bestByMedia = <GravixRoomMedia, GravixRegionMeasurement>{};
  final mediaReason = <GravixRoomMedia, GravixRegionSelectReason>{};
  final mediaChallenger = <GravixRoomMedia, GravixRegionChallenger>{};
  final mediaAnchorsNext = <GravixRoomMedia, ({_RegionRtt rtt, DateTime at})>{...?state?.mediaAnchors};
  final mediaChallengersNext = <GravixRoomMedia, GravixRegionChallenger>{...?state?.mediaChallengers};
  for (final media in GravixRoomMedia.values) {
    final takes = [
      for (final m in measured)
        if (gravixRegionAllowsMedia(m.entry, media)) m,
    ];
    if (takes.length == measured.length || takes.isEmpty) continue;
    final mAnchor = state?.liveMediaAnchor(media, nowAtStart);
    final sel = gravixSelectRegion(
      [for (final m in takes) GravixRegionSample(region: m.region, status: m.state.name, rttMs: m.rttMs)],
      anchor: mAnchor?.region,
      challenger: state?.mediaChallengers[media],
      anchorKnown: mAnchor != null,
    );
    if (sel == null) continue; // no evidence: the anchor and its votes stay
    final m = takes.where((t) => t.region == sel.region).first;
    final chosen = m.ok
        ? m
        : GravixRegionMeasurement(
            entry: m.entry,
            rttMs: mAnchor!.rttMs,
            samplesMs: m.samplesMs,
            status: GravixRegionMeasurementStatus.ok,
            source: GravixRegionCandidateSource.cache,
          );
    bestByMedia[media] = chosen;
    mediaReason[media] = sel.reason;
    if (sel.challenger != null) {
      mediaChallenger[media] = sel.challenger!;
      mediaChallengersNext[media] = sel.challenger!;
    } else {
      mediaChallengersNext.remove(media);
    }
    mediaAnchorsNext[media] = (rtt: (region: chosen.region, url: chosen.url, rttMs: chosen.rttMs!), at: DateTime.now());
    GravixRegionLog.step(
      'select',
      'media=${media.name} -> ${chosen.region} rtt=${chosen.rttMs} reason=${sel.reason.name}'
          '${mAnchor == null ? '' : ' anchor=${mAnchor.region}'}'
          '${sel.challenger == null ? '' : ' challenger=${sel.challenger!.region}x${sel.challenger!.wins}'}',
    );
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
    selectReason: selection?.reason,
    challenger: selection?.challenger,
    bestByMedia: bestByMedia,
    mediaSelectReason: mediaReason,
    mediaChallenger: mediaChallenger,
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
    regions: measuredBest != null
        ? [
            for (final m in measured)
              if (m.ok) (region: m.region, url: m.url, rttMs: m.rttMs!),
          ]
        : (stateFresh ? state.regions : const []),
    // A run with no measured region keeps the anchor (and its age) as it was.
    anchor: measuredBest != null
        ? (region: measuredBest.region, url: measuredBest.url, rttMs: measuredBest.rttMs!)
        : liveAnchor,
    anchorAt: measuredBest != null ? DateTime.now() : (liveAnchor != null ? state?.anchorAt : null),
    challenger: selection != null ? selection.challenger : state?.challenger,
    mediaAnchors: mediaAnchorsNext,
    mediaChallengers: mediaChallengersNext,
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
    if (r.selectReason != null) 'select_reason': r.selectReason!.name,
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

/// Why [gravixPickRegion] chose its region. Wire names = [name].
///
/// - `measured`: the measured best region (or the fastest the room offers);
/// - `pinned`: the pinned url, kept because the pick was not clearly faster;
/// - `home`: the room's home region, within the home margin of the fastest;
/// - `fallback` (2026-10-21): no measured region the room offers allows the
///   join's media and the pinned url's region does not either: the first
///   shortlist region allowing it (else the lowest `est_rtt_ms`, else the first
///   offered one that does).
enum GravixRegionPickReason { measured, pinned, home, fallback }

/// A [gravixPickRegionFor] answer: the region, why, and what the media filter did.
@immutable
class GravixRegionPick {
  const GravixRegionPick({
    required this.entry,
    required this.reason,
    this.media,
    this.skipped = const [],
    this.mediaIgnored = false,
  });

  final GravixRegionUrl entry;
  final GravixRegionPickReason reason;

  /// The join's media (null: no filter).
  final GravixRoomMedia? media;

  /// Measured regions the room offers that were passed over because they do not
  /// allow [media], fastest first.
  final List<String> skipped;

  /// No offered region allows [media]: the pick ignored it, so the join still has
  /// a region (the server refuses what it does not take; see
  /// gravix_region_failover.dart).
  final bool mediaIgnored;
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
///
/// [homeRegion] (a viewer / guest joining someone else's room): the region the
/// room lives on, when the app's backend knows it (e.g. the token response's
/// `home_region`, [gravixHomeRegionFrom]). It wins when it is offered, measured
/// `ok`, and within [gravixHomeRegionMargin] (max(25 ms, 30 %)) of the fastest
/// offered region: joining it saves the relay hop between the viewer's region and
/// the host's (e.g. a host in sgp1 and a viewer in blr1: a few ms apart, yet
/// 2.9-3.4 % loss measured on the relay leg). Further away, the viewer's own pick stands (the room
/// is relayed to it) and the pinned rule is skipped, so a pinned home url cannot
/// keep it either. Home not measured: as if none were given. Hosts pass none.
///
/// [media] (2026-10-21, gravix_region_media.dart): only regions allowing the
/// join's media are offered -- measured, pinned and home alike. See
/// [gravixPickRegionFor].
GravixRegionUrl? gravixPickMeasuredRegion(
  String pinnedUrl,
  List<GravixRegionUrl> candidates, {
  DateTime? now,
  String? homeRegion,
  GravixRoomMedia? media,
}) => gravixPickRegionFor(pinnedUrl, candidates, now: now, homeRegion: homeRegion, media: media)?.entry;

/// [gravixPickMeasuredRegion], with why it chose that region.
({GravixRegionUrl entry, GravixRegionPickReason reason})? gravixPickRegion(
  String pinnedUrl,
  List<GravixRegionUrl> candidates, {
  DateTime? now,
  String? homeRegion,
  GravixRoomMedia? media,
}) {
  final p = gravixPickRegionFor(pinnedUrl, candidates, now: now, homeRegion: homeRegion, media: media);
  return p == null ? null : (entry: p.entry, reason: p.reason);
}

String _normUrl(String u) => u.replaceAll(RegExp(r'/+$'), '');

/// [gravixPickRegion] with the media filter's details, and one
/// `[GravixRegion] pick` line when [media] is given (the decision and its cause).
///
/// With [media]:
///  1. the candidates that allow it are the offer (entry `media`, else the last
///     `/v1/regions` answer, else allowed; a region that refused it lately is
///     not) -- none does: every candidate, [GravixRegionPick.mediaIgnored];
///  2. the measured pick, the pinned rule and the home rule run on that offer;
///  3. nothing measured on it: the pinned url stays (null, as before) when its
///     region allows [media] or is unknown; else the first shortlist region
///     allowing it, the lowest `est_rtt_ms` allowing it, or the first offered
///     one (`fallback`).
GravixRegionPick? gravixPickRegionFor(
  String pinnedUrl,
  List<GravixRegionUrl> candidates, {
  DateTime? now,
  String? homeRegion,
  GravixRoomMedia? media,
}) {
  if (candidates.isEmpty) return null;
  final m = gravixRegionMeasurement(now: now);
  final allowed = media == null
      ? candidates
      : [
          for (final c in candidates)
            if (gravixRegionAllowsMedia(c, media, now: now)) c,
        ];
  final ignored = media != null && allowed.isEmpty;
  final offer = ignored ? candidates : allowed;
  final skipped = <String>[];
  final skipWhy = <String>[];
  if (m != null && media != null && !ignored) {
    final best = m.bestFor(media);
    final order = [?best, ...m.regions.where((r) => r.region != best?.region)];
    for (final r in order) {
      if (!r.ok || skipped.contains(r.region)) continue;
      final c =
          candidates.where((c) => c.url == r.url).firstOrNull ??
          candidates.where((c) => c.region == r.region).firstOrNull;
      if (c != null && !offer.contains(c)) {
        skipped.add(r.region);
        skipWhy.add('${r.region}(${gravixMediaSkipWhy(c, media, now: now)})');
      }
    }
  }

  GravixRegionPick? pick = _pickMeasured(
    pinnedUrl,
    offer,
    m,
    homeRegion: homeRegion,
    media: media,
    skipped: skipped,
    ignored: ignored,
  );
  if (pick == null && media != null && !ignored) {
    // Nothing measured on the offer. The pinned url stays unless its region is
    // known not to take [media].
    final n = gravixNormalizeRegionUrl(pinnedUrl);
    final pinnedEntry =
        candidates.where((c) => gravixNormalizeRegionUrl(c.url) == n).firstOrNull ??
        gravixLastRegionDirectory().where((c) => gravixNormalizeRegionUrl(c.url) == n).firstOrNull;
    if (pinnedEntry != null && !gravixRegionAllowsMedia(pinnedEntry, media, now: now)) {
      final fb = gravixFallbackRegion(
        GravixRegionDirectory(regions: gravixLastRegionDirectory(), shortlist: gravixLastRegionShortlist()),
        media: media,
      );
      final offered = fb == null ? null : offer.where((c) => c.region == fb.entry.region).firstOrNull;
      pick = GravixRegionPick(
        entry: offered ?? offer.first,
        reason: GravixRegionPickReason.fallback,
        media: media,
        skipped: skipped,
      );
      GravixRegionLog.step(
        'pick',
        'media=${media.name} nothing-measured pinned=${pinnedEntry.region}(${gravixMediaSkipWhy(pinnedEntry, media, now: now)})'
            ' -> ${pick.entry.region} reason=fallback cause=${offered != null ? fb!.source.name : 'first-offered'}',
      );
      return pick;
    }
  }
  if (media != null) {
    final rtt = pick == null
        ? null
        : m?.regions.where((r) => r.region == pick!.entry.region && r.ok).firstOrNull?.rttMs;
    GravixRegionLog.step(
      'pick',
      'media=${media.name}${skipWhy.isEmpty ? '' : ' skip=${skipWhy.join(',')}'}'
          '${ignored ? ' mediaIgnored(no region allows ${media.name})' : ''}'
          ' -> ${pick == null ? 'token-url cause=${m == null ? 'no-measurement' : 'nothing-measured'}' : '${pick.entry.region} rtt=${rtt ?? '?'} reason=${pick.reason.name}'}',
    );
  }
  return pick;
}

GravixRegionPick? _pickMeasured(
  String pinnedUrl,
  List<GravixRegionUrl> candidates,
  GravixRegionMeasurementResult? m, {
  String? homeRegion,
  GravixRoomMedia? media,
  List<String> skipped = const [],
  bool ignored = false,
}) {
  if (m == null || m.best == null || candidates.isEmpty) return null;
  final first = m.bestFor(media)!;
  GravixRegionPick answer(GravixRegionUrl e, GravixRegionPickReason reason) =>
      GravixRegionPick(entry: e, reason: reason, media: media, skipped: skipped, mediaIgnored: ignored);
  GravixRegionUrl? offeredFor(GravixRegionMeasurement r) =>
      candidates.where((c) => c.url == r.url).firstOrNull ?? candidates.where((c) => c.region == r.region).firstOrNull;
  final order = [first, ...m.regions.where((r) => r.region != first.region)];
  GravixRegionMeasurement? pickedM;
  GravixRegionUrl? picked;
  for (final r in order) {
    if (!r.ok) continue;
    final offered = offeredFor(r);
    if (offered != null) {
      pickedM = r;
      picked = offered;
      break;
    }
  }
  if (picked == null || pickedM == null) return null;

  if (homeRegion != null && homeRegion.isNotEmpty) {
    final homeM = order.where((r) => r.ok && r.region == homeRegion).firstOrNull;
    final homeOffered = homeM == null ? null : offeredFor(homeM);
    if (homeM != null && homeOffered != null) {
      var fastest = homeM;
      for (final r in order) {
        if (r.ok && offeredFor(r) != null && r.rttMs! < fastest.rttMs!) fastest = r;
      }
      if (gravixHomeRegionWithinMargin(homeMs: homeM.rttMs!, fastestMs: fastest.rttMs!)) {
        return answer(homeOffered, GravixRegionPickReason.home);
      }
      return answer(picked, GravixRegionPickReason.measured);
    }
  }

  if (_normUrl(picked.url) == _normUrl(pinnedUrl)) return answer(picked, GravixRegionPickReason.measured);
  final pinnedM = m.regions.where((r) => r.ok && _normUrl(r.url) == _normUrl(pinnedUrl)).firstOrNull;
  final pinned = candidates.where((c) => _normUrl(c.url) == _normUrl(pinnedUrl)).firstOrNull;
  if (pinnedM == null || pinned == null) return answer(picked, GravixRegionPickReason.measured);
  final gain = pinnedM.rttMs! - pickedM.rttMs!;
  final needed = [
    GravixRegionDecisionCache.switchMinGain.inMilliseconds.toDouble(),
    pinnedM.rttMs! * GravixRegionDecisionCache.switchMinGainRatio,
  ].reduce((a, b) => a > b ? a : b);
  return gain > needed
      ? answer(picked, GravixRegionPickReason.measured)
      : answer(pinned, GravixRegionPickReason.pinned);
}

/// The measured regions as join candidates, for a connect whose token came with
/// no region list -- only when [connectUrl] is itself a measured region (a url
/// outside them, e.g. the app's own server, is never redirected). Else empty.
///
/// [media] (2026-10-27): [connectUrl] is a fleet region of the last
/// `/v1/regions` answer that was not measured (outside this caller's shortlist)
/// and does not allow [media] (doh1 audio-only, a video join): the candidates
/// are the measured regions plus the directory, so [gravixPickRegionFor] moves
/// the join to the best measured region allowing [media], else the first
/// shortlist region allowing it. No region allows [media]: empty (the token url
/// stays) and the log says why. A lookup, nothing sent. Field 2026-10-27: such a
/// video join stayed on doh1 and its camera publish was refused.
List<GravixRegionUrl> gravixMeasuredCandidates(String connectUrl, {DateTime? now, GravixRoomMedia? media}) {
  final m = gravixRegionMeasurement(now: now);
  String norm(String u) => u.replaceAll(RegExp(r'/+$'), '');
  if (m != null && m.regions.any((r) => norm(r.url) == norm(connectUrl))) {
    return [for (final r in m.regions) r.entry];
  }
  if (media == null) return const [];
  final dir = gravixLastRegionDirectory();
  final n = gravixNormalizeRegionUrl(connectUrl);
  final token = dir.where((c) => gravixNormalizeRegionUrl(c.url) == n).firstOrNull;
  if (token == null || gravixRegionAllowsMedia(token, media, now: now)) return const [];
  final why = '${token.region}(${gravixMediaSkipWhy(token, media, now: now)})';
  if (!dir.any((c) => gravixRegionAllowsMedia(c, media, now: now))) {
    GravixRegionLog.step('candidates', 'media=${media.name} pinned=$why kept cause=no-region-allows-${media.name}');
    return const [];
  }
  final out = <GravixRegionUrl>[for (final r in m?.regions ?? const <GravixRegionMeasurement>[]) r.entry];
  for (final c in dir) {
    if (!out.any((o) => o.region == c.region || norm(o.url) == norm(c.url))) out.add(c);
  }
  GravixRegionLog.step(
    'candidates',
    'media=${media.name} pinned=$why unmeasured -> directory+measured cause=media-not-allowed',
  );
  return out;
}

/// Measure now, then every [refresh] and whenever the network changes. Call once
/// when the app starts, e.g. with `https://<console host>/v1/regions`. Never throws.
class GravixRegionMeasurementHandle {
  GravixRegionMeasurementHandle._(this._run, this._timer, this._sub, this._onStop);
  final Future<GravixRegionMeasurementResult> Function() _run;
  final Timer? _timer;
  final StreamSubscription<Object?>? _sub;
  final void Function() _onStop;
  late final Future<GravixRegionMeasurementResult> ready;

  /// Measure again now.
  Future<GravixRegionMeasurementResult> refresh() => _run();

  /// Stop re-measuring. The last answer stays until its TTL.
  void stop() {
    _timer?.cancel();
    _sub?.cancel();
    _onStop();
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
  // A rival that won once (`confirming`) is measured again soon instead of at
  // the next refresh: joins move only after a second win, and that second run
  // should not be 5 minutes away when the held region really got worse.
  Timer? confirm;
  var stopped = false;
  Future<GravixRegionMeasurementResult> runAndConfirm() => run().then((r) {
    if (!stopped && r.selectReason == GravixRegionSelectReason.confirming && confirm == null) {
      confirm = Timer(kGravixRegionConfirmDelay, () {
        confirm = null;
        if (!stopped) runAndConfirm();
      });
    }
    return r;
  });
  final timer = refresh > Duration.zero ? Timer.periodic(refresh, (_) => runAndConfirm()) : null;
  StreamSubscription<Object?>? sub;
  if (watchNetwork) {
    try {
      sub = Connectivity().onConnectivityChanged.listen((_) => runAndConfirm());
    } catch (_) {
      // no connectivity plugin on this platform: the periodic refresh still runs
    }
  }
  final handle = GravixRegionMeasurementHandle._(runAndConfirm, timer, sub, () {
    stopped = true;
    confirm?.cancel();
  });
  handle.ready = runAndConfirm();
  return handle;
}

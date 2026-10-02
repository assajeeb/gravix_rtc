// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.
//
// Which regions the start-up measurement probes, and when it may stop: the pure
// half of gravix_init_measure.dart, rule for rule the React SDK's
// src/core/room/region/regionShortlist.ts (0.6.4). Both SDKs run
// test/fixtures/region_shortlist_cases.json; the same fixture must give the same
// choice.
//
// Why (owner, 2026-10-02): the fleet grows to 20-50 servers in 10-20 regions.
// Measuring every region from every phone at every start does not scale: 50
// regions x 3 samples is 150 requests, and on cellular the slow ones hold the
// answer for seconds. The gateway now answers `GET /v1/regions` with an optional
// `shortlist` (its geo/ASN guess, usually 3) and `probe_budget_ms`; old gateways
// send only `regions[]` and must keep working.
//
// Candidates:
// - shortlist present: the shortlist, plus the region joins use now when the
//   shortlist leaves it out (to know whether to keep it);
// - no shortlist, N <= [kGravixProbeAllMax]: every region (the old behaviour);
// - no shortlist, N > 6, `est_rtt_ms` known: the [kGravixEstProbeCount] lowest;
// - else, a cache for this network: its [kGravixExploreKnown] last-known-best plus
//   [kGravixExploreCount] others from a ROTATING cursor;
// - else every region (concurrency-capped; the budget decides how many finish).
//
// "2 random others" is a rotation, not a random draw: a cursor kept with the
// per-network cache walks the list, so every region is tried within N/2 runs and
// both SDKs pick the same regions from the same state (a random draw cannot be
// parity-tested).
import 'dart:convert';
import 'dart:math' as math;

import 'gravix_region_cache.dart';
import 'gravix_region_report.dart';

/// Without a shortlist, a list this short is measured whole.
const kGravixProbeAllMax = 6;

/// Without a shortlist, the regions with the lowest `est_rtt_ms` probed.
const kGravixEstProbeCount = 3;

/// Explore mode: last-known-best regions kept from the cache.
const kGravixExploreKnown = 2;

/// Explore mode: other regions tried per run, from the rotating cursor.
const kGravixExploreCount = 2;

/// Regions measured at the same time.
const kGravixMeasureConcurrency = 6;

/// Default total budget of one measurement on Wi-Fi / unknown networks.
const kGravixMeasureBudget = Duration(milliseconds: 1500);

/// Default total budget on cellular.
const kGravixMeasureBudgetCellular = Duration(milliseconds: 3000);

/// Why a region was probed. `cache` = the held / last-known-best region, probed so
/// the keep-current rule has a number for it. Wire names = [name].
enum GravixRegionCandidateSource { shortlist, est, explore, all, cache }

/// How the candidates were chosen. Wire names = [name].
enum GravixRegionPlanMode { shortlist, est, explore, all }

/// The gateway's `GET /v1/regions` answer. Old gateways send only `regions`.
class GravixRegionDirectory {
  const GravixRegionDirectory({required this.regions, this.shortlist, this.probeBudget, this.shortlistTtl});

  final List<GravixRegionUrl> regions;

  /// Region slugs to probe, best guess first.
  final List<String>? shortlist;

  /// Total measurement budget the gateway asks for (`probe_budget_ms`).
  final Duration? probeBudget;

  /// How long a measurement on this list is trusted (`shortlist_ttl_s`).
  final Duration? shortlistTtl;

  /// Parses `{ regions:[...], shortlist?, probe_budget_ms?, shortlist_ttl_s? }`;
  /// anything malformed is left out (an old gateway is just `regions`).
  factory GravixRegionDirectory.fromJson(Object? body) {
    final b = body is Map ? body : const <String, Object?>{};
    final list = b['regions'];
    final regions = <GravixRegionUrl>[
      if (list is List)
        for (final r in list)
          if (r is Map && r['region'] is String && r['url'] is String)
            GravixRegionUrl(
              region: r['region'] as String,
              url: r['url'] as String,
              probeUrl: r['probe_url'] is String ? r['probe_url'] as String : null,
              estRttMs: _nonNegative(r['est_rtt_ms']),
            ),
    ];
    final sl = b['shortlist'];
    final shortlist = sl is List
        ? [
            for (final s in sl)
              if (s is String && s.isNotEmpty) s,
          ]
        : const <String>[];
    final budget = _positive(b['probe_budget_ms']);
    final ttl = _positive(b['shortlist_ttl_s']);
    return GravixRegionDirectory(
      regions: regions,
      shortlist: shortlist.isEmpty ? null : shortlist,
      probeBudget: budget == null ? null : Duration(microseconds: (budget * 1000).round()),
      shortlistTtl: ttl == null ? null : Duration(milliseconds: (ttl * 1000).round()),
    );
  }

  Map<String, Object?> toJson() => {
    'regions': [
      for (final r in regions)
        {
          'region': r.region,
          'url': r.url,
          if (r.probeUrl != null) 'probe_url': r.probeUrl,
          if (r.estRttMs != null) 'est_rtt_ms': r.estRttMs,
        },
    ],
    if (shortlist != null) 'shortlist': shortlist,
    if (probeBudget != null) 'probe_budget_ms': probeBudget!.inMilliseconds,
    if (shortlistTtl != null) 'shortlist_ttl_s': shortlistTtl!.inSeconds,
  };
}

double? _nonNegative(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;
double? _positive(Object? v) => v is num && v.isFinite && v > 0 ? v.toDouble() : null;

/// What the per-network cache remembers between runs.
class GravixRegionPlanState {
  const GravixRegionPlanState({this.known = const [], this.cursor = 0});

  /// Last-known-best region slugs, fastest first.
  final List<String> known;

  /// Rotating exploration cursor.
  final int cursor;
}

class GravixPlannedCandidate {
  const GravixPlannedCandidate(this.entry, this.source);
  final GravixRegionUrl entry;
  final GravixRegionCandidateSource source;
}

class GravixRegionPlan {
  const GravixRegionPlan({required this.mode, required this.candidates, required this.cursor});
  final GravixRegionPlanMode mode;
  final List<GravixPlannedCandidate> candidates;

  /// The cursor the next run starts from (explore mode advances it).
  final int cursor;
}

/// First entry per region slug, in list order.
Map<String, GravixRegionUrl> _byRegion(List<GravixRegionUrl> regions) {
  final m = <String, GravixRegionUrl>{};
  for (final r in regions) {
    m.putIfAbsent(r.region, () => r);
  }
  return m;
}

/// The shortlist entries the list actually has, deduplicated, in shortlist order.
List<GravixRegionUrl> _shortlistEntries(GravixRegionDirectory dir) {
  final map = _byRegion(dir.regions);
  final seen = <String>{};
  return [
    for (final slug in dir.shortlist ?? const <String>[])
      if (map[slug] != null && seen.add(slug)) map[slug]!,
  ];
}

/// Regions with an `est_rtt_ms`, lowest first (list order breaks ties).
List<GravixRegionUrl> _byEst(List<GravixRegionUrl> regions) {
  final indexed = [
    for (var i = 0; i < regions.length; i++)
      if (regions[i].estRttMs != null) (r: regions[i], i: i),
  ];
  indexed.sort((a, b) {
    final c = a.r.estRttMs!.compareTo(b.r.estRttMs!);
    return c != 0 ? c : a.i.compareTo(b.i);
  });
  return [for (final x in indexed) x.r];
}

/// The regions to probe this run. Pure: same inputs, same plan, in both SDKs.
///
/// [currentRegion] -- the region joins use now (the cache's best, or the app's
/// pinned one) -- is added when the plan leaves it out and the list has it, with
/// source `cache`, so the keep-current rule compares against a fresh number
/// instead of switching blind.
GravixRegionPlan gravixPlanRegionCandidates(
  GravixRegionDirectory dir, {
  GravixRegionPlanState? state,
  String? currentRegion,
}) {
  final map = _byRegion(dir.regions);
  final regions = map.values.toList();
  var cursor = state?.cursor ?? 0;
  final candidates = <GravixPlannedCandidate>[];
  void add(GravixRegionUrl e, GravixRegionCandidateSource s) {
    if (!candidates.any((c) => c.entry.region == e.region)) candidates.add(GravixPlannedCandidate(e, s));
  }

  final GravixRegionPlanMode mode;
  final shortlist = _shortlistEntries(dir);
  final known = (state?.known ?? const <String>[]).where(map.containsKey).take(kGravixExploreKnown).toList();
  final est = _byEst(regions);
  if (shortlist.isNotEmpty) {
    mode = GravixRegionPlanMode.shortlist;
    for (final e in shortlist) {
      add(e, GravixRegionCandidateSource.shortlist);
    }
  } else if (regions.length <= kGravixProbeAllMax) {
    mode = GravixRegionPlanMode.all;
    for (final e in regions) {
      add(e, GravixRegionCandidateSource.all);
    }
  } else if (est.isNotEmpty) {
    mode = GravixRegionPlanMode.est;
    for (final e in est.take(kGravixEstProbeCount)) {
      add(e, GravixRegionCandidateSource.est);
    }
  } else if (known.isNotEmpty) {
    mode = GravixRegionPlanMode.explore;
    for (final s in known) {
      add(map[s]!, GravixRegionCandidateSource.cache);
    }
    final pool = regions.where((r) => !known.contains(r.region)).toList();
    if (pool.isNotEmpty) {
      final start = ((cursor % pool.length) + pool.length) % pool.length;
      final n = math.min(kGravixExploreCount, pool.length);
      for (var i = 0; i < n; i++) {
        add(pool[(start + i) % pool.length], GravixRegionCandidateSource.explore);
      }
      cursor = (start + n) % pool.length;
    }
  } else {
    mode = GravixRegionPlanMode.all;
    for (final e in regions) {
      add(e, GravixRegionCandidateSource.all);
    }
  }

  final cur = currentRegion == null ? null : map[currentRegion];
  if (cur != null) add(cur, GravixRegionCandidateSource.cache);
  return GravixRegionPlan(mode: mode, candidates: List.unmodifiable(candidates), cursor: cursor);
}

/// The keep-current margin against a region measured at [slowerMs]: the decision
/// cache's rule, max(30 ms, 20 %).
double gravixSwitchMargin(int slowerMs) => math.max(
  GravixRegionDecisionCache.switchMinGain.inMilliseconds.toDouble(),
  slowerMs * GravixRegionDecisionCache.switchMinGainRatio,
);

/// One candidate as the early-exit rule sees it.
class GravixMeasureProgress {
  const GravixMeasureProgress({required this.warm, required this.done});

  /// Warm samples so far (the cold first one excluded).
  final List<int> warm;

  /// Finished: failed, or out of samples.
  final bool done;
}

/// Early exit: every candidate has a warm sample (or is finished without one), at
/// least one has, and the best beats every other by the keep-rule margin -- the
/// remaining samples cannot change the choice, so they are not worth the wait.
bool gravixShouldStopMeasuring(List<GravixMeasureProgress> states) {
  int? best;
  for (final s in states) {
    if (s.warm.isEmpty) {
      if (!s.done) return false;
      continue;
    }
    final m = s.warm.reduce(math.min);
    if (best == null || m < best) best = m;
  }
  if (best == null) return false;
  var bestSeen = false;
  for (final s in states) {
    if (s.warm.isEmpty) continue;
    final m = s.warm.reduce(math.min);
    if (m == best && !bestSeen) {
      bestSeen = true;
      continue;
    }
    if (m - best <= gravixSwitchMargin(m)) return false;
  }
  return true;
}

/// When nothing was measured: `shortlist[0]`, else the lowest `est_rtt_ms`, else
/// null (the join keeps the token's region).
({GravixRegionUrl entry, GravixRegionCandidateSource source})? gravixFallbackRegion(GravixRegionDirectory dir) {
  final sl = _shortlistEntries(dir);
  if (sl.isNotEmpty) return (entry: sl.first, source: GravixRegionCandidateSource.shortlist);
  final est = _byEst(_byRegion(dir.regions).values.toList());
  if (est.isNotEmpty) return (entry: est.first, source: GravixRegionCandidateSource.est);
  return null;
}

/// The last-known-best list after a run: this run's answering regions fastest
/// first, then earlier ones this run did not probe (still unknown, not failed); a
/// region that failed this run is dropped.
List<String> gravixNextKnown(List<String> rankedOk, List<String> probed, List<String> previous) {
  final out = <String>[];
  for (final r in rankedOk) {
    if (!out.contains(r)) out.add(r);
  }
  for (final r in previous) {
    if (!out.contains(r) && !probed.contains(r)) out.add(r);
  }
  return out.take(kGravixExploreKnown).toList();
}

/// FNV-1a 32-bit, hex: hashes an SSID or carrier name into the cache key, so the
/// name itself is never stored. Same function in the React SDK.
String gravixHashNetworkId(String id) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(id)) {
    h ^= b;
    // h * 0x01000193 mod 2^32, split so it stays exact on the web (53-bit doubles).
    h = (h * 0x193 + ((h << 24) & 0xffffffff)) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// The per-network cache key: the network type, plus the hashed SSID / carrier
/// when the app knows it (`wifi:1a2b3c4d`).
String gravixRegionNetworkKey(String type, [String? id]) =>
    id == null || id.isEmpty ? type : '$type:${gravixHashNetworkId(id)}';

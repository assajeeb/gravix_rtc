// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart';

import '../rtc_core/src/core/engine.dart' show GravixRestartRegionStrategy;
import 'gravix_region_cache.dart';
import 'gravix_region_prober.dart';
import 'gravix_region_report.dart';

/// Re-probes the regions on a FULL reconnect (`regionReprobeOnRestart`).
///
/// The probe-race contract has always said a full reconnect re-probes. Until
/// 2026-09-19 this SDK did not: the engine re-joined whatever url the session
/// was on. A full reconnect is exactly when that answer is most likely stale,
/// either because the region failed or, more often, because the client's
/// network changed and the nearest edge changed with it.
///
/// The region the session was on is deliberately NOT penalised. The usual cause
/// of a full reconnect is the client's own network, not the region, and the
/// fresh race is the evidence: a healthy current region simply wins again. Same
/// rules as the JS SDK's `createProbeRestartStrategy`.
class GravixProbeRestartStrategy implements GravixRestartRegionStrategy {
  GravixProbeRestartStrategy({
    required this.pinnedUrl,
    required this.entries,
    required GravixRegionProber prober,
    GravixRegionDecisionCache? cache,
  }) : _prober = prober,
       _cache = cache;

  final String pinnedUrl;
  final List<GravixRegionUrl> entries;
  final GravixRegionProber _prober;

  /// When set, the fresh race is folded into the decision cache as a connect's
  /// race would be.
  final GravixRegionDecisionCache? _cache;

  List<String> _ladder = const [];

  @override
  Future<String?> getRestartUrl() async {
    _ladder = const [];
    // Fresh, never from the cache: whatever it holds was decided before
    // whatever just broke the session.
    final outcome = await _prober.raceEntries(entries, pinnedUrl: pinnedUrl);
    _cache?.record(pinnedUrl, outcome, candidates: entries);
    final winner = outcome.winner;
    _ladder = List.of(
      gravixRegionFallbackLadder(outcome: outcome, candidates: [for (final e in entries) e.url], pinnedUrl: pinnedUrl),
    );
    debugPrint('🌍 full reconnect re-probed: ${winner ?? 'no responder, keeping the current url'}');
    // No responder: keep the engine's current url rather than guess.
    return winner;
  }

  @override
  Future<String?> getNextUrl() async => _ladder.isEmpty ? null : _ladder.removeAt(0);
}

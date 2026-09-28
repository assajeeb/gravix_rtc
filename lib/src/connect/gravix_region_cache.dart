// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'gravix_region_prober.dart';
import 'gravix_region_report.dart';

/// One remembered region decision.
@immutable
class GravixRegionDecision {
  const GravixRegionDecision({required this.url, required this.region, required this.rtt, required this.decidedAt});

  final String url;
  final String region;
  final Duration rtt;
  final DateTime decidedAt;
}

/// Remembers which region won the probe race, so a repeat join does not pay for
/// the race again. A port of the JS SDK's `region/regionCache.ts`, with the same
/// constants and rules.
///
/// With `connect(regionProbe: true, regionDecisionCache: true)` a repeat join
/// connects to the remembered region IMMEDIATELY and the race runs in the
/// background to keep the memory fresh. The background race never delays, and
/// cannot fail, the join it was started from.
///
/// In memory and per process, deliberately: no storage dependency, nothing to
/// migrate, nothing personal persisted. Keyed by the pinned url, which
/// identifies the gateway's answer for this deployment.
///
/// One difference from JS, and why: this SDK's race decides at the first
/// responder (plus the 15ms pinned window), so a slower region's probe may still
/// be in flight when the outcome is recorded. If the REMEMBERED region is one of
/// those, its current RTT is unknown. The memory keeps it but does not refresh
/// its timestamp, so it ages out at [ttl] and a full race decides again. JS
/// waits for every probe and never has this case.
class GravixRegionDecisionCache {
  GravixRegionDecisionCache({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The process-wide cache [GravixRoomService] uses unless given another.
  static final GravixRegionDecisionCache shared = GravixRegionDecisionCache();

  /// How long a decision is trusted. Long enough to cover a session's rejoins,
  /// short enough that a user who moved networks is re-raced soon after.
  static const ttl = Duration(minutes: 10);

  /// A rival must beat the remembered region by MORE than the larger of these:
  /// an absolute floor, and a fraction of the remembered region's RTT. The 15ms
  /// in-connect tie-break only protects the pinned region, and gives no
  /// stickiness from one connect to the next; without this, two edges a few ms
  /// apart trade places on noise and the user moves between regions join to join.
  static const switchMinGain = Duration(milliseconds: 30);
  static const switchMinGainRatio = 0.2;

  /// How long a region that refused a connection is kept out of the memory.
  ///
  /// A refusing region usually still PASSES its probe: the probe is HTTPS to the
  /// edge, and the refusal comes from the WebSocket behind it (load balancer up,
  /// SFU draining). Without this, the background race would put it straight back
  /// moments after it was forgotten, and every repeat join would pay a failed
  /// connection attempt before the ladder rescued it. Short, because a drain ends.
  static const refusalPenalty = Duration(minutes: 2);

  final DateTime Function() _now;
  final Map<String, GravixRegionDecision> _decisions = {};

  /// pinnedUrl -> (refused url -> penalised until)
  final Map<String, Map<String, DateTime>> _penalties = {};

  bool _isPenalised(String pinnedUrl, String url, DateTime now) {
    final until = _penalties[pinnedUrl]?[url];
    return until != null && now.isBefore(until);
  }

  /// The remembered decision for this gateway pin, if it is fresh and the
  /// gateway still offers that region. The pinned url always counts as offered.
  GravixRegionDecision? read(String pinnedUrl, List<String> offeredUrls) {
    final decision = _decisions[pinnedUrl];
    if (decision == null) return null;
    if (_now().difference(decision.decidedAt) > ttl) {
      _decisions.remove(pinnedUrl);
      return null;
    }
    final stillOffered = decision.url == pinnedUrl || offeredUrls.contains(decision.url);
    return stillOffered ? decision : null;
  }

  /// Folds a finished race into the memory, with hysteresis: the remembered
  /// region keeps its place unless it stopped answering or the new winner is
  /// clearly better. A race nobody answered carries no information and is not
  /// recorded.
  void record(String pinnedUrl, GravixRegionRaceOutcome outcome, {required List<GravixRegionUrl> candidates}) {
    if (outcome.winner == null) return;
    final now = _now();
    String regionOf(String url) => candidates
        .firstWhere(
          (c) => c.url == url,
          orElse: () => GravixRegionUrl(region: kGravixUnknownRegion, url: url),
        )
        .region;

    // The race's own choice, unless that region recently refused a connection,
    // in which case the fastest responder that has NOT refused is the one worth
    // remembering.
    final usable = [
      for (final r in outcome.results)
        if (r.ok && !_isPenalised(pinnedUrl, r.url, now)) r,
    ]..sort((a, b) => a.elapsed.compareTo(b.elapsed));
    if (usable.isEmpty) return;
    final winner = usable.firstWhere((r) => r.url == outcome.winner, orElse: () => usable.first);
    final fresh = GravixRegionDecision(
      url: winner.url,
      region: regionOf(winner.url),
      rtt: winner.elapsed,
      decidedAt: now,
    );

    final held = _decisions[pinnedUrl];
    if (held != null && held.url != fresh.url) {
      final heldNow = outcome.results.where((r) => r.url == held.url).firstOrNull;
      if (heldNow == null) {
        // Still in flight when the race decided: slower than the winner by an
        // unknown amount. Keep it, unrefreshed, so the TTL settles it (see the
        // class comment).
        return;
      }
      if (heldNow.ok) {
        final neededMs = math.max(
          switchMinGain.inMilliseconds.toDouble(),
          heldNow.elapsed.inMilliseconds * switchMinGainRatio,
        );
        if ((heldNow.elapsed - fresh.rtt).inMilliseconds <= neededMs) {
          // Not clearly better: stay, but refresh the remembered region's numbers.
          _decisions[pinnedUrl] = GravixRegionDecision(
            url: held.url,
            region: held.region,
            rtt: heldNow.elapsed,
            decidedAt: now,
          );
          return;
        }
      }
    }
    _decisions[pinnedUrl] = fresh;
  }

  /// A region refused a connection: drop the memory for this pin and, when the
  /// refusing url is given, keep it out of the memory for [refusalPenalty].
  void forget(String pinnedUrl, {String? refusedUrl}) {
    _decisions.remove(pinnedUrl);
    if (refusedUrl != null) {
      (_penalties[pinnedUrl] ??= {})[refusedUrl] = _now().add(refusalPenalty);
    }
  }

  /// Remember the region a join actually LANDED on after the ladder rescued it.
  /// A WebSocket that connected is better evidence than any probe, so it is
  /// recorded directly rather than waiting for a race to agree.
  void recordLanded(String pinnedUrl, {required String url, required String region, Duration? rtt}) {
    _decisions[pinnedUrl] = GravixRegionDecision(
      url: url,
      region: region,
      rtt: rtt ?? Duration.zero,
      decidedAt: _now(),
    );
  }

  /// Empty the memory and the penalties.
  void clear() {
    _decisions.clear();
    _penalties.clear();
  }
}

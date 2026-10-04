// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.
//
// Which measured region joins use: the pure half of the start-up measurement's
// decision, rule for rule the React SDK's src/core/room/region/regionSelection.ts.
// Both SDKs run test/fixtures/region_selection_cases.json; the same fixture must
// give the same choice.
//
// Why (field test 2026-10-04, owner's phone in Bangladesh): sgp1 and blr1 measure
// within a few ms of each other from there. Four sessions in 15 minutes went
// blr1, sgp1, sgp1, blr1, and one audio room ended up cross-region (host sgp1,
// viewer blr1, 2.9-3.4 % loss on the relay leg). The keep-current rule existed,
// but it had nothing to keep:
//   - the region in use was only remembered while the per-network answer was
//     fresh (10 min). After that, every measurement picked the plain fastest, so
//     noise of a few ms moved the user;
//   - one measurement was enough to move, so one noisy run (a cold radio, a
//     sample cut by the budget) moved the user too.
//
// Now the last good region is an ANCHOR, kept per network for
// [kGravixRegionAnchorLife] (hours, not the 10-minute answer TTL), and a rival
// must beat it by the keep-current margin (max(30 ms, 20 %), the decision cache's
// rule) in [kGravixRegionConfirmRuns] CONSECUTIVE measurements before joins move.
// Only a failed anchor (it answered with an error / not at all) moves at once.
//
// The home-region rule ([gravixHomeRegionWithinMargin]) is the viewer side of
// the same problem: a viewer that picks its own fastest region while the host is
// on another one a few ms slower pays a relay hop (latency, a server hop, relay
// bandwidth, and that leg's loss) for nothing.
import 'dart:math' as math;

import 'gravix_region_cache.dart';

/// How long the last good region is kept as the anchor for a network, measured or
/// not. The answer TTL (`shortlist_ttl_s`, 10 min) only decides whether a start-up
/// may use the cached answer before measuring; the anchor decides what a new
/// measurement must beat.
const kGravixRegionAnchorLife = Duration(hours: 12);

/// Consecutive measurements a rival must win (by the keep-current margin) before
/// joins move to it.
const kGravixRegionConfirmRuns = 2;

/// After a measurement in which a rival won once, measure again this soon, so a
/// genuinely better region (or a degraded anchor) is confirmed in seconds rather
/// than at the next 5-minute refresh.
const kGravixRegionConfirmDelay = Duration(seconds: 20);

/// The home-region margin: a viewer joins the room's home region when its RTT is
/// at most this much above the fastest region's -- the larger of an absolute
/// floor and a fraction of the fastest region's RTT.
const kGravixHomeRegionMarginMin = Duration(milliseconds: 25);
const kGravixHomeRegionMarginRatio = 0.3;

/// One measured region as the selection sees it. [status] = `ok` | `failed` |
/// `unmeasured` (the measurement's wire names).
class GravixRegionSample {
  const GravixRegionSample({required this.region, required this.status, this.rttMs});
  final String region;
  final String status;
  final int? rttMs;
  bool get ok => status == 'ok' && rttMs != null;
}

/// A rival that beat the anchor by the margin in [wins] consecutive measurements.
class GravixRegionChallenger {
  const GravixRegionChallenger(this.region, this.wins);
  final String region;
  final int wins;

  Map<String, Object?> toJson() => {'region': region, 'wins': wins};

  static GravixRegionChallenger? fromJson(Object? o) => o is Map && o['region'] is String && o['wins'] is int
      ? GravixRegionChallenger(o['region'] as String, o['wins'] as int)
      : null;
}

/// Why [GravixRegionSelection.region] was chosen. Wire names = [name].
///
/// - `fastest`: no anchor (or the anchor is the fastest);
/// - `kept`: the anchor, within the margin of the fastest;
/// - `confirming`: the anchor, although a rival beat it by the margin (or the
///   anchor got no answer within the budget) -- not yet in enough consecutive runs;
/// - `switched`: the rival won its confirming run;
/// - `anchorFailed`: the anchor failed, the fastest at once;
/// - `anchorGone`: the anchor was not measured this run at all (no longer listed).
enum GravixRegionSelectReason { fastest, kept, confirming, switched, anchorFailed, anchorGone }

class GravixRegionSelection {
  const GravixRegionSelection({required this.region, required this.reason, this.challenger});

  /// The region joins should use.
  final String region;
  final GravixRegionSelectReason reason;

  /// The challenger state to keep for the next measurement (null = none).
  final GravixRegionChallenger? challenger;
}

/// The keep-current margin against an anchor measured at [anchorMs]: max(30 ms,
/// 20 %), the decision cache's rule.
double gravixAnchorMargin(int anchorMs) => math.max(
  GravixRegionDecisionCache.switchMinGain.inMilliseconds.toDouble(),
  anchorMs * GravixRegionDecisionCache.switchMinGainRatio,
);

/// Picks the region joins use from one measurement, with hysteresis. Pure: same
/// inputs, same answer, in both SDKs. Null when no region measured `ok` (the
/// caller falls back to the gateway's guess).
///
/// [anchor]: the last good region for this network (null = none).
/// [challenger]: the rival state from the previous measurement on this network.
///
/// Rules:
/// 1. no `ok` region: null, challenger unchanged (a run with no evidence neither
///    confirms nor resets anything);
/// 2. no anchor, or the anchor is the fastest: the fastest, challenger cleared;
/// 3. the anchor not among the samples: the fastest (`anchorGone`);
/// 4. the anchor `failed`: the fastest at once (`anchorFailed`);
/// 5. the anchor `ok` and the fastest beats it by no more than the margin: the
///    anchor (`kept`), challenger cleared;
/// 6. otherwise (beaten by more than the margin, or the anchor `unmeasured`: the
///    rival answered within the budget and the anchor did not) the fastest gets a
///    vote -- one more if it is the same challenger as last time, else its first.
///    At [kGravixRegionConfirmRuns] votes: the fastest (`switched`); before that:
///    the anchor (`confirming`) -- when [anchorKnown] says the caller can still
///    use it (an `unmeasured` anchor needs a last-known RTT), else the fastest.
GravixRegionSelection? gravixSelectRegion(
  List<GravixRegionSample> samples, {
  String? anchor,
  GravixRegionChallenger? challenger,
  bool anchorKnown = true,
}) {
  GravixRegionSample? fastest;
  for (final s in samples) {
    if (s.ok && (fastest == null || s.rttMs! < fastest.rttMs!)) fastest = s;
  }
  if (fastest == null) return null;
  if (anchor == null || anchor == fastest.region) {
    return GravixRegionSelection(region: fastest.region, reason: GravixRegionSelectReason.fastest);
  }
  final a = samples.where((s) => s.region == anchor).firstOrNull;
  if (a == null) return GravixRegionSelection(region: fastest.region, reason: GravixRegionSelectReason.anchorGone);
  if (a.status == 'failed') {
    return GravixRegionSelection(region: fastest.region, reason: GravixRegionSelectReason.anchorFailed);
  }
  if (a.ok && a.rttMs! - fastest.rttMs! <= gravixAnchorMargin(a.rttMs!)) {
    return GravixRegionSelection(region: anchor, reason: GravixRegionSelectReason.kept);
  }
  final wins = challenger != null && challenger.region == fastest.region ? challenger.wins + 1 : 1;
  if (wins >= kGravixRegionConfirmRuns) {
    return GravixRegionSelection(region: fastest.region, reason: GravixRegionSelectReason.switched);
  }
  if (!a.ok && !anchorKnown) {
    return GravixRegionSelection(region: fastest.region, reason: GravixRegionSelectReason.anchorFailed);
  }
  return GravixRegionSelection(
    region: anchor,
    reason: GravixRegionSelectReason.confirming,
    challenger: GravixRegionChallenger(fastest.region, wins),
  );
}

/// The home-region margin against the fastest region at [fastestMs]:
/// max(25 ms, 30 %).
double gravixHomeRegionMargin(int fastestMs) =>
    math.max(kGravixHomeRegionMarginMin.inMilliseconds.toDouble(), fastestMs * kGravixHomeRegionMarginRatio);

/// True when the room's home region, measured at [homeMs], is close enough to the
/// fastest region ([fastestMs]) that a viewer should join it instead and skip the
/// relay hop.
bool gravixHomeRegionWithinMargin({required int homeMs, required int fastestMs}) =>
    homeMs - fastestMs <= gravixHomeRegionMargin(fastestMs);

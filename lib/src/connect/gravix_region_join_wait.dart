// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.
//
// 0.9.0 (2026-11-08): a join waits, briefly, for the start-up region measurement.
//
// Field, Tuki app: a viewer in Doha joining a room whose home is dac1 (Dhaka)
// landed on dac1 at ~320 ms instead of doh1 (~20 ms). The app had called
// gravixStartRegionMeasurement at start, but the join's url lookup is a lookup
// only: with the run still in flight nothing was measured, and the token's url
// (the home region) stayed for the whole call.
//
// Now a join with nothing fresh measured for this network waits for the run in
// flight (or kicks one) for at most [kGravixJoinMeasureWait]; then, still with
// nothing measured, the gateway's `est_rtt_ms` decides between home and the best
// estimated region (gravixEstFallbackPick). The wait never throws and never
// fails a join. A join that still landed unmeasured kicks a refresh
// ([gravixRefreshAfterJoin]), so the in-session latency move (Room,
// RoomOptions.recovery.latencyRegionMove) can correct it within seconds.
import 'dart:async';

import 'gravix_init_measure.dart';
import 'gravix_region_failover.dart' show gravixNormalizeRegionUrl;
import 'gravix_region_media.dart';
import 'gravix_region_report.dart';
import 'gravix_region_selection.dart';

/// How long a join waits for the region measurement when nothing fresh is
/// measured for this network.
///
/// Why 800 ms: the tap-to-audio target is ~1-1.5 s, and a wrong region costs the
/// whole call (Doha -> dac1: +300 ms RTT for every word). The run's own budget is
/// longer on purpose (1.5 s Wi-Fi / 3 s cellular, for a cold TLS handshake on a
/// bad link): this bound is not meant to see every run to its end. A run whose
/// best clearly wins stops early (usually well inside 800 ms on Wi-Fi), the
/// region directory is in hand once its fetch answered (before any sample), so
/// a join that stops waiting still has `est_rtt_ms` for its fallback, and the
/// latency move corrects what is left.
const kGravixJoinMeasureWait = Duration(milliseconds: 800);

/// A run ended less than this long ago is not re-run by a join (the gateway
/// down, every card tap would start a run: a probe storm), nor by a refresh
/// after a join ([gravixRefreshAfterJoin]).
const kGravixRegionRefreshMinAge = Duration(seconds: 30);

/// What the join's wait found and did.
class GravixJoinMeasureWait {
  const GravixJoinMeasureWait({required this.before, this.waited = Duration.zero, this.kicked = false, this.skipped});

  /// The state before the wait: `fresh`, `no-handle`, `no-measurement`, `stale`
  /// or `failed`.
  final String before;

  /// How long the join waited.
  final Duration waited;

  /// The join started the run it waited for.
  final bool kicked;

  /// Why nothing was waited for although nothing was measured (e.g.
  /// `refresh-skipped age=4s`).
  final String? skipped;

  /// The log's cause: the state, then the wait.
  String get cause =>
      'cause=$before'
      '${waited > Duration.zero || kicked ? ' waited=${waited.inMilliseconds}ms${kicked ? ' kicked' : ''}' : ''}'
      '${skipped == null ? '' : ' $skipped'}';
}

/// The measurement's state for a join now: `fresh` (a fresh answer measured
/// `ok`), `stale` (an answer past its TTL), `failed` (an answer with nothing
/// measured: an error, or only the gateway's guess), `no-measurement`.
String gravixJoinMeasureState({DateTime? now}) {
  final m = gravixRegionMeasurement(now: now);
  if (m != null) return m.best?.ok ?? false ? 'fresh' : 'failed';
  return gravixHeldRegionMeasurement() != null ? 'stale' : 'no-measurement';
}

/// Waits for the start-up / refresh run when nothing fresh is measured, at most
/// [bound]. With no run in flight (and the last one ended at least
/// [refreshMinAge] ago) it starts one. No handle registered: returns at once.
/// Never throws.
Future<GravixJoinMeasureWait> gravixAwaitRegionForJoin({
  Duration bound = kGravixJoinMeasureWait,
  Duration refreshMinAge = kGravixRegionRefreshMinAge,
}) async {
  try {
    final handle = gravixActiveRegionMeasurement();
    if (handle == null) return const GravixJoinMeasureWait(before: 'no-handle');
    final before = gravixJoinMeasureState();
    if (before == 'fresh') return GravixJoinMeasureWait(before: before);
    var run = handle.inFlight;
    var kicked = false;
    if (run == null) {
      final last = handle.lastRunEndedAt;
      final age = last == null ? null : DateTime.now().difference(last);
      if (age != null && age < refreshMinAge) {
        return GravixJoinMeasureWait(before: before, skipped: 'refresh-skipped age=${age.inSeconds}s');
      }
      run = handle.refresh();
      kicked = true;
    }
    if (bound <= Duration.zero) return GravixJoinMeasureWait(before: before, kicked: kicked);
    final watch = Stopwatch()..start();
    try {
      await run.timeout(bound);
    } catch (_) {
      // the bound, or the run's own failure: the join goes on with what there is
    }
    return GravixJoinMeasureWait(before: before, waited: watch.elapsed, kicked: kicked);
  } catch (_) {
    return const GravixJoinMeasureWait(before: 'error');
  }
}

/// The est fallback for a join with [homeRegion] and nothing measured: the region
/// to dial instead of [pinnedUrl], with the pick, or null (the token url stays).
///
/// Only when [pinnedUrl] is a fleet url of the last `/v1/regions` answer (a url
/// outside it, e.g. the app's own server, is never redirected). The dialled entry
/// is the [candidates]' (the token's region list) when it has one for the region,
/// else the directory's; with a non-empty [candidates] lacking the region, null.
({GravixRegionUrl entry, GravixEstPick pick})? gravixEstJoinRegion(
  String pinnedUrl,
  List<GravixRegionUrl> candidates, {
  required String? homeRegion,
  GravixRoomMedia? media,
  DateTime? now,
}) {
  if (homeRegion == null || homeRegion.isEmpty) return null;
  final dir = gravixLastRegionDirectory();
  if (dir.isEmpty) return null;
  final n = gravixNormalizeRegionUrl(pinnedUrl);
  if (!dir.any((e) => gravixNormalizeRegionUrl(e.url) == n)) return null;
  final pick = gravixEstFallbackPick(
    [
      for (final e in dir)
        GravixEstRegion(
          region: e.region,
          estRttMs: e.estRttMs,
          allowsMedia: media == null || gravixRegionAllowsMedia(e, media, now: now),
        ),
    ],
    homeRegion: homeRegion,
    shortlist: gravixLastRegionShortlist(),
  );
  if (pick == null) return null;
  final offered = candidates.where((c) => c.region == pick.region).firstOrNull;
  if (offered == null && candidates.isNotEmpty) return null;
  final entry = offered ?? dir.firstWhere((e) => e.region == pick.region);
  return (entry: entry, pick: pick);
}

/// Step 4 of 0.9.0: a join that landed with a url NOT from a fresh measurement
/// ([unmeasured]: the token's, an estimate, a fallback) kicks a measurement
/// refresh when a handle is registered, no run is in flight, and the last one
/// ended at least [kGravixRegionRefreshMinAge] ago -- so the latency move can
/// act after the confirm delay (~20 s) instead of the next 5-minute refresh.
/// True when it kicked one. Never throws.
///
/// [minAge]: the floor (a latency move that just landed passes Duration.zero:
/// the run that moved it ended seconds ago).
bool gravixRefreshAfter(String cause, {DateTime? now, Duration minAge = kGravixRegionRefreshMinAge}) {
  try {
    final handle = gravixActiveRegionMeasurement();
    if (handle == null || handle.inFlight != null) return false;
    final last = handle.lastRunEndedAt;
    if (last != null && (now ?? DateTime.now()).difference(last) < minAge) return false;
    GravixRegionLog.step('refresh', 'cause=$cause');
    unawaited(handle.refresh().then((_) {}, onError: (Object _) {}));
    return true;
  } catch (_) {
    return false;
  }
}

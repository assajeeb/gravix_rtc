// Copyright (c) 2026 Gravity Compile. Apache 2.0.
//
// Region failover and the connected region (0.4.15, field 2026-10-09).
//
// Pakhi, a viewer in Bangladesh: the session failed over from blr1 to doh1
// (284 ms) because the vendored core's cloud failover dialled the first untried
// entry of the SFU's `/settings/regions` -- the other regions in configuration
// order, which knows nothing about latency. sgp1 (~61 ms) was up. And the app's
// server chip kept saying blr1, because it showed the url the app had passed.
//
// [gravixOrderFailoverRegions] puts the measured regions first, nearest first,
// with the console's near-only cap; [gravixRegionOfUrl] names the region of a
// url from what the SDK knows (a region list, the start-up measurement).
import 'gravix_init_measure.dart';
import 'gravix_region_media.dart';
import 'gravix_region_report.dart';

/// Normalised for comparison: scheme folded to ws/wss, host lower-cased,
/// trailing slashes dropped.
String gravixNormalizeRegionUrl(String url) {
  var u = url.trim().replaceAll(RegExp(r'/+$'), '');
  final i = u.indexOf('://');
  if (i > 0) {
    var scheme = u.substring(0, i).toLowerCase();
    if (scheme == 'https') scheme = 'wss';
    if (scheme == 'http') scheme = 'ws';
    final rest = u.substring(i + 3);
    final slash = rest.indexOf('/');
    final host = (slash < 0 ? rest : rest.substring(0, slash)).toLowerCase();
    u = '$scheme://$host${slash < 0 ? '' : rest.substring(slash)}';
  }
  return u;
}

/// The region slug of [url]: from [known] (a region list, the server's
/// `/settings/regions`) first, else from the fresh start-up measurement. Null
/// when neither has it, or it is [kGravixUnknownRegion].
String? gravixRegionOfUrl(String? url, {Iterable<GravixRegionUrl> known = const [], DateTime? now}) {
  if (url == null || url.isEmpty) return null;
  final n = gravixNormalizeRegionUrl(url);
  String? valid(String? r) => r == null || r.isEmpty || r == kGravixUnknownRegion ? null : r;
  for (final e in known) {
    if (gravixNormalizeRegionUrl(e.url) == n && valid(e.region) != null) return e.region;
  }
  final m = gravixRegionMeasurement(now: now);
  if (m != null) {
    for (final r in m.regions) {
      if (gravixNormalizeRegionUrl(r.url) == n && valid(r.region) != null) return r.region;
    }
  }
  return null;
}

/// The near-only cap of the console's shortlist (gravix-tools, C4): a region
/// measured slower than max(2 x best, best + 100 ms) is not "near".
int gravixNearOnlyCapMs(int bestMs) {
  final a = bestMs * 2;
  final b = bestMs + 100;
  return a > b ? a : b;
}

/// Orders the failover [candidates] (the server's `/settings/regions` entries,
/// in the server's order) by the fresh start-up measurement:
///  1. measured `ok` and near -- RTT within [gravixNearOnlyCapMs] of the best
///     remaining measured candidate -- fastest first;
///  2. the other candidates the measurement has no RTT for (unmeasured, or not
///     in it), in the server's order;
///  3. measured `ok` but far, fastest first; then the ones whose measurement
///     failed, in the server's order.
/// The server's list stays the last resort: nothing is dropped, only ordered.
/// No fresh measurement, or none of the candidates in it: [candidates] as given.
///
/// "Best remaining" because the region that just failed (usually the best
/// measured one) is not a candidate any more: the cap is taken against the best
/// of the regions still on offer.
///
/// [media] (2026-10-21, per-region media): the candidates that do not take it
/// (an audio-only region for a video join, or one that refused it lately) go
/// after all the others, in the same order -- last resort, never dropped.
List<T> gravixOrderFailoverRegions<T>(
  List<T> candidates, {
  required String Function(T) regionOf,
  required String Function(T) urlOf,
  DateTime? now,
  GravixRoomMedia? media,
}) {
  if (media == null) return _orderByMeasurement(candidates, regionOf: regionOf, urlOf: urlOf, now: now);
  bool allows(T c) => gravixRegionAllowsMedia(
    GravixRegionUrl(region: regionOf(c), url: urlOf(c)),
    media,
    now: now,
  );
  final ordered = _orderByMeasurement(candidates, regionOf: regionOf, urlOf: urlOf, now: now);
  final ok = ordered.where(allows).toList();
  final last = ordered.where((c) => !allows(c)).toList();
  if (last.isNotEmpty && ok.isNotEmpty) {
    GravixRegionLog.step(
      'failoverOrder',
      'media=${media.name} last=${last.map(regionOf).join(',')} first=${ok.map(regionOf).join(',')}',
    );
  }
  return [...ok, ...last];
}

List<T> _orderByMeasurement<T>(
  List<T> candidates, {
  required String Function(T) regionOf,
  required String Function(T) urlOf,
  DateTime? now,
}) {
  final m = gravixRegionMeasurement(now: now);
  if (m == null || candidates.isEmpty) return candidates;
  GravixRegionMeasurement? measured(T c) {
    final n = gravixNormalizeRegionUrl(urlOf(c));
    final region = regionOf(c);
    for (final r in m.regions) {
      if (region.isNotEmpty && r.region == region) return r;
    }
    for (final r in m.regions) {
      if (gravixNormalizeRegionUrl(r.url) == n) return r;
    }
    return null;
  }

  final ok = <(T, int)>[];
  final unknown = <T>[];
  final failed = <T>[];
  for (final c in candidates) {
    final r = measured(c);
    if (r == null || r.state == GravixRegionMeasurementStatus.unmeasured) {
      unknown.add(c);
    } else if (r.ok) {
      ok.add((c, r.rttMs!));
    } else {
      failed.add(c);
    }
  }
  if (ok.isEmpty) return candidates;
  ok.sort((a, b) => a.$2.compareTo(b.$2));
  final cap = gravixNearOnlyCapMs(ok.first.$2);
  final near = [
    for (final e in ok)
      if (e.$2 <= cap) e.$1,
  ];
  final far = [
    for (final e in ok)
      if (e.$2 > cap) e.$1,
  ];
  return [...near, ...unknown, ...far, ...failed];
}

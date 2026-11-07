// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Which url a join dials (0.4.19, fast join; moved from the apps). A lookup on
// the start-up region measurement (gravixStartRegionMeasurement), never a probe
// on the tap path.

import 'package:flutter/foundation.dart';

import '../backend/gravix_token_provider.dart';
import '../connect/gravix_init_measure.dart';
import '../connect/gravix_region_join_wait.dart';
import '../connect/gravix_region_failover.dart' show gravixRegionOfUrl;
import '../connect/gravix_region_media.dart';
import '../connect/gravix_region_report.dart' show GravixRegionUrl;
import 'gravix_join_log.dart';

/// Where a [GravixJoinUrlChoice] came from.
enum GravixJoinUrlSource {
  /// The region the measurement holds (or the fastest measured one the token offers).
  measured,

  /// The room's home region (a viewer / guest in someone else's room), within the
  /// home margin of the fastest region.
  home,

  /// The token's own url: no measurement yet, or a url outside the measured fleet.
  token,

  /// A standby already open in another of the token's regions ([GravixJoinUrlChoice.withStandby]).
  standby,

  /// 0.9.0: nothing measured after the join's wait ([gravixJoinUrlAsync]): the region the
  /// gateway's `est_rtt_ms` favours over the room's home region (or the home, within the
  /// home margin of the best estimate).
  est,
}

/// The url a join dials, and why.
@immutable
class GravixJoinUrlChoice {
  const GravixJoinUrlChoice({
    required this.url,
    required this.source,
    this.region,
    this.rttMs,
    this.homeRegion,
    this.media,
    this.cause,
  });

  final String url;
  final GravixJoinUrlSource source;

  /// The region slug, when known.
  final String? region;

  /// The measured round trip to [region], when measured.
  final int? rttMs;

  /// The room's home region the token named (viewers), if any.
  final String? homeRegion;

  /// The join's media (2026-10-21): the url allows it (unless no region does).
  final GravixRoomMedia? media;

  /// 0.9.0: what the join's wait found ([gravixJoinUrlAsync]: `cause=no-measurement
  /// waited=412ms`, `cause=fresh`, ...). Null from the sync [gravixJoinUrl].
  final String? cause;

  /// This choice once a standby pre-connect is taken into account. A standby
  /// for this token, open at [standbyUrl] in another region while nothing is
  /// open at [url], beats a re-pick between warm-up and tap (field 2026-10-04:
  /// the start-up measurement flipped between two close regions in between and
  /// the join paid a cold WebSocket) -- EXCEPT for a home-region pick: that pick
  /// keeps host and viewer on one server, and dialling the standby's region
  /// instead would put the viewer back on the relayed path the home region
  /// avoids (2.9-3.4 % relay-leg loss measured that day). A cold WebSocket
  /// (~0.5-1 s, once) is the cheaper loss than a relayed session.
  ///
  /// 0.9.0: an [GravixJoinUrlSource.est] pick is kept too, for the same trade: the warm ran
  /// before anything was measured and opened its standby at the token's url (Tuki: the home,
  /// dac1, ~300 ms from a Doha viewer), and a cold WebSocket once is cheaper than that for the
  /// whole call.
  GravixJoinUrlChoice withStandby({required String? standbyUrl, required bool pickedOpen, required bool standbyOpen}) {
    if (source == GravixJoinUrlSource.home || source == GravixJoinUrlSource.est) return this;
    if (standbyUrl == null || standbyUrl == url || pickedOpen || !standbyOpen) return this;
    // 2026-10-21: a standby opened by an audio warm at an audio-only region
    // (doh1) must not take a video join there.
    final m = media;
    if (m != null) {
      final region = gravixRegionOfUrl(standbyUrl, known: gravixLastRegionDirectory());
      if (region != null && !gravixRegionAllowsMedia(GravixRegionUrl(region: region, url: standbyUrl), m)) {
        GravixRegionLog.step(
          'standbySkip',
          'media=${m.name} standby=$region(${gravixMediaSkipWhy(GravixRegionUrl(region: region, url: standbyUrl), m)}) keep=${this.region ?? '?'}',
        );
        return this;
      }
    }
    return GravixJoinUrlChoice(url: standbyUrl, source: GravixJoinUrlSource.standby, media: media, cause: cause);
  }

  @override
  String toString() =>
      'GravixJoinUrlChoice(${region ?? '?'} ${rttMs ?? '?'}ms via=${source.name}'
      '${homeRegion == null ? '' : ' home=$homeRegion'})';
}

/// The url a join with [credentials] dials:
///  - a viewer whose token names the room's home region joins it when it
///    measures within max(25 ms, 30 %) of the fastest region (field 2026-10-04:
///    a viewer joined another region than its host a few ms away and the relay
///    leg lost 2.9-3.4 %), its own pick otherwise (the room is relayed to it);
///  - everyone else joins the region the measurement holds: the token's url is
///    not an anchor (for a host's own token it is just the region list's first);
///  - the candidates are the token's region list, else the measured regions when
///    the token's url is one of them; a url outside the measured fleet is never
///    redirected;
///  - no measurement yet: the token's url;
///  - [media] (2026-10-21): only regions that allow it (gravix_region_media.dart);
///    a token url on a region that does not is replaced by the best measured
///    region that does, else the first shortlist region that does, even with
///    nothing measured -- also when that url itself was not measured (2026-10-27,
///    [gravixMeasuredCandidates]). No region allows it: the token url. Null: no
///    filter.
///
/// A lookup: it never waits for a measurement in flight. A join uses [gravixJoinUrlAsync].
GravixJoinUrlChoice gravixJoinUrl(GravixJoinCredentials credentials, {DateTime? now, GravixRoomMedia? media}) =>
    _joinUrl(credentials, now: now, media: media).choice;

({GravixJoinUrlChoice choice, List<String> skipped, bool mediaIgnored}) _joinUrl(
  GravixJoinCredentials credentials, {
  DateTime? now,
  GravixRoomMedia? media,
  bool log = true,
}) {
  final serverUrl = credentials.url;
  try {
    final candidates = credentials.regionEntries.isNotEmpty
        ? credentials.regionEntries
        : gravixMeasuredCandidates(serverUrl, now: now, media: media, homeRegion: credentials.homeRegion);
    final home = credentials.homeRegion;
    final m = gravixRegionMeasurement(now: now);
    final best = m?.bestFor(media);
    String? held;
    if (best != null && best.ok) {
      for (final c in candidates) {
        if ((c.region == best.region || c.url == best.url) &&
            (media == null || gravixRegionAllowsMedia(c, media, now: now))) {
          held = c.url;
          break;
        }
      }
    }
    final p = gravixPickRegionFor(
      home != null ? serverUrl : (held ?? serverUrl),
      candidates,
      homeRegion: home,
      now: now,
      media: media,
      log: log,
    );
    if (p != null) {
      int? rtt;
      for (final r in m?.regions ?? const <GravixRegionMeasurement>[]) {
        if (r.region == p.entry.region && r.ok) rtt = r.rttMs;
      }
      return (
        choice: GravixJoinUrlChoice(
          url: p.entry.url,
          region: p.entry.region,
          rttMs: rtt,
          source: p.reason == GravixRegionPickReason.home ? GravixJoinUrlSource.home : GravixJoinUrlSource.measured,
          homeRegion: home,
          media: media,
        ),
        skipped: p.skipped,
        mediaIgnored: p.mediaIgnored,
      );
    }
  } catch (e) {
    GravixJoinLog.step('error', detail: 'join url: region pick failed, using the token url (${e.runtimeType})');
  }
  return (
    choice: GravixJoinUrlChoice(
      url: serverUrl,
      source: GravixJoinUrlSource.token,
      homeRegion: credentials.homeRegion,
      media: media,
    ),
    skipped: const <String>[],
    mediaIgnored: false,
  );
}

/// 0.9.0 (2026-11-08): [gravixJoinUrl] for a join -- it first waits for the region
/// measurement when nothing fresh is measured for this network.
///
/// 1. a run in flight (the app's gravixStartRegionMeasurement at start-up, a
///    refresh, a network change) is waited for, at most [wait]
///    ([kGravixJoinMeasureWait]); none in flight and the answer stale or failed:
///    a refresh is started and waited for the same (not when the last run ended
///    under [kGravixRegionRefreshMinAge] ago). No handle registered: no wait;
/// 2. then the choice as [gravixJoinUrl] makes it;
/// 3. still nothing measured, the token's url a fleet url and the join a viewer's
///    (`homeRegion` set): the gateway's `est_rtt_ms` decides between home and the
///    best estimated region allowing [media] ([gravixEstJoinRegion]),
///    [GravixJoinUrlSource.est]. No directory or estimate: the token url.
///
/// Hosts wait too (a measured pick is as good for them); the est fallback is for
/// viewers only: a host's token url is its own choice. Writes one
/// `[GravixRegion] pick join` line with the cause. Never throws.
Future<GravixJoinUrlChoice> gravixJoinUrlAsync(
  GravixJoinCredentials credentials, {
  GravixRoomMedia? media,
  Duration wait = kGravixJoinMeasureWait,
}) async {
  GravixJoinMeasureWait w;
  try {
    w = await gravixAwaitRegionForJoin(bound: wait);
  } catch (_) {
    w = const GravixJoinMeasureWait(before: 'error');
  }
  final r = _joinUrl(credentials, media: media, log: false);
  var choice = r.choice;
  String? est;
  try {
    if (choice.source == GravixJoinUrlSource.token && !(gravixRegionMeasurement()?.best?.ok ?? false)) {
      final e = gravixEstJoinRegion(
        credentials.url,
        credentials.regionEntries,
        homeRegion: credentials.homeRegion,
        media: media,
      );
      if (e != null) {
        choice = GravixJoinUrlChoice(
          url: e.entry.url,
          source: GravixJoinUrlSource.est,
          region: e.entry.region,
          homeRegion: credentials.homeRegion,
          media: media,
        );
        est =
            ' est-fallback(${e.pick.reason.wire} home=${credentials.homeRegion}:${e.pick.homeEstMs}ms'
            ' best=${e.pick.bestRegion}:${e.pick.bestEstMs}ms)';
      } else if (credentials.homeRegion != null) {
        est = ' est-fallback(none)';
      }
    }
  } catch (_) {
    // the token url stands
  }
  choice = GravixJoinUrlChoice(
    url: choice.url,
    source: choice.source,
    region: choice.region,
    rttMs: choice.rttMs,
    homeRegion: choice.homeRegion,
    media: choice.media,
    cause: w.cause,
  );
  GravixRegionLog.step(
    'pick',
    'join -> ${choice.region ?? gravixRegionOfUrl(choice.url, known: gravixLastRegionDirectory()) ?? Uri.tryParse(choice.url)?.host ?? '?'}'
        ' source=${choice.source.name} rtt=${choice.rttMs ?? '-'}'
        '${media == null ? '' : ' media=${media.name}'}'
        '${credentials.homeRegion == null ? '' : ' home=${credentials.homeRegion}'}'
        '${r.skipped.isEmpty ? '' : ' skip=${r.skipped.join(',')}'}'
        '${r.mediaIgnored ? ' mediaIgnored' : ''}'
        ' ${w.cause}${est ?? ''}',
  );
  return choice;
}

/// 0.9.0: after a join landed with [source] (the choice it dialled): when that url
/// did not come from a fresh measurement (the token's, an estimate, or nothing
/// fresh measured by now), a measurement refresh is kicked
/// ([gravixRefreshAfter]: a handle registered, no run in flight, the last one at
/// least [kGravixRegionRefreshMinAge] old), so the in-session latency move can
/// act after the confirm delay instead of the next 5-minute refresh. True when
/// it kicked one. Never throws.
bool gravixRefreshAfterJoin(GravixJoinUrlSource source, {DateTime? now}) {
  final unmeasured =
      source == GravixJoinUrlSource.token ||
      source == GravixJoinUrlSource.est ||
      gravixJoinMeasureState(now: now) != 'fresh';
  if (!unmeasured) return false;
  return gravixRefreshAfter('join-source=${source.name}', now: now);
}

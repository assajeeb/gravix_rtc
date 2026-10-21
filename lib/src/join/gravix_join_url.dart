// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Which url a join dials (0.4.19, fast join; moved from the apps). A lookup on
// the start-up region measurement (gravixStartRegionMeasurement), never a probe
// on the tap path.

import 'package:flutter/foundation.dart';

import '../backend/gravix_token_provider.dart';
import '../connect/gravix_init_measure.dart';
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

  /// This choice once a standby pre-connect is taken into account. A standby
  /// for this token, open at [standbyUrl] in another region while nothing is
  /// open at [url], beats a re-pick between warm-up and tap (field 2026-10-04:
  /// the start-up measurement flipped between two close regions in between and
  /// the join paid a cold WebSocket) -- EXCEPT for a home-region pick: that pick
  /// keeps host and viewer on one server, and dialling the standby's region
  /// instead would put the viewer back on the relayed path the home region
  /// avoids (2.9-3.4 % relay-leg loss measured that day). A cold WebSocket
  /// (~0.5-1 s, once) is the cheaper loss than a relayed session.
  GravixJoinUrlChoice withStandby({required String? standbyUrl, required bool pickedOpen, required bool standbyOpen}) {
    if (source == GravixJoinUrlSource.home) return this;
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
    return GravixJoinUrlChoice(url: standbyUrl, source: GravixJoinUrlSource.standby, media: media);
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
///    a token url on a region that does not is replaced by the first shortlist
///    region that does, even with nothing measured. Null: no filter.
GravixJoinUrlChoice gravixJoinUrl(GravixJoinCredentials credentials, {DateTime? now, GravixRoomMedia? media}) {
  final serverUrl = credentials.url;
  try {
    final candidates = credentials.regionEntries.isNotEmpty
        ? credentials.regionEntries
        : gravixMeasuredCandidates(serverUrl, now: now);
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
    final p = gravixPickRegion(
      home != null ? serverUrl : (held ?? serverUrl),
      candidates,
      homeRegion: home,
      now: now,
      media: media,
    );
    if (p != null) {
      int? rtt;
      for (final r in m?.regions ?? const <GravixRegionMeasurement>[]) {
        if (r.region == p.entry.region && r.ok) rtt = r.rttMs;
      }
      return GravixJoinUrlChoice(
        url: p.entry.url,
        region: p.entry.region,
        rttMs: rtt,
        source: p.reason == GravixRegionPickReason.home ? GravixJoinUrlSource.home : GravixJoinUrlSource.measured,
        homeRegion: home,
        media: media,
      );
    }
  } catch (e) {
    GravixJoinLog.step('error', detail: 'join url: region pick failed, using the token url (${e.runtimeType})');
  }
  return GravixJoinUrlChoice(
    url: serverUrl,
    source: GravixJoinUrlSource.token,
    homeRegion: credentials.homeRegion,
    media: media,
  );
}

// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

/// Cross-SDK probe-race telemetry, split into two events.
///
/// ## Why two events and not one
///
/// The first cut of this contract emitted a single `ConnectionReport` carrying
/// both the region decision and the join-to-first-audio timing. Because
/// `joinToFirstAudioMs` was part of it, the whole report had to be withheld
/// until first audio arrived **or its 30 s timeout elapsed** — so any session
/// that ended inside that window emitted nothing at all.
///
/// That is exactly backwards. A user who lands on a far edge, waits, hears
/// nothing and closes the app is the session the region telemetry exists to
/// catch, and it was the one session guaranteed to report nothing. Splitting
/// the region decision out means it is emitted at `connectedAt`,
/// unconditionally, with no dependency on anything that happens later.
///
/// The two events are correlated by [GravixRegionReport.connectionId].
///
/// ## Field names are a cross-SDK contract
///
/// Every name and wire value in this file is shared **verbatim** with the JS
/// SDK (`src/core/room/region/types.ts`) so the two SDKs' telemetry can be
/// joined in one table. Renaming a field here without renaming it there makes
/// the data unjoinable. See `doc/PROBE_RACE_PARITY.md`.
library;

import 'package:flutter/foundation.dart';

/// One candidate region from the token response's `region_urls`.
@immutable
class GravixRegionUrl {
  const GravixRegionUrl({required this.region, required this.url, this.probeUrl, this.estRttMs});

  /// Region slug, e.g. `sgp1`, `blr1`.
  final String region;

  /// Signalling URL for that region, e.g. `wss://sgp1.example.com`.
  final String url;

  /// The region's dedicated probe endpoint - the token response's `probe_url`,
  /// which is the SFU's `/v1/region-probe` (uncached, lock-free, answers
  /// `{"region","node"}`). When present it is probed INSTEAD of the signalling
  /// origin's root and the region it names is checked against [region]. Null
  /// when the gateway sent none; the entry is then probed the original way.
  final String? probeUrl;

  /// The gateway's estimate of this client's RTT to the region (`est_rtt_ms` in
  /// `GET /v1/regions`, 2026-10-02), from its latency map. Used only to choose WHICH
  /// regions to measure when the list is long and has no shortlist; never as a
  /// measurement. Null when the gateway sent none.
  final double? estRttMs;

  @override
  bool operator ==(Object other) =>
      other is GravixRegionUrl &&
      other.region == region &&
      other.url == url &&
      other.probeUrl == probeUrl &&
      other.estRttMs == estRttMs;

  @override
  int get hashCode => Object.hash(region, url, probeUrl, estRttMs);

  @override
  String toString() => '$region=$url';
}

/// Slug used when a URL cannot be matched to a region. Shared with the JS SDK.
const String kGravixUnknownRegion = 'unknown';

/// HTTP method behind a probe measurement.
///
/// `HEAD` is the contract default and what this SDK issues. `GET` exists only
/// as the single per-region retry for an edge that answers `HEAD` with 405 or
/// 501, i.e. does not implement the method at all. This SDK does not yet issue
/// that retry; the field exists so both SDKs emit the same shape.
enum GravixProbeMethod {
  head('HEAD'),
  get('GET');

  const GravixProbeMethod(this.wireName);

  /// The value written to the wire. Uppercase, matching the JS SDK.
  final String wireName;
}

/// Why a particular URL was chosen. Wire values match the JS SDK exactly.
enum GravixRegionChoiceReason {
  /// A probe responded fastest and won the race outright.
  probeWinner('probe-winner'),

  /// The pinned URL was within the tie-break window of the fastest responder.
  pinnedTiebreak('pinned-tiebreak'),

  /// Nothing answered within the probe timeout; the pinned URL was used.
  noResponder('no-responder'),

  /// Only one candidate region was available to probe.
  singleRegion('single-region'),

  /// A remembered decision was used and nothing was probed for this connect
  /// (`regionDecisionCache`). Same wire value as the JS SDK.
  cached('cached');

  const GravixRegionChoiceReason(this.wireName);

  /// The value written to the wire — kebab-case, matching the JS SDK.
  final String wireName;
}

/// UTC ISO-8601 with millisecond precision — the format every SDK emits.
///
/// `DateTime.toIso8601String()` on a UTC value already produces
/// `2026-09-12T10:04:03.123Z`; microseconds are dropped so the two SDKs cannot
/// disagree on precision.
String gravixIsoMs(DateTime at) {
  final utc = at.toUtc();
  return DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
    utc.hour,
    utc.minute,
    utc.second,
    utc.millisecond,
  ).toIso8601String();
}

/// Outcome of a single region probe.
@immutable
class GravixRegionProbe {
  const GravixRegionProbe({
    required this.region,
    required this.url,
    required this.rttMs,
    required this.ok,
    this.method = GravixProbeMethod.head,
    this.methodFallback = false,
  });

  final String region;
  final String url;

  /// Round-trip time in milliseconds, or null when the probe failed or timed
  /// out.
  final int? rttMs;

  /// True only for a 2xx response received within the probe timeout.
  final bool ok;

  /// The method that produced [rttMs].
  final GravixProbeMethod method;

  /// True when a `HEAD` was answered 405/501 and retried once as `GET`.
  final bool methodFallback;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'region': region,
    'url': url,
    'rttMs': rttMs,
    'ok': ok,
    'method': method.wireName,
    'methodFallback': methodFallback,
  };

  @override
  String toString() => '$region ${ok ? "ok" : "fail"}${rttMs == null ? "" : " ${rttMs}ms"}';
}

/// The region decision for one connect, emitted at `connectedAt`.
///
/// Emitted **unconditionally** with respect to audio: nothing about this event
/// waits on first audio, on a timeout, or on the session lasting any
/// particular length of time. See the library doc for why that matters.
@immutable
class GravixRegionReport {
  const GravixRegionReport({
    required this.connectionId,
    required this.pinnedRegion,
    required this.chosenRegion,
    required this.chosenUrl,
    required this.fallbackUsed,
    required this.reason,
    required this.probes,
    required this.probeMethod,
    required this.probeStartedAt,
    required this.connectStartedAt,
    required this.connectedAt,
    this.regionsMeasured,
  });

  /// The start-up measurement behind this connect's region knowledge, when one is
  /// fresh and sampled something (0.4.6, 2026-10-02): the analytics report's
  /// `regions_measured` object ([gravixRegionsMeasuredReport]). Absent from
  /// [toJson] otherwise, so existing consumers see no change.
  final Map<String, Object?>? regionsMeasured;

  /// Correlates this report with the [GravixFirstAudioReport] for the same
  /// connect. Unique per `connect()`; opaque to consumers.
  final String connectionId;

  /// Region slug of the pinned home URL from the token response.
  final String pinnedRegion;

  /// Region slug actually connected to.
  final String chosenRegion;

  /// Signalling URL actually connected to.
  final String chosenUrl;

  /// True when the pinned URL was used because no region answered in time.
  final bool fallbackUsed;

  /// Machine-readable explanation of the choice.
  final GravixRegionChoiceReason reason;

  /// One entry per candidate region, in the order supplied by the server.
  final List<GravixRegionProbe> probes;

  /// The method behind the winning measurement, or null when no region
  /// answered and the pinned URL was used.
  final GravixProbeMethod? probeMethod;

  final DateTime probeStartedAt;
  final DateTime connectStartedAt;
  final DateTime connectedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'connectionId': connectionId,
    'pinnedRegion': pinnedRegion,
    'chosenRegion': chosenRegion,
    'chosenUrl': chosenUrl,
    'fallbackUsed': fallbackUsed,
    'reason': reason.wireName,
    'probes': probes.map((p) => p.toJson()).toList(growable: false),
    'probeMethod': probeMethod?.wireName,
    'probeStartedAt': gravixIsoMs(probeStartedAt),
    'connectStartedAt': gravixIsoMs(connectStartedAt),
    'connectedAt': gravixIsoMs(connectedAt),
    if (regionsMeasured != null) 'regionsMeasured': regionsMeasured,
  };

  @override
  String toString() => 'GravixRegionReport(${reason.wireName} -> $chosenRegion $chosenUrl, id=$connectionId)';
}

/// First-audio timing for one connect, emitted once the first remote audio
/// track is subscribed or the wait times out — whichever comes first.
///
/// Correlate with [GravixRegionReport] via [connectionId]. A session that ends
/// before audio arrives still gets this event, with both audio fields null.
@immutable
class GravixFirstAudioReport {
  const GravixFirstAudioReport({
    required this.connectionId,
    required this.connectedAt,
    required this.firstAudioAt,
    required this.joinToFirstAudioMs,
  });

  /// Matches the [GravixRegionReport.connectionId] of the same connect.
  final String connectionId;

  /// Repeated from the region report so this event stands on its own.
  final DateTime connectedAt;

  /// When the first remote audio track was subscribed, or null when none
  /// arrived within [kGravixFirstAudioTimeout] or the session ended first.
  final DateTime? firstAudioAt;

  /// `connectedAt` → `firstAudioAt` in milliseconds, or null.
  final int? joinToFirstAudioMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'connectionId': connectionId,
    'connectedAt': gravixIsoMs(connectedAt),
    'firstAudioAt': firstAudioAt == null ? null : gravixIsoMs(firstAudioAt!),
    'joinToFirstAudioMs': joinToFirstAudioMs,
  };

  @override
  String toString() =>
      'GravixFirstAudioReport(id=$connectionId, ${joinToFirstAudioMs == null ? "no audio" : "${joinToFirstAudioMs}ms"})';
}

/// Give up waiting for first audio after this long; the first-audio event is
/// then emitted with null audio fields. Matches the JS SDK's
/// `FIRST_AUDIO_TIMEOUT_MS`.
const Duration kGravixFirstAudioTimeout = Duration(seconds: 30);

/// Reads `region_urls` out of a token-service response as region/url pairs.
///
/// Tolerant in exactly the same way as [gravixRegionUrlsFrom]: an absent, null
/// or wrongly-typed field means "no regions". A bare string entry carries no
/// slug, so it is reported as [kGravixUnknownRegion] rather than dropped.
List<GravixRegionUrl> gravixRegionEntriesFrom(Map<String, dynamic>? tokenResponse) {
  final raw = tokenResponse?['region_urls'];
  if (raw is! List) return const [];
  final entries = <GravixRegionUrl>[];
  for (final entry in raw) {
    if (entry is String) {
      if (entry.isNotEmpty) entries.add(GravixRegionUrl(region: kGravixUnknownRegion, url: entry));
    } else if (entry is Map) {
      final url = entry['url'];
      if (url is String && url.isNotEmpty) {
        final region = entry['region'];
        final probeUrl = entry['probe_url'];
        entries.add(
          GravixRegionUrl(
            region: region is String && region.isNotEmpty ? region : kGravixUnknownRegion,
            url: url,
            probeUrl: probeUrl is String && probeUrl.isNotEmpty ? probeUrl : null,
          ),
        );
      }
    }
  }
  return List<GravixRegionUrl>.unmodifiable(entries);
}

/// Builds the region event from a race outcome.
///
/// A pure function on purpose: it is the half of the contract that has to
/// agree with the JS SDK field for field, and keeping it out of
/// `GravixRoomService` means it can be tested without a transport that can
/// actually connect. The JS SDK's equivalent is `buildConnectionReport` in
/// `src/core/room/region/connectionReport.ts`.
GravixRegionReport buildGravixRegionReport({
  required String connectionId,
  required List<GravixRegionUrl> candidates,
  required String pinnedUrl,
  required String chosenUrl,
  required bool anyResponder,
  required Map<String, ({bool ok, Duration elapsed})> results,
  required DateTime probeStartedAt,
  required DateTime connectStartedAt,
  required DateTime connectedAt,
  bool cached = false,
  Map<String, Object?>? regionsMeasured,
}) {
  String regionFor(String url) {
    for (final c in candidates) {
      if (c.url == url) return c.region;
    }
    return kGravixUnknownRegion;
  }

  // One entry per CANDIDATE, in the server's order — not one per probe that
  // happened to finish. A probe still in flight when the race was decided is
  // reported as a non-responder rather than omitted, so the array length is
  // the candidate count in both SDKs and a missing row always means the server
  // did not offer that region.
  // A cache hit reports honestly, as JS does: nothing was probed for THIS
  // connect, so no probe rows rather than the previous race's numbers.
  final probes = cached
      ? const <GravixRegionProbe>[]
      : <GravixRegionProbe>[
          for (final c in candidates)
            GravixRegionProbe(
              region: c.region,
              url: c.url,
              rttMs: (results[c.url]?.ok ?? false) ? results[c.url]!.elapsed.inMilliseconds : null,
              ok: results[c.url]?.ok ?? false,
            ),
        ];

  final fallbackUsed = !cached && !anyResponder;
  final reason = cached
      ? GravixRegionChoiceReason.cached
      : fallbackUsed
      ? GravixRegionChoiceReason.noResponder
      : candidates.length == 1
      ? GravixRegionChoiceReason.singleRegion
      : chosenUrl == pinnedUrl
      // Same meaning as JS `pinned-tiebreak` since 2026-09-19: the pinned url
      // was the fastest, or answered within 15ms of the fastest and kept the
      // join (GravixRegionProber.tieBreak). Before that this SDK took the
      // first responder outright and the label was only an approximation.
      ? GravixRegionChoiceReason.pinnedTiebreak
      : GravixRegionChoiceReason.probeWinner;

  return GravixRegionReport(
    connectionId: connectionId,
    pinnedRegion: regionFor(pinnedUrl),
    chosenRegion: regionFor(chosenUrl),
    chosenUrl: chosenUrl,
    fallbackUsed: fallbackUsed,
    reason: reason,
    probes: List<GravixRegionProbe>.unmodifiable(probes),
    // HEAD is and stays the probe method — see [GravixRegionProber]. Null when
    // nothing answered, because then no measurement produced the choice.
    probeMethod: fallbackUsed || cached ? null : GravixProbeMethod.head,
    probeStartedAt: probeStartedAt,
    connectStartedAt: connectStartedAt,
    connectedAt: connectedAt,
    regionsMeasured: regionsMeasured,
  );
}

/// Builds the first-audio event. [firstAudioAt] is null when nothing was heard
/// before [kGravixFirstAudioTimeout] or the session ended.
GravixFirstAudioReport buildGravixFirstAudioReport({
  required String connectionId,
  required DateTime connectedAt,
  required DateTime? firstAudioAt,
}) => GravixFirstAudioReport(
  connectionId: connectionId,
  connectedAt: connectedAt,
  firstAudioAt: firstAudioAt,
  joinToFirstAudioMs: firstAudioAt?.difference(connectedAt).inMilliseconds,
);

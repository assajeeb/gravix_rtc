// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart';

/// Why the connect fell back to the pinned URL instead of a probed region.
enum GravixRegionFallbackReason {
  /// No fallback — a probed region won.
  none,

  /// `regionProbe` was not enabled.
  disabled,

  /// The token response carried no `region_urls`.
  noRegionUrls,

  /// Every probe failed before the race deadline.
  allProbesFailed,

  /// The race deadline passed with no responder.
  timeout,
}

/// One region probe's outcome.
@immutable
class GravixRegionProbeResult {
  const GravixRegionProbeResult({required this.url, required this.elapsed, required this.ok, this.error});

  final String url;

  /// How long the probe took, or how long it ran before failing/being cut off.
  final Duration elapsed;

  final bool ok;

  /// Failure detail, when [ok] is false.
  final Object? error;

  @override
  String toString() => '$url ${ok ? "ok" : "fail"} in ${elapsed.inMilliseconds}ms${error == null ? "" : " ($error)"}';
}

/// What happened during a connect: which region was used and why, and how long
/// the user waited to hear anything.
///
/// Produced by [GravixRoomService.connect] and readable afterwards as
/// `service.lastConnectionReport`. Purely observational — nothing in the SDK
/// branches on it.
@immutable
class GravixConnectionReport {
  const GravixConnectionReport({
    required this.startedAt,
    required this.pinnedUrl,
    required this.connectedUrl,
    required this.regionProbeEnabled,
    required this.candidateUrls,
    required this.probeResults,
    required this.fallbackReason,
    this.winningRegionUrl,
    this.regionSelection,
    this.joinToConnected,
    this.joinToFirstAudio,
    this.connected = false,
  });

  /// When `connect()` was called.
  final DateTime startedAt;

  /// The URL the caller passed — the fallback, and the URL used whenever the
  /// probe race is off, empty, or loses.
  final String pinnedUrl;

  /// The URL actually handed to the transport.
  final String connectedUrl;

  final bool regionProbeEnabled;

  /// The region URLs that were raced, in the order the token service gave
  /// them. Empty when there were none.
  final List<String> candidateUrls;

  /// Every probe outcome known when the race was decided. Probes still in
  /// flight at that moment are absent.
  final List<GravixRegionProbeResult> probeResults;

  /// Null when a region won; otherwise why the pinned URL was used.
  final GravixRegionFallbackReason fallbackReason;

  /// The region that answered first, if any.
  final String? winningRegionUrl;

  /// Time spent racing probes. Null when no race ran.
  final Duration? regionSelection;

  /// `connect()` entry to the transport reporting connected.
  final Duration? joinToConnected;

  /// `connect()` entry to the first **remote** audio track being subscribed —
  /// the first moment the user could actually hear another participant.
  ///
  /// Null when the room was still silent when the report was read: a solo
  /// join, a listener-only room with nobody speaking, or a connect that
  /// failed. It is filled in asynchronously, so read
  /// `service.lastConnectionReport` again after audio starts rather than
  /// caching the instance returned at connect time.
  final Duration? joinToFirstAudio;

  /// Whether the transport reported a successful connect.
  final bool connected;

  /// True when a probed region beat the pinned URL.
  bool get usedProbedRegion => winningRegionUrl != null;

  GravixConnectionReport copyWith({
    String? connectedUrl,
    List<GravixRegionProbeResult>? probeResults,
    GravixRegionFallbackReason? fallbackReason,
    String? winningRegionUrl,
    Duration? regionSelection,
    Duration? joinToConnected,
    Duration? joinToFirstAudio,
    bool? connected,
  }) => GravixConnectionReport(
    startedAt: startedAt,
    pinnedUrl: pinnedUrl,
    connectedUrl: connectedUrl ?? this.connectedUrl,
    regionProbeEnabled: regionProbeEnabled,
    candidateUrls: candidateUrls,
    probeResults: probeResults ?? this.probeResults,
    fallbackReason: fallbackReason ?? this.fallbackReason,
    winningRegionUrl: winningRegionUrl ?? this.winningRegionUrl,
    regionSelection: regionSelection ?? this.regionSelection,
    joinToConnected: joinToConnected ?? this.joinToConnected,
    joinToFirstAudio: joinToFirstAudio ?? this.joinToFirstAudio,
    connected: connected ?? this.connected,
  );

  @override
  String toString() {
    final b = StringBuffer('GravixConnectionReport(')..write('connected=$connected, url=$connectedUrl');
    if (winningRegionUrl != null) {
      b.write(', region=$winningRegionUrl won in ${regionSelection?.inMilliseconds}ms');
    } else {
      b.write(', pinned (${fallbackReason.name})');
    }
    if (joinToConnected != null) b.write(', joinToConnected=${joinToConnected!.inMilliseconds}ms');
    if (joinToFirstAudio != null) b.write(', joinToFirstAudio=${joinToFirstAudio!.inMilliseconds}ms');
    if (probeResults.isNotEmpty) b.write(', probes=[${probeResults.join(", ")}]');
    return (b..write(')')).toString();
  }
}

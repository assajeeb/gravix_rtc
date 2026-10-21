// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.
//
// Per-region media (owner 2026-10-21): which media a region's servers take.
//
// doh1 (GCP Doha) egress is expensive, so doh1 is audio-only: the console's
// `GET /v1/regions` entries carry an optional `media` (`["audio"]`; absent =
// every medium; a region allowing nothing is not listed) and its shortlist
// always holds at least one region allowing audio and one allowing video. The
// start-up measurement is media-blind (one measurement serves every join); the
// JOIN filters: a join that uses video goes to the best measured region that
// allows video, an audio-only join may use any region. Rule for rule the React
// SDK's src/core/room/region/regionMedia.ts and the Android SDK's
// GravixRegionMedia.kt; the `media` cases of test/fixtures/region_shortlist_cases.json
// must give the same choice in all three.
//
// No network call on the join path: what a region allows is remembered from the
// start-up `/v1/regions` fetch (or its stored copy) in a slug -> media map, so
// candidates that carry no `media` (a token's `region_urls`, a cache-seeded
// answer) are still checked.
import 'package:flutter/foundation.dart';

import '../rtc_core/src/token_source/jwt.dart' show GravixRtcJwtPayload;
import 'gravix_region_failover.dart' show gravixRegionOfUrl;
import 'gravix_region_report.dart';

/// What a room uses, as the join declares it. Wire names = [name].
///
/// - [audio]: nobody in the room publishes or watches video (voice rooms);
/// - [video]: the room uses video (published by this user or by others): the
///   default, because it is the safe one -- it never lands on an audio-only
///   region.
enum GravixRoomMedia { audio, video }

/// Media names a region's `media` list uses.
const kGravixMediaAudio = 'audio';
const kGravixMediaVideo = 'video';

/// The string a server refusal of a medium carries (publish error / leave
/// reason) when this node does not take it, e.g. video on an audio-only region.
const kGravixMediaNotAllowed = 'media_not_allowed';

/// How long a region that refused a medium is avoided for it.
const kGravixMediaRefusalLife = Duration(minutes: 10);

/// Parses a region entry's `media`: a list of names (lower-cased; unknown names
/// are kept, they just never match), or null when absent / not a list (= every
/// medium). An empty list allows nothing.
List<String>? gravixParseRegionMedia(Object? v) {
  if (v is! List) return null;
  return List.unmodifiable([
    for (final m in v)
      if (m is String && m.trim().isNotEmpty) m.trim().toLowerCase(),
  ]);
}

/// True when a region whose `media` is [media] takes a [want] join. Null media =
/// every medium (old servers; regions with no restriction).
bool gravixMediaAllows(List<String>? media, GravixRoomMedia want) => media == null || media.contains(want.name);

/// See the file comment: slug -> `media` from the last region directory.
final Map<String, List<String>?> _mediaBySlug = <String, List<String>?>{};

/// The last region directory's entries (with `media`), in list order, plus its
/// shortlist: the nothing-measured fallback of a join needs them.
List<GravixRegionUrl> _lastRegions = const [];
List<String> _lastShortlist = const [];

/// region -> media -> refused until.
final Map<String, Map<GravixRoomMedia, DateTime>> _refused = <String, Map<GravixRoomMedia, DateTime>>{};

/// Remembers what each region of a fresh (or stored) `/v1/regions` answer
/// allows. Called by the start-up measurement; apps do not need to.
void gravixNoteRegionDirectory(List<GravixRegionUrl> regions, {List<String>? shortlist}) {
  if (regions.isEmpty) return;
  _mediaBySlug.clear();
  for (final r in regions) {
    _mediaBySlug.putIfAbsent(r.region, () => r.media);
  }
  _lastRegions = List.unmodifiable(regions);
  _lastShortlist = List.unmodifiable(shortlist ?? const <String>[]);
}

/// The last region directory's entries (see [gravixNoteRegionDirectory]).
List<GravixRegionUrl> gravixLastRegionDirectory() => _lastRegions;

/// The last region directory's shortlist.
List<String> gravixLastRegionShortlist() => _lastShortlist;

/// What [region] allows, as the last directory said (null = every medium, or
/// not known).
List<String>? gravixRegionMediaOf(String region) => _mediaBySlug[region];

/// Notes that [region] refused [media] (a server refusal: [gravixIsMediaNotAllowed]).
/// Joins and failovers avoid it for that medium for [kGravixMediaRefusalLife].
void gravixNoteMediaRefused(String region, GravixRoomMedia media, {DateTime? now}) {
  if (region.isEmpty) return;
  (_refused[region] ??= <GravixRoomMedia, DateTime>{})[media] = (now ?? DateTime.now()).add(kGravixMediaRefusalLife);
  GravixRegionLog.step(
    'mediaRefused',
    'region=$region media=${media.name} avoid=${kGravixMediaRefusalLife.inMinutes}min',
  );
}

bool _refusedNow(String region, GravixRoomMedia media, DateTime? now) {
  final until = _refused[region]?[media];
  return until != null && (now ?? DateTime.now()).isBefore(until);
}

/// True when [entry] takes a [media] join: its own `media` when it carries one,
/// else what the last directory said of its region, else yes (old servers). A
/// region that refused [media] in the last [kGravixMediaRefusalLife] does not.
bool gravixRegionAllowsMedia(GravixRegionUrl entry, GravixRoomMedia media, {DateTime? now}) {
  if (_refusedNow(entry.region, media, now)) return false;
  return gravixMediaAllows(entry.media ?? _mediaBySlug[entry.region], media);
}

/// True when [url] takes a [media] join: its region (from [known], the last
/// directory, the measurement) allows it, or its region is not known (a url
/// outside the fleet is never second-guessed).
bool gravixUrlAllowsMedia(
  String url,
  GravixRoomMedia media, {
  Iterable<GravixRegionUrl> known = const [],
  DateTime? now,
}) {
  final region = gravixRegionOfUrl(url, known: [...known, ..._lastRegions], now: now);
  if (region == null) return true;
  final entry = known.where((e) => e.region == region).firstOrNull ?? GravixRegionUrl(region: region, url: url);
  return gravixRegionAllowsMedia(entry, media, now: now);
}

/// Why a region was passed over, for the log: `audio-only`, `video-only`,
/// `refused`, or the region's list.
String gravixMediaSkipWhy(GravixRegionUrl entry, GravixRoomMedia media, {DateTime? now}) {
  if (_refusedNow(entry.region, media, now)) return 'refused';
  final m = entry.media ?? _mediaBySlug[entry.region] ?? const <String>[];
  return m.length == 1 ? '${m.first}-only' : (m.isEmpty ? 'no-media' : m.join('+'));
}

/// The token's hint (never a demotion): `video` when its video grant lets this
/// participant publish the camera or a screen share (`video.canPublishSources`
/// names `camera` / `screen_share`). Null otherwise -- including a mic-only
/// publisher: someone who publishes only audio may still WATCH video, so a
/// mic-only grant does not make the room audio-only. An empty / absent list
/// (= every source) says nothing either. Never throws.
GravixRoomMedia? gravixMediaHintFromToken(String? token) {
  if (token == null || token.isEmpty) return null;
  try {
    final claims = GravixRtcJwtPayload.fromToken(token)?.claims;
    final video = claims?['video'];
    final sources = video is Map ? video['canPublishSources'] : null;
    if (sources is! List) return null;
    for (final s in sources) {
      final n = '$s'.toLowerCase();
      if (n == 'camera' || n == 'screen_share' || n == 'screenshare') return GravixRoomMedia.video;
    }
  } catch (_) {
    // a token this SDK cannot read gives no hint
  }
  return null;
}

/// The media a join uses: [declared] (default [GravixRoomMedia.video]),
/// promoted to video when [enableVideo] (the join publishes the camera) or the
/// token may publish video ([gravixMediaHintFromToken]). Never demoted. Logs the
/// decision and its cause.
GravixRoomMedia gravixJoinMedia({GravixRoomMedia? declared, bool enableVideo = false, String? token}) {
  final base = declared ?? GravixRoomMedia.video;
  if (base == GravixRoomMedia.video) {
    GravixRegionLog.step('media', 'media=video cause=${declared == null ? 'default' : 'declared'}');
    return GravixRoomMedia.video;
  }
  if (enableVideo) {
    GravixRegionLog.step('media', 'media=video cause=enableVideo (declared audio)');
    return GravixRoomMedia.video;
  }
  if (gravixMediaHintFromToken(token) == GravixRoomMedia.video) {
    GravixRegionLog.step('media', 'media=video cause=token-grant-camera (declared audio)');
    return GravixRoomMedia.video;
  }
  GravixRegionLog.step('media', 'media=audio cause=declared');
  return GravixRoomMedia.audio;
}

/// The medium a [kGravixMediaNotAllowed] refusal is about: audio when its text
/// names audio and not video, else video. The SFU's refusal of a video publish
/// on a video-off node is a RequestResponse NOT_ALLOWED whose message is exactly
/// `media_not_allowed` (SFU flag work, 2026-10-21): video.
GravixRoomMedia gravixRefusedMedia(Object? reason) {
  final t = '$reason'.toLowerCase();
  return t.contains('audio') && !t.contains('video') ? GravixRoomMedia.audio : GravixRoomMedia.video;
}

/// True when [errorOrReason] (an error, a publish failure, a leave reason) is a
/// server refusal of a medium on this node ([kGravixMediaNotAllowed]).
bool gravixIsMediaNotAllowed(Object? errorOrReason) {
  if (errorOrReason == null) return false;
  try {
    return '$errorOrReason'.toLowerCase().contains(kGravixMediaNotAllowed);
  } catch (_) {
    return false;
  }
}

/// Forgets every media note (tests; [gravixClearRegionMeasurement] calls it).
void gravixClearRegionMedia() {
  _mediaBySlug.clear();
  _lastRegions = const [];
  _lastShortlist = const [];
  _refused.clear();
}

/// `[GravixRegion] <step> <detail>`: one line per region decision (owner rule
/// 2026-10-15: the reason and the cause of every step). Never a token or a url
/// path; region slugs and numbers only.
abstract final class GravixRegionLog {
  static const String prefix = '[GravixRegion]';

  /// On by default (a few lines per join).
  static bool enabled = true;

  /// Where the lines go (default debugPrint).
  static void Function(String line)? sink;

  static void step(String step, String detail) {
    if (!enabled) return;
    final line = '$prefix $step $detail';
    (sink ?? debugPrint)(line);
  }
}

// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rtc_core/gravix_client.dart' show ConnectionQuality, RemoteTrackPublication, RemoteVideoTrack, Room;

/// One remote video subscription the policy can turn off and back on.
///
/// A seam over [RemoteTrackPublication], so the policy — the part with the
/// hysteresis and the bookkeeping, i.e. the part that can be wrong — is
/// testable without a live SFU. [GravixRoomVideoSource] is the real
/// implementation.
abstract interface class GravixVideoSubscription {
  String get sid;
  bool get subscribed;
  Future<void> subscribe();
  Future<void> unsubscribe();
}

/// Where the policy reads connection quality and remote video from.
abstract interface class GravixVideoSource {
  /// The local participant's connection quality, or null when there is no
  /// local participant yet.
  ConnectionQuality? get connectionQuality;

  /// Every remote video publication currently known.
  Iterable<GravixVideoSubscription> get videoSubscriptions;
}

/// [GravixVideoSource] backed by a live [Room].
class GravixRoomVideoSource implements GravixVideoSource {
  const GravixRoomVideoSource(this.room);

  final Room room;

  @override
  ConnectionQuality? get connectionQuality => room.localParticipant?.connectionQuality;

  @override
  Iterable<GravixVideoSubscription> get videoSubscriptions =>
      room.remoteParticipants.values.expand((p) => p.videoTrackPublications).map(_PublicationSubscription.new);
}

class _PublicationSubscription implements GravixVideoSubscription {
  const _PublicationSubscription(this._publication);

  final RemoteTrackPublication<RemoteVideoTrack> _publication;

  @override
  String get sid => _publication.sid;

  @override
  bool get subscribed => _publication.subscribed;

  @override
  Future<void> subscribe() => _publication.subscribe();

  @override
  Future<void> unsubscribe() => _publication.unsubscribe();
}

/// Drops remote **video** subscriptions while the local connection is
/// sustainedly poor, and restores them once it recovers.
///
/// This is the viewer-side counterpart to the publisher-side data saver: the
/// data saver protects a weak *uplink* by publishing less, this protects a weak
/// *downlink* by subscribing to less. Audio is never touched — in a live room
/// losing the audio is losing the room, so video is the only thing that goes.
///
/// Entirely opt-in and self-contained: construct one, [attach] it to a room,
/// and [detach] before the room goes away. Nothing in [GravixRoomService] does
/// this for you, and the policy never publishes, renegotiates, or reconnects —
/// it only flips subscriptions on existing publications.
///
/// ```dart
/// final fallback = GravixAudioOnlyFallback()..attach(room);
/// // ... later
/// await fallback.detach();
/// ```
class GravixAudioOnlyFallback {
  GravixAudioOnlyFallback({
    this.engageAfter = const Duration(seconds: 10),
    this.restoreAfter = const Duration(seconds: 45),
    this.minSwitchGap = const Duration(seconds: 60),
    this.pollInterval = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long quality must stay poor/lost before video is dropped.
  ///
  /// Long enough that a lift-crossing blip does not blank everyone's video.
  final Duration engageAfter;

  /// How long quality must stay excellent before video comes back.
  ///
  /// Deliberately much longer than [engageAfter]: re-subscribing costs
  /// bandwidth on a link that was just struggling, so the bar to spend it again
  /// is higher than the bar to stop.
  final Duration restoreAfter;

  /// Floor between two switches, so a link hovering at the boundary cannot
  /// oscillate.
  final Duration minSwitchGap;

  /// How often quality is sampled.
  final Duration pollInterval;

  final DateTime Function() _now;

  GravixVideoSource? _source;
  Timer? _timer;
  DateTime? _poorSince;
  DateTime? _goodSince;
  DateTime _lastSwitch = DateTime.fromMillisecondsSinceEpoch(0);
  bool _switching = false;

  /// True while video subscriptions are dropped. Bind a "Video paused — weak
  /// connection" banner to this.
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Publications this policy unsubscribed, so restore only re-subscribes what
  /// it took away — never something the app or the server unsubscribed for its
  /// own reasons.
  final Set<String> _droppedSids = <String>{};

  /// Whether a source is currently attached.
  bool get isAttached => _source != null;

  /// Track sids currently dropped by this policy.
  Set<String> get droppedTrackSids => Set<String>.unmodifiable(_droppedSids);

  /// Start watching [room].
  void attach(Room room) => attachSource(GravixRoomVideoSource(room));

  /// [attach] against any [GravixVideoSource].
  void attachSource(GravixVideoSource source) {
    detachSync();
    _source = source;
    _timer = Timer.periodic(pollInterval, (_) => unawaited(evaluate()));
  }

  /// Stop watching, restoring anything this policy dropped.
  Future<void> detach() async {
    final source = _source;
    _timer?.cancel();
    _timer = null;
    if (source != null && _droppedSids.isNotEmpty) {
      await _restore(source);
    }
    _source = null;
    _poorSince = null;
    _goodSince = null;
    active.value = false;
  }

  /// Stop watching without restoring — for a room that is going away anyway.
  void detachSync() {
    _timer?.cancel();
    _timer = null;
    _source = null;
    _poorSince = null;
    _goodSince = null;
  }

  void dispose() {
    detachSync();
    active.dispose();
  }

  /// One policy tick. Public so an app can drive it from its own quality
  /// signal instead of the timer, and so it is testable without waiting.
  Future<void> evaluate() async {
    final source = _source;
    if (source == null || _switching) return;

    final quality = source.connectionQuality;
    if (quality == null) return;
    final now = _now();

    final isPoor = quality == ConnectionQuality.poor || quality == ConnectionQuality.lost;
    final isExcellent = quality == ConnectionQuality.excellent;

    _poorSince = isPoor ? (_poorSince ?? now) : null;
    _goodSince = isExcellent ? (_goodSince ?? now) : null;

    if (now.difference(_lastSwitch) < minSwitchGap) return;

    final poorSince = _poorSince;
    final goodSince = _goodSince;
    if (!active.value && poorSince != null && now.difference(poorSince) >= engageAfter) {
      await _engage(source);
    } else if (active.value && goodSince != null && now.difference(goodSince) >= restoreAfter) {
      await _restore(source);
    }
  }

  /// Drop video now, regardless of measured quality — for a user-facing
  /// "audio only" switch.
  Future<void> engageNow() async {
    final source = _source;
    if (source != null && !active.value) await _engage(source);
  }

  /// Restore video now, regardless of measured quality.
  Future<void> restoreNow() async {
    final source = _source;
    if (source != null && active.value) await _restore(source);
  }

  Future<void> _engage(GravixVideoSource source) async {
    _switching = true;
    try {
      var dropped = 0;
      for (final publication in source.videoSubscriptions) {
        if (!publication.subscribed) continue;
        try {
          await publication.unsubscribe();
          _droppedSids.add(publication.sid);
          dropped++;
        } catch (e) {
          debugPrint('audioOnlyFallback: could not unsubscribe ${publication.sid}: $e');
        }
      }
      active.value = true;
      _lastSwitch = _now();
      _poorSince = null;
      _goodSince = null;
      debugPrint('📉 audioOnlyFallback: dropped $dropped video subscription(s) on sustained poor quality');
    } finally {
      _switching = false;
    }
  }

  Future<void> _restore(GravixVideoSource source) async {
    _switching = true;
    try {
      var restored = 0;
      for (final publication in source.videoSubscriptions) {
        if (!_droppedSids.contains(publication.sid)) continue;
        try {
          await publication.subscribe();
          restored++;
        } catch (e) {
          debugPrint('audioOnlyFallback: could not re-subscribe ${publication.sid}: $e');
        }
      }
      // Cleared wholesale: a track that went away while we were in audio-only
      // is never coming back under the same sid, and holding its id would leak.
      _droppedSids.clear();
      active.value = false;
      _lastSwitch = _now();
      _poorSince = null;
      _goodSince = null;
      debugPrint('📈 audioOnlyFallback: restored $restored video subscription(s)');
    } finally {
      _switching = false;
    }
  }
}

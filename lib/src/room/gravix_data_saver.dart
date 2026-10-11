// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The host's automatic data saver (GravixRoomService, video rooms).
//
// Simulcast serves weak VIEWERS; this protects weak HOSTS. A 3 s monitor
// watches the host's own connectionQuality:
//   poor/lost for >= 10 s  -> low-data profile (data saver ON)
//   excellent for >= 45 s  -> normal profile   (data saver OFF)
// Hysteresis + a 60 s minimum gap between switches prevent oscillation.
//
// REAL-DEVICE finding 2026-10-11 (iPhone 17 Pro Max, iOS 27.0.1, n=3: background
// twice, screen lock once): ~15-25 s after the app left the screen, iOS had
// paused the camera, the SFU scored the silent video "poor", and the data saver
// unpublished the camera to republish it single-layer. The republish failed
// ("can't addTransceiver!"): video gone for good, isCameraEnabled still true -
// the field symptom "the host's video is black for viewers".
//
// Root cause (every platform, foreground too - a host on a truly poor uplink hit
// it the same way): removePublishedTrack always ends in pub.dispose(), and a
// LocalTrackPublication disposes its track. The track is stopped and
// flutter_webrtc forgets it (`trackDispose`), whatever stopLocalTrackOnUnpublish
// says. Republishing it hands a dead track id to addTransceiver: iOS "can't
// addTransceiver!", Android "track is null". The background was only the
// trigger (a paused camera read as a poor network).
//
// With GravixRecoveryOptions.hostCameraGuard (default on):
//  - the profile changes IN PLACE: the camera sender's encodings get new
//    bitrate caps through setParameters, no unpublish (Pakhi's own data saver
//    has done this since 2026-10-05); a change that does not go through is
//    undone and reported;
//  - no quality sample counts while the app is not in the foreground or the
//    camera sent no frame since the previous sample, nor for 10 s after;
//  - a camera publication that is missing while the camera is on (lost in the
//    background, a failed rejoin republish) is published again on a fresh
//    capture, at most 3 tries 10 s apart; then the camera is reported off.
// Off: the 0.4.14 unpublish + republish, every sample counted, no restore. A
// republish that fails is rolled back in both modes (a fresh capture with the
// previous profile): the camera is never left unpublished while it is "on".

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc show RTCRtpEncoding, RTCRtpSender;

import '../rtc_core/gravix_client.dart';

/// What the data saver did to the host camera's publication.
enum GravixDataSaverEventKind {
  /// The low-data profile is on.
  engaged,

  /// The normal profile is back.
  released,

  /// A profile change failed; [GravixDataSaverEvent.error] says why. Nothing
  /// changed (in place) or the change is being rolled back (republish path).
  failed,

  /// A failed republish was undone: the camera is published again with the
  /// previous profile.
  rolledBack,

  /// The camera publication was missing while the camera was on, and was
  /// published again.
  cameraRestored,

  /// The camera publication could not be restored; the service now reports the
  /// camera as off (`isCameraEnabled` false).
  cameraLost,
}

/// One data-saver event (see [GravixDataSaverEventKind]).
@immutable
class GravixDataSaverEvent {
  const GravixDataSaverEvent(this.kind, {required this.lowData, this.error, required this.at});

  final GravixDataSaverEventKind kind;

  /// The profile the event is about (true = low data).
  final bool lowData;

  /// The failure, for [GravixDataSaverEventKind.failed] / [GravixDataSaverEventKind.cameraLost].
  final Object? error;

  final DateTime at;

  @override
  String toString() => 'GravixDataSaverEvent(${kind.name}, lowData: $lowData${error == null ? '' : ', error: $error'})';
}

/// Whether the host app counts as in the foreground for the data saver: the app
/// did not report a background (`GravixRoomService.setAppBackgrounded`) and
/// Flutter's lifecycle is `resumed` (or unknown: no binding). `inactive` does
/// not count: iOS passes through it on the way to the lock screen.
bool gravixHostInForeground({required bool appBackgrounded, required AppLifecycleState? state}) =>
    !appBackgrounded && (state == null || state == AppLifecycleState.resumed);

/// The automatic data saver of one service (one connected room at a time).
class GravixDataSaver {
  GravixDataSaver({
    required Room? Function() room,
    required this.cameraEnabled,
    required this.lowDataActive,
    required VideoPublishOptions Function(bool lowData) publishOptions,
    this.inForeground,
    this.reopenCamera,
    this.guard = true,
    this.onEvent,
    DateTime Function()? now,
  }) : _room = room,
       _publishOptions = publishOptions,
       _now = now ?? DateTime.now;

  static const Duration poorEngage = Duration(seconds: 10);
  static const Duration goodRestore = Duration(seconds: 45);
  static const Duration minSwitchGap = Duration(seconds: 60);
  static const Duration tickInterval = Duration(seconds: 3);

  /// After a paused sample: the SFU's score still describes the camera that
  /// sent nothing (it lags by a scoring window or two).
  static const Duration resumeGrace = Duration(seconds: 10);

  /// Restoring a lost camera publication: the gap between tries, and how many.
  static const Duration reopenGap = Duration(seconds: 10);
  static const int maxReopens = 3;

  /// Lower simulcast rungs under the data saver (in place): this share of their
  /// bitrate (the top rung gets the low profile's cap).
  static const double lowerRungScale = 0.6;

  final Room? Function() _room;
  final VideoPublishOptions Function(bool lowData) _publishOptions;
  final DateTime Function() _now;

  /// The service's camera flag (`GravixRoomService.isCameraEnabled`).
  final ValueNotifier<bool> cameraEnabled;

  /// The service's `lowDataActive`.
  final ValueNotifier<bool> lowDataActive;

  /// Whether the app is in the foreground. Null = always.
  final bool Function()? inForeground;

  /// Publishes a fresh camera track (the service's camera-on path); true when
  /// the camera is published after it.
  final Future<bool> Function()? reopenCamera;

  /// `GravixRecoveryOptions.hostCameraGuard`; see the file comment.
  final bool guard;

  final void Function(GravixDataSaverEvent event)? onEvent;

  Timer? _timer;

  /// Between [stop] (the room is being left) and the next [start]: no restore.
  bool _stopped = false;
  DateTime? _poorSince;
  DateTime? _goodSince;
  DateTime _lastProfileSwitch = DateTime.fromMillisecondsSinceEpoch(0);

  /// One change at a time: a profile switch or a camera restore.
  bool _busy = false;

  /// lowDataActive when the room was joined (the connect's lowDataMode): the
  /// profile a fresh camera publication gets.
  bool _startLowData = false;

  // in place
  String? _baselineSenderId;
  Map<String, int?> _baseline = const {};
  String? _seenSenderId;

  // paused camera
  DateTime? _graceUntil;
  bool _pausedLogged = false;
  Object? _framesTrack;
  num? _lastFrames;
  num? _lastStatsTs;

  // restore
  DateTime? _lastReopen;
  int _reopenFailures = 0;

  void start() {
    _stopped = false;
    _timer?.cancel();
    _poorSince = null;
    _goodSince = null;
    _graceUntil = null;
    _startLowData = lowDataActive.value;
    _reopenFailures = 0;
    _lastReopen = null;
    // a new room: nothing of the previous room's camera sender carries over
    _seenSenderId = null;
    _baselineSenderId = null;
    _baseline = const {};
    _framesTrack = null;
    _lastFrames = null;
    _lastStatsTs = null;
    _pausedLogged = false;
    _timer = Timer.periodic(tickInterval, (_) => tick());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _poorSince = null;
    _goodSince = null;
  }

  /// One quality sample. Completes when a change it started is done.
  Future<void> tick() async {
    final room = _room();
    final lp = room?.localParticipant;
    if (_stopped || room == null || lp == null || !cameraEnabled.value || _busy) return;
    final now = _now();

    if (guard) {
      // A camera the OS paused (iOS background / lock screen, the camera taken
      // by another app) sends nothing, and the SFU scores a silent camera poor:
      // that is not the network. Field 2026-10-11: this sample is what started
      // the fatal republish.
      if (!(inForeground?.call() ?? true)) {
        _pause(now, 'app not in the foreground');
        return;
      }
      final pub = lp.getTrackPublicationBySource(TrackSource.camera);
      if (pub == null) {
        await _restoreCamera(room, now);
        return;
      }
      final track = pub.track;
      if (track is LocalVideoTrack) {
        if (_captureStalled(track)) {
          _pause(now, 'no frame sent since the last sample: capture paused, or no layer subscribed');
          return;
        }
        final sender = track.sender;
        if (sender != null && sender.senderId != _seenSenderId) {
          // a new camera sender (camera reopened, rejoin republish) carries the
          // profile it was published with; the data saver's caps go on it too
          _seenSenderId = sender.senderId;
          if (lowDataActive.value) await _reapplyLow(sender, now);
        }
      }
      if (_graceUntil != null && now.isBefore(_graceUntil!)) {
        _poorSince = null;
        _goodSince = null;
        return;
      }
      if (_pausedLogged) {
        _pausedLogged = false;
        debugPrint('📶 auto data-saver: camera live again, quality samples count');
      }
    }

    final q = lp.connectionQuality;
    final isPoor = q == ConnectionQuality.poor || q == ConnectionQuality.lost;
    final isExcellent = q == ConnectionQuality.excellent;

    _poorSince = isPoor ? (_poorSince ?? now) : null;
    _goodSince = isExcellent ? (_goodSince ?? now) : null;

    if (now.difference(_lastProfileSwitch) < minSwitchGap) return;

    if (!lowDataActive.value && _poorSince != null && now.difference(_poorSince!) >= poorEngage) {
      await apply(lowData: true);
    } else if (lowDataActive.value && _goodSince != null && now.difference(_goodSince!) >= goodRestore) {
      await apply(lowData: false);
    }
  }

  /// The app came back to the foreground: the score is stale for a while, and a
  /// camera publication lost meanwhile is restored now rather than at the next
  /// tick.
  Future<void> onForeground() async {
    if (!guard || _stopped) return;
    final room = _room();
    final lp = room?.localParticipant;
    if (room == null || lp == null || !cameraEnabled.value || _busy) return;
    final now = _now();
    _graceUntil = now.add(resumeGrace);
    _poorSince = null;
    _goodSince = null;
    if (lp.getTrackPublicationBySource(TrackSource.camera) == null) await _restoreCamera(room, now);
  }

  /// Switch the camera to the low-data / normal profile.
  Future<void> apply({required bool lowData}) async {
    if (_busy) return;
    _busy = true;
    try {
      if (guard) {
        await _applyInPlace(lowData);
      } else {
        await _applyByRepublish(lowData);
      }
    } finally {
      _busy = false;
    }
  }

  // ── in place ───────────────────────────────────────────────────────────────

  Future<void> _applyInPlace(bool lowData) async {
    final lp = _room()?.localParticipant;
    final track = lp?.getTrackPublicationBySource(TrackSource.camera)?.track;
    if (lp == null || track is! LocalVideoTrack) return;
    final sender = track.sender;
    if (sender == null || (sender.parameters.encodings?.isEmpty ?? true)) {
      _failed(lowData, StateError('the camera sender has no encodings'));
      return;
    }
    debugPrint(
      '📶 auto data-saver: switching to '
      '${lowData ? "LOW (600k top cap, in place)" : "NORMAL (in place)"} '
      '(quality=${lp.connectionQuality})',
    );
    final error = await _setCaps(sender, lowData: lowData);
    if (error != null) {
      _failed(lowData, error);
      return;
    }
    _seenSenderId = sender.senderId;
    lowDataActive.value = lowData;
    _switched();
    _emit(lowData ? GravixDataSaverEventKind.engaged : GravixDataSaverEventKind.released, lowData: lowData);
  }

  Future<void> _reapplyLow(rtc.RTCRtpSender sender, DateTime now) async {
    if (sender.parameters.encodings?.isEmpty ?? true) return;
    _busy = true;
    try {
      final error = await _setCaps(sender, lowData: true);
      if (error != null) {
        // the state must say what the sender sends
        lowDataActive.value = false;
        _failed(true, error);
      }
    } finally {
      _busy = false;
    }
  }

  /// Sets every layer's bitrate cap for [lowData]: the top layer (sent at full
  /// size) to the low profile's cap / the normal profile's, lower rungs to
  /// [lowerRungScale] of what they were published with / back to that. `active`
  /// is left alone (dynacast owns it; it mutates the same cached parameters, so
  /// these caps survive its layer toggles). Returns the error; on one, the
  /// parameters are put back: flutter_webrtc caches what setParameters was
  /// given even when the native call fails, and the next unrelated
  /// setParameters would apply it.
  Future<Object?> _setCaps(rtc.RTCRtpSender sender, {required bool lowData}) async {
    final params = sender.parameters;
    final encodings = params.encodings!;
    if (_baselineSenderId != sender.senderId) {
      _baselineSenderId = sender.senderId;
      _baseline = {for (final e in encodings) e.rid ?? '': e.maxBitrate};
    }
    final before = [for (final e in encodings) e.maxBitrate];
    final top = _topIndex(encodings);
    final lowTop = _publishOptions(true).videoEncoding?.maxBitrate;
    final normalTop = _publishOptions(false).videoEncoding?.maxBitrate;
    for (var i = 0; i < encodings.length; i++) {
      final e = encodings[i];
      final base = _baseline[e.rid ?? ''] ?? e.maxBitrate;
      if (i == top) {
        e.maxBitrate = lowData
            ? (base == null || lowTop == null ? (lowTop ?? base) : (base < lowTop ? base : lowTop))
            : (normalTop ?? base);
      } else {
        e.maxBitrate = (lowData && base != null) ? (base * lowerRungScale).round() : base;
      }
    }
    Object? error;
    try {
      if (!await sender.setParameters(params)) error = StateError('setParameters returned false');
    } catch (e) {
      error = e;
    }
    if (error != null) {
      for (var i = 0; i < encodings.length; i++) {
        encodings[i].maxBitrate = before[i];
      }
    }
    return error;
  }

  /// The encoding sent at full size: the smallest scale-down (rids are given
  /// low to high, so with two layers the top one is 'h', not 'f').
  static int _topIndex(List<rtc.RTCRtpEncoding> encodings) {
    var top = 0;
    for (var i = 1; i < encodings.length; i++) {
      if ((encodings[i].scaleResolutionDownBy ?? 1) <= (encodings[top].scaleResolutionDownBy ?? 1)) top = i;
    }
    return top;
  }

  // ── republish (guard off: the 0.4.14 path) ──────────────────────────────────

  Future<void> _applyByRepublish(bool lowData) async {
    final lp = _room()?.localParticipant;
    final pub = lp?.getTrackPublicationBySource(TrackSource.camera);
    final track = pub?.track;
    if (lp == null || pub == null || track is! LocalVideoTrack) return;

    debugPrint(
      '📶 auto data-saver: switching to '
      '${lowData ? "LOW (single-layer 600k)" : "NORMAL (simulcast 800k)"} '
      '(quality=${lp.connectionQuality})',
    );
    try {
      // NOTE: this unpublish disposes the track (pub.dispose()), so the republish
      // of the same track below fails on every platform; kept as the rollback
      // flag's exact 0.4.14 attempt.
      await lp.removePublishedTrack(pub.sid);
      await lp.publishVideoTrack(track, publishOptions: _publishOptions(lowData));
      lowDataActive.value = lowData;
      _switched();
      _emit(lowData ? GravixDataSaverEventKind.engaged : GravixDataSaverEventKind.released, lowData: lowData);
    } catch (e) {
      debugPrint('Error applying publish profile: $e');
      _failed(lowData, e);
      if (lp.getTrackPublicationBySource(TrackSource.camera) != null) return;
      // ROLLBACK (2026-10-11, a pure bug fix in both modes): the camera was
      // left unpublished while isCameraEnabled said on. Publish a fresh capture
      // (the old one is disposed) with the profile the room was joined with.
      final ok = await _reopen();
      if (ok) {
        lowDataActive.value = _startLowData;
        _emit(GravixDataSaverEventKind.rolledBack, lowData: _startLowData);
      } else {
        cameraEnabled.value = false;
        _emit(GravixDataSaverEventKind.cameraLost, lowData: lowData, error: e);
      }
    }
  }

  // ── paused camera ──────────────────────────────────────────────────────────

  void _pause(DateTime now, String why) {
    _poorSince = null;
    _goodSince = null;
    _graceUntil = now.add(resumeGrace);
    if (!_pausedLogged) {
      _pausedLogged = true;
      debugPrint('📶 auto data-saver: camera paused ($why): quality samples ignored');
    }
  }

  /// No frame left the camera's encoder since the previous sample. Reads the
  /// stats the track already polls every 2 s (no new poll). Unknown (no stats,
  /// a layer without framesSent, the poll not advancing) is not a pause.
  bool _captureStalled(LocalVideoTrack track) {
    if (!identical(_framesTrack, track)) {
      _framesTrack = track;
      _lastFrames = null;
      _lastStatsTs = null;
    }
    final stats = track.prevStats;
    if (stats == null || stats.isEmpty) {
      _lastFrames = null;
      return false;
    }
    num frames = 0;
    num ts = 0;
    for (final s in stats.values) {
      final f = s.framesSent;
      if (f == null) {
        _lastFrames = null;
        return false;
      }
      frames += f;
      if (s.timestamp > ts) ts = s.timestamp;
    }
    final prevFrames = _lastFrames;
    final prevTs = _lastStatsTs;
    _lastFrames = frames;
    _lastStatsTs = ts;
    if (prevFrames == null || prevTs == null) return false;
    return ts > prevTs && frames == prevFrames;
  }

  // ── restore a lost camera publication ──────────────────────────────────────

  Future<void> _restoreCamera(Room room, DateTime now) async {
    if (reopenCamera == null || _busy || _stopped) return;
    final lp = room.localParticipant;
    // not while a rejoin is republishing the tracks: its publications are
    // missing on purpose for a moment
    if (lp == null ||
        room.connectionState != ConnectionState.connected ||
        room.engine.gravixFullReconnectInProgress ||
        lp.gravixRepublishPending(TrackSource.camera)) {
      return;
    }
    final last = _lastReopen;
    if (last != null && now.difference(last) < reopenGap) return;
    _lastReopen = now;
    debugPrint('📶 auto data-saver: the camera is on but not published: reopening it');
    _busy = true;
    Object? error;
    var ok = false;
    try {
      ok = await reopenCamera!();
    } catch (e) {
      error = e;
    } finally {
      _busy = false;
    }
    ok = ok && lp.getTrackPublicationBySource(TrackSource.camera) != null;
    if (ok) {
      _reopenFailures = 0;
      _emit(GravixDataSaverEventKind.cameraRestored, lowData: lowDataActive.value);
      return;
    }
    if (++_reopenFailures >= maxReopens) {
      _reopenFailures = 0;
      // isCameraEnabled follows the publication: the app must not show "camera
      // on" for a camera nobody receives
      cameraEnabled.value = false;
      _emit(GravixDataSaverEventKind.cameraLost, lowData: lowDataActive.value, error: error);
    }
  }

  Future<bool> _reopen() async {
    final reopen = reopenCamera;
    if (reopen == null) return false;
    try {
      return await reopen();
    } catch (e) {
      debugPrint('📶 auto data-saver: camera reopen failed: $e');
      return false;
    }
  }

  // ── bookkeeping ────────────────────────────────────────────────────────────

  void _switched() {
    _lastProfileSwitch = _now();
    _poorSince = null;
    _goodSince = null;
  }

  void _failed(bool lowData, Object error) {
    debugPrint('📶 auto data-saver: ${lowData ? "LOW" : "NORMAL"} not applied: $error');
    // no new attempt for the switch gap: not every 3 s
    _switched();
    _emit(GravixDataSaverEventKind.failed, lowData: lowData, error: error);
  }

  void _emit(GravixDataSaverEventKind kind, {required bool lowData, Object? error}) {
    final e = GravixDataSaverEvent(kind, lowData: lowData, error: error, at: _now());
    try {
      onEvent?.call(e);
    } catch (err) {
      debugPrint('onDataSaverEvent threw: $err');
    }
  }
}

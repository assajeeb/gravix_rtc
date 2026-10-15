// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixRejoinPolicy (0.4.19): a viewer joins again by itself when its session
// ended while the live is still on, or when the live comes back (moved from the
// apps; the policy is RTC-only, the app supplies "is the live on" and the join).
//
// Field 2026-10-13: the host left a video room (the live ended with it), the
// viewer's screen showed the end and left its session; the host went live again
// on the same room 33 s later; the viewer's screen went back to the stage but
// nothing joined again: "waiting for the host's video" forever.
//
// Rules (each from a review or a field case, 2026-10-13/14):
//  - only a transport-style end is rejoined (rejoinable): never after a kick, the
//    same identity joining elsewhere (two phones of one account would kick each
//    other forever), a deleted room, a refused join or our own leave;
//  - backoff 1, 2, 4, 8 s, re-checking liveOn before every attempt; when every
//    attempt failed, onGaveUp (the screen shows a Retry);
//  - at most maxPerIncident rejoins follow each other while every session ends
//    again within stableAfter (one incident);
//  - at most maxTotal attempts per live on one screen (a join dropped right after
//    it connects, again and again, cannot loop); liveBack starts a new budget;
//  - an optional entry check (mayRejoin: the app's kick / ban rules) before every
//    attempt: false = never again on this screen; a check slower than
//    mayRejoinTimeout counts as "go ahead" (a stalled backend must not stall the
//    backoff while the network is coming back);
//  - a rejoin refused because the room cannot be joined with this SDK (0.4.19,
//    owner 2026-10-15: rooms of old app builds on the old server, "not to
//    count"): a RetiredServerException, a GravixRoomRefused or the app's
//    isRefusal, thrown by rejoin(): not a failed attempt (not counted), no
//    backoff retry, no onGaveUp (a Retry cannot join it); onRefused; liveBack
//    may try again.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rtc_core/src/types/other.dart' show DisconnectReason;
import 'gravix_join_log.dart';
import 'gravix_room_refused.dart';

/// See the file comment. One per room screen; the screen calls [liveEnded],
/// [liveBack], [sessionEnded] and [joined], and [dispose] with itself.
class GravixRejoinPolicy {
  GravixRejoinPolicy({
    required this.rejoin,
    required this.liveOn,
    this.mayRejoin,
    this.onGaveUp,
    this.isRefusal,
    this.onRefused,
    this.backoff = const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8)],
    this.maxPerIncident = 3,
    this.stableAfter = const Duration(seconds: 60),
    this.maxTotal = 12,
    this.mayRejoinTimeout = const Duration(seconds: 3),
    DateTime Function()? now,
    void Function(String line)? log,
  }) : assert(backoff.isNotEmpty),
       _now = now ?? DateTime.now,
       _sink = log;

  /// Whether a session that ended with [reason] may be joined again: not after a
  /// kick / block, the same identity joining elsewhere, a deleted room, a refused
  /// join, our own leave, nor the call-only ends that never apply to a room
  /// viewer. Exhaustive: a new SDK reason is a compile error until decided.
  static bool rejoinable(DisconnectReason? reason) => switch (reason) {
    null ||
    DisconnectReason.unknown ||
    DisconnectReason.disconnected ||
    DisconnectReason.signalingConnectionFailure ||
    DisconnectReason.reconnectAttemptsExceeded ||
    DisconnectReason.signalClose ||
    DisconnectReason.connectionTimeout ||
    DisconnectReason.mediaFailure ||
    DisconnectReason.stateMismatch ||
    DisconnectReason.serverShutdown ||
    DisconnectReason.migration ||
    DisconnectReason.roomClosed => true,
    DisconnectReason.clientInitiated ||
    DisconnectReason.participantRemoved ||
    DisconnectReason.duplicateIdentity ||
    DisconnectReason.roomDeleted ||
    DisconnectReason.joinFailure ||
    DisconnectReason.userUnavailable ||
    DisconnectReason.userRejected ||
    DisconnectReason.sipTrunkFailure ||
    DisconnectReason.agentError => false,
  };

  /// One full join (a fresh token, a connect); true when connected. It lands on
  /// the host's NEW session and subscribes to its new tracks.
  final Future<bool> Function() rejoin;

  /// The live is on (the app's own room state).
  final bool Function() liveOn;

  /// The app's entry check before every attempt (kick / ban); false stops every
  /// rejoin on this screen. A throw counts as "go ahead".
  final Future<bool> Function()? mayRejoin;

  /// Every attempt failed while the live was on, or a cap was reached.
  final VoidCallback? onGaveUp;

  /// The app's own refusals among what [rejoin] throws (given the error
  /// unwrapped from a `GravixTokenException`; pass the same as
  /// `GravixJoin.isRefusal`). Built in besides it: `RetiredServerException`,
  /// [GravixRoomRefused]. A refused rejoin is not a failed attempt (see the
  /// file comment).
  final bool Function(Object unwrappedError)? isRefusal;

  /// A rejoin was refused (the app's unwrapped error, e.g. to show its "the
  /// host uses an old app version" message). No retry follows; no [onGaveUp].
  final void Function(Object error)? onRefused;

  final List<Duration> backoff;

  /// Rejoins that may follow each other while each session ends again before
  /// [stableAfter] (one incident).
  final int maxPerIncident;

  /// A session that stayed up this long ends the incident.
  final Duration stableAfter;

  /// Attempts per live on this screen ([liveBack] starts a new budget).
  final int maxTotal;

  /// See the file comment.
  final Duration mayRejoinTimeout;

  final DateTime Function() _now;
  // [GravixJoinLog] lines (`[GravixJoin] rejoin...`); null: GravixJoinLog.sink
  final GravixJoinLogSink? _sink;

  void _log(String step, String detail, {GravixJoinLogLevel at = GravixJoinLogLevel.info}) =>
      GravixJoinLog.step(step, detail: detail, at: at, to: _sink);

  Timer? _timer;
  int _attempt = 0;
  int _total = 0;
  int _incidentRejoins = 0;
  bool _incidentGaveUp = false;
  DateTime? _joinedAt;
  bool _refused = false;
  bool _roomRefused = false;
  bool _running = false;
  bool _disposed = false;
  bool _ended = false;

  /// A rejoin is scheduled or running.
  bool get pending => _timer != null || _running;

  /// Rejoin attempts since the last successful join.
  int get attempts => _attempt;

  /// Rejoin attempts on this screen in this live.
  int get total => _total;

  /// [mayRejoin] refused: this screen never rejoins again.
  bool get refused => _refused;

  /// The last rejoin was refused (the room cannot be joined with this SDK):
  /// nothing rejoins until [liveBack].
  bool get roomRefused => _roomRefused;

  /// The live ended: nothing rejoins until [liveBack].
  void liveEnded() {
    _ended = true;
    _cancel();
    _attempt = 0;
  }

  /// The live is on again after [liveEnded] (the host went live again): join now.
  void liveBack() {
    if (_disposed || _refused || !_ended) return;
    _ended = false;
    _roomRefused = false;
    _attempt = 0;
    _total = 0;
    _resetIncident();
    _log('rejoinLiveBack', 'joining again');
    _schedule(Duration.zero, 'liveBack');
  }

  /// The session ended by itself ([reason]: the SDK's, null when unknown) while
  /// the screen is up -- not our own leave or minimise. True when a rejoin is
  /// scheduled.
  bool sessionEnded([DisconnectReason? reason]) {
    if (_disposed || _refused || _roomRefused || _ended || pending) {
      _log(
        'rejoinRefused',
        'why=${_disposed
            ? 'disposed'
            : _refused
            ? 'refused before'
            : _roomRefused
            ? 'room refused before'
            : _ended
            ? 'live ended'
            : 'already pending'}',
        at: GravixJoinLogLevel.verbose,
      );
      return false;
    }
    if (!rejoinable(reason)) {
      _log('rejoinRefused', 'why=not after ${reason?.name}');
      return false;
    }
    if (!liveOn()) {
      _log('rejoinRefused', 'why=live is off');
      return false;
    }
    final joinedAt = _joinedAt;
    // a session that stayed up ends the incident; a give-up stays until the live
    // comes back
    if (!_incidentGaveUp && joinedAt != null && _now().difference(joinedAt) >= stableAfter) _resetIncident();
    if (_incidentRejoins >= maxPerIncident) {
      if (!_incidentGaveUp) {
        _incidentGaveUp = true;
        _log('rejoinGaveUp', 'why=$_incidentRejoins rejoins each ended at once');
        onGaveUp?.call();
      }
      return false;
    }
    _schedule(_delay(), reason?.name ?? 'unknown');
    return true;
  }

  /// A join succeeded (also the screen's own: the first join, a Retry): the next
  /// drop gets the full backoff again.
  void joined() {
    _attempt = 0;
  }

  void dispose() {
    _disposed = true;
    _cancel();
  }

  void _resetIncident() {
    _incidentRejoins = 0;
    _incidentGaveUp = false;
    _joinedAt = null;
  }

  Duration _delay() => backoff[_attempt < backoff.length ? _attempt : backoff.length - 1];

  void _schedule(Duration d, String after) {
    _log('rejoinScheduled', 'n=${_attempt + 1} in=${d.inMilliseconds}ms after=$after');
    _cancel();
    _timer = Timer(d, () => unawaited(_run()));
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _run() async {
    _timer = null;
    if (_disposed || _refused || _roomRefused || _ended || !liveOn()) return;
    if (_total >= maxTotal) {
      _log('rejoinGaveUp', 'why=cap of $maxTotal attempts');
      onGaveUp?.call();
      return;
    }
    _running = true;
    final check = mayRejoin;
    if (check != null) {
      var allowed = true;
      try {
        allowed = await check().timeout(mayRejoinTimeout);
      } catch (e) {
        _log('rejoinCheck', 'failed (${e.runtimeType}), joining anyway');
      }
      if (!allowed) {
        _running = false;
        _refused = true;
        _cancel();
        _log('rejoinRefused', 'why=entry check');
        return;
      }
      if (_disposed || _ended || !liveOn()) {
        _running = false;
        return;
      }
    }
    _attempt++;
    _total++;
    _log('rejoinAttempt', 'n=$_attempt total=$_total');
    var ok = false;
    var threw = false;
    try {
      ok = await rejoin();
    } catch (e) {
      threw = true;
      if (GravixRoomRefused.classify(e, isRefusal)) {
        // not a failed attempt: uncounted, no retry, no give-up
        _running = false;
        _attempt--;
        _total--;
        _roomRefused = true;
        final cause = GravixRoomRefused.unwrap(e);
        _log('rejoinRefused', 'why=room refused (${cause.runtimeType})');
        if (!_disposed) onRefused?.call(cause);
        return;
      }
      _log('rejoinFail', 'n=$_attempt err=${e.runtimeType}');
    } finally {
      _running = false;
    }
    if (!threw) _log(ok ? 'rejoinOk' : 'rejoinFail', ok ? 'n=$_attempt' : 'n=$_attempt connected=false');
    if (_disposed || _ended) return;
    if (ok) {
      _incidentRejoins++;
      _joinedAt = _now();
      joined();
      return;
    }
    if (!liveOn()) return;
    if (_attempt >= backoff.length) {
      _log('rejoinGaveUp', 'why=all $_attempt attempts failed');
      onGaveUp?.call();
      return;
    }
    _schedule(_delay(), 'retry');
  }
}

/// One connect that leaves nothing behind when the screen that asked for it is
/// gone: [alive] is checked before [connect] (no connect for a closed screen)
/// and after it (a session joined while the screen closed is left again with
/// [disconnect]). True only when connected for a screen that is still there.
Future<bool> gravixConnectWhileAlive({
  required bool Function() alive,
  required Future<bool> Function() connect,
  required Future<void> Function() disconnect,
}) async {
  if (!alive()) return false;
  final ok = await connect();
  if (!alive()) {
    if (ok) await disconnect();
    return false;
  }
  return ok;
}

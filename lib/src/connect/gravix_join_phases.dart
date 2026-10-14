// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../rtc_core/src/core/room.dart';
import '../rtc_core/src/core/signal_client.dart' show SignalClient;
import '../rtc_core/src/events.dart';
import '../rtc_core/src/internal/events.dart';
import '../rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import '../rtc_core/src/types/other.dart';

/// The steps of a join an app that drives [Room] itself can observe (0.4.8).
///
/// Up to 0.4.7 the only way to see them was to subscribe to `@internal` events
/// on `room.engine.signalClient` (an app's join trace did exactly that, with
/// `ignore_for_file: invalid_use_of_internal_member`). These names are the
/// stable, exported surface; the internals behind them may change.
enum GravixJoinPhase {
  /// The signal client is about to dial the WebSocket (DNS + TCP + TLS + upgrade
  /// follow, or one round trip over a standby connection).
  wsConnecting,

  /// The signalling WebSocket is open. `detail['standby']`: the standby
  /// pre-connect outcome (`used`, `none`, `stalled_redialed`, ...) when the
  /// platform has one; `detail['signalIsolate']`: whether the socket lives in
  /// the signal isolate, only while `GravixSignalIsolate.enabled` is on.
  wsOpen,

  /// The SFU's JoinResponse arrived; the local participant exists from here.
  /// `detail`: `serverRegion`, `serverVersion`, `subscriberPrimary`,
  /// `fastPublish` (the SFU lets the publisher connection negotiate right now),
  /// `otherParticipants`.
  joinResponse,

  /// The PRIMARY peer connection is connected: ICE **and** DTLS done (what
  /// `Room.connect` waits for). Not "ICE only": on libwebrtc the connection-state
  /// callback that would mark the end of ICE fires after DTLS (see
  /// doc/JOIN_TIMELINE.md); the ICE/DTLS split needs `getStats()` polling, which
  /// `GravixRoomService`'s join timeline does. `detail['transport']`:
  /// `subscriber` or `publisher`.
  peerConnected,

  /// The publisher peer connection is connected (ICE + DTLS): from here a
  /// published track's media can leave the device. In a two-connection session
  /// it is the second connection; [peerConnected] when the publisher is primary.
  publisherConnected,

  /// The subscriber peer connection is connected (ICE + DTLS).
  subscriberConnected,

  /// The first local AUDIO track was published (the SFU accepted its AddTrack).
  /// `detail['source']`.
  localAudioPublished,

  /// The microphone of a join with `Room.connect(joinMicrophone: ...)` (or
  /// `GravixRoomService.connect(publishMicOnJoin: true)`) was published inside
  /// the join. `detail['inFirstOffer']`: true when the microphone was part of
  /// the publisher connection's first offer (it flows as soon as
  /// [publisherConnected] is reached); false when its capture was not ready in
  /// time and it was published with an offer of its own. `detail['attempt']`:
  /// the join attempt (1 = the first). [localAudioPublished] is reported too.
  micPublishedInJoin,

  /// The camera of a join with `Room.connect(joinCamera: ...)` was published
  /// inside the join. `detail['inFirstOffer']`: true when the camera was part of
  /// the publisher connection's first offer; false when it was published with an
  /// offer of its own (not ready within `GravixJoinCamera.offerWait`, or the
  /// server announced no publish codecs). `detail['attempt']`: the join attempt.
  /// [localVideoPublished] is reported too.
  cameraPublishedInJoin,

  /// The first local VIDEO track was published (the SFU accepted its AddTrack).
  /// Media flows once [publisherConnected] is reached as well: "camera live" is
  /// the later of the two (see [GravixJoinPhases.cameraLiveAt]).
  localVideoPublished,

  /// The first remote AUDIO track was subscribed.
  remoteAudioSubscribed,

  /// The first remote VIDEO track was subscribed.
  remoteVideoSubscribed,
}

/// One [GravixJoinPhase], first time reached in this join.
@immutable
class GravixJoinPhaseEvent {
  const GravixJoinPhaseEvent({required this.phase, required this.at, required this.elapsed, this.detail = const {}});

  final GravixJoinPhase phase;

  /// Wall clock when the SDK saw it.
  final DateTime at;

  /// Since [GravixJoinPhases.startedAt] (the attach, the last [GravixJoinPhases.reset],
  /// or the `startedAt` the app passed, e.g. its tap), on a monotonic clock.
  final Duration elapsed;

  final Map<String, Object?> detail;

  Map<String, Object?> toJson() => {
    'phase': phase.name,
    'at': at.toUtc().toIso8601String(),
    'ms': elapsed.inMilliseconds,
    if (detail.isNotEmpty) 'detail': detail,
  };

  @override
  String toString() => '+${elapsed.inMilliseconds} ${phase.name}${detail.isEmpty ? '' : ' $detail'}';
}

/// Join-phase hooks for one [Room]: attach BEFORE `room.connect`, read
/// [events] / [onPhase], dispose when done. Each phase is reported once per join
/// (the first time it is reached); call [reset] before connecting the same Room
/// again. Observation only: nothing on the wire changes and nothing is polled.
///
/// ```dart
/// final phases = room.watchJoinPhases(startedAt: tapAt, onPhase: (e) => log('$e'));
/// await room.connect(url, token);
/// ...
/// await phases.dispose();
/// ```
class GravixJoinPhases {
  GravixJoinPhases.attach(Room room, {DateTime? startedAt, this.onPhase}) : _room = room {
    _start(startedAt);
    final engine = room.engine;
    final signal = engine.signalClient;
    _cancels
      ..add(signal.events.on<SignalConnectingEvent>((_) => _note(GravixJoinPhase.wsConnecting)))
      ..add(
        signal.events.on<SignalConnectedEvent>((_) {
          final outcome = signal.gravixStandby?['outcome'];
          final viaIsolate = signal.gravixStandby?['signalIsolate'];
          _note(GravixJoinPhase.wsOpen, {'standby': ?outcome, 'signalIsolate': ?viaIsolate});
        }),
      )
      ..add(signal.events.on<SignalJoinResponseEvent>((e) => debugNoteJoinResponse(e.response)))
      ..add(
        engine.events.on<EnginePeerStateUpdatedEvent>((e) {
          if (e.state != rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) return;
          debugNotePeerConnected(publisher: e is EnginePublisherPeerStateUpdatedEvent, isPrimary: e.isPrimary);
        }),
      )
      ..add(
        engine.events.on<EngineJoinCameraPublishedEvent>(
          (e) => debugNoteJoinCameraPublished(inFirstOffer: e.inFirstOffer, attempt: e.attempt),
        ),
      )
      ..add(
        engine.events.on<EngineJoinMicPublishedEvent>(
          (e) => debugNoteJoinMicPublished(inFirstOffer: e.inFirstOffer, attempt: e.attempt),
        ),
      )
      ..add(
        room.events.on<LocalTrackPublishedEvent>(
          (e) => debugNoteLocalPublished(e.publication.kind, source: e.publication.source.name),
        ),
      )
      ..add(room.events.on<TrackSubscribedEvent>((e) => debugNoteRemoteSubscribed(e.publication.kind)));
  }

  final Room _room;

  /// Called for every phase, as it is reached (also on [events]).
  final void Function(GravixJoinPhaseEvent event)? onPhase;

  final _ctrl = StreamController<GravixJoinPhaseEvent>.broadcast();
  final _cancels = <CancelListenFunc>[];
  final _reached = <GravixJoinPhase, GravixJoinPhaseEvent>{};
  final _clock = Stopwatch();
  late DateTime _startedAt;
  Duration _startOffset = Duration.zero;
  bool _disposed = false;

  /// The Room these hooks watch.
  Room get room => _room;

  /// Every phase as it is reached (broadcast).
  Stream<GravixJoinPhaseEvent> get events => _ctrl.stream;

  /// The zero of [GravixJoinPhaseEvent.elapsed].
  DateTime get startedAt => _startedAt;

  /// The phases reached so far in this join, first occurrence each.
  Map<GravixJoinPhase, GravixJoinPhaseEvent> get reached => Map.unmodifiable(_reached);

  /// When a published camera could first send media: the later of
  /// [GravixJoinPhase.localVideoPublished] and [GravixJoinPhase.publisherConnected]
  /// (`elapsed`). Null until both are reached.
  Duration? get cameraLiveAt => _laterOf(GravixJoinPhase.localVideoPublished);

  /// Same as [cameraLiveAt] for the microphone.
  Duration? get micLiveAt => _laterOf(GravixJoinPhase.localAudioPublished);

  /// A new join on the same Room: forgets what was reached and restarts the clock
  /// (at [startedAt] when given, e.g. the tap, else now).
  void reset({DateTime? startedAt}) {
    _reached.clear();
    _start(startedAt);
  }

  /// Stops listening and closes [events]. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final c in _cancels) {
      c();
    }
    _cancels.clear();
    await _ctrl.close();
  }

  void _start(DateTime? startedAt) {
    final now = DateTime.now();
    _startedAt = startedAt ?? now;
    // a startedAt in the past (the tap) counts from there on the monotonic clock
    final back = now.difference(_startedAt);
    _startOffset = back.isNegative ? Duration.zero : back;
    _clock
      ..reset()
      ..start();
  }

  Duration? _laterOf(GravixJoinPhase published) {
    final a = _reached[published]?.elapsed;
    final b = _reached[GravixJoinPhase.publisherConnected]?.elapsed;
    if (a == null || b == null) return null;
    return a > b ? a : b;
  }

  void _note(GravixJoinPhase phase, [Map<String, Object?> detail = const {}]) {
    if (_disposed || _reached.containsKey(phase)) return;
    final event = GravixJoinPhaseEvent(
      phase: phase,
      at: DateTime.now(),
      elapsed: _startOffset + _clock.elapsed,
      detail: Map.unmodifiable(detail),
    );
    _reached[phase] = event;
    _ctrl.add(event);
    try {
      onPhase?.call(event);
    } catch (e) {
      debugPrint('GravixJoinPhases.onPhase threw: $e');
    }
  }

  /// The mapping from a connected peer connection to phases. Public for tests
  /// (the engine event behind it is internal); not part of the app surface.
  @visibleForTesting
  void debugNotePeerConnected({required bool publisher, required bool isPrimary}) {
    final transport = publisher ? 'publisher' : 'subscriber';
    if (isPrimary) _note(GravixJoinPhase.peerConnected, {'transport': transport});
    _note(publisher ? GravixJoinPhase.publisherConnected : GravixJoinPhase.subscriberConnected);
  }

  /// See [debugNotePeerConnected].
  @visibleForTesting
  void debugNoteJoinResponse(lk_rtc.JoinResponse r) => _note(GravixJoinPhase.joinResponse, {
    'serverRegion': r.serverRegion,
    'serverVersion': r.serverVersion,
    'subscriberPrimary': r.subscriberPrimary,
    'fastPublish': r.fastPublish,
    'otherParticipants': r.otherParticipants.length,
  });

  /// See [debugNotePeerConnected].
  @visibleForTesting
  void debugNoteLocalPublished(TrackType kind, {String? source}) {
    final d = {'source': ?source};
    if (kind == TrackType.AUDIO) _note(GravixJoinPhase.localAudioPublished, d);
    if (kind == TrackType.VIDEO) _note(GravixJoinPhase.localVideoPublished, d);
  }

  /// See [debugNotePeerConnected].
  @visibleForTesting
  void debugNoteJoinMicPublished({required bool inFirstOffer, required int attempt}) =>
      _note(GravixJoinPhase.micPublishedInJoin, {'inFirstOffer': inFirstOffer, 'attempt': attempt});

  /// See [debugNotePeerConnected].
  @visibleForTesting
  void debugNoteJoinCameraPublished({required bool inFirstOffer, required int attempt}) =>
      _note(GravixJoinPhase.cameraPublishedInJoin, {'inFirstOffer': inFirstOffer, 'attempt': attempt});

  /// See [debugNotePeerConnected].
  @visibleForTesting
  void debugNoteRemoteSubscribed(TrackType kind) {
    if (kind == TrackType.AUDIO) _note(GravixJoinPhase.remoteAudioSubscribed);
    if (kind == TrackType.VIDEO) _note(GravixJoinPhase.remoteVideoSubscribed);
  }
}

/// `room.watchJoinPhases(...)` = [GravixJoinPhases.attach]; plus the signalling
/// round trip, which apps read from `room.engine.signalClient.rtt` (internal).
extension GravixRoomJoinPhases on Room {
  /// Attach BEFORE `connect`. See [GravixJoinPhases].
  GravixJoinPhases watchJoinPhases({DateTime? startedAt, void Function(GravixJoinPhaseEvent event)? onPhase}) =>
      GravixJoinPhases.attach(this, startedAt: startedAt, onPhase: onPhase);

  /// The signalling WebSocket's round trip in ms, as last measured by the
  /// ping/pong (0 before the first pong). Replaces `room.engine.signalClient.rtt`.
  ///
  /// With `GravixSignalIsolate` on (2026-10-13) it is the network's round trip:
  /// the signal isolate stamps the ping's write and the pong's arrival, so the
  /// app isolate's own work in between is not counted. With it off it is
  /// stamped on the app's isolate, and a busy app isolate (startup work right
  /// after launch) adds its delay: see [signalRtt]`.networkOnly` and
  /// [signalRttMinMs].
  int get signalRttMs => engine.signalClient.rtt;

  /// The smallest of the last [GravixSignalRtt.window] round trips of the
  /// current signal connection, ms (0 before its first pong). A busy app
  /// isolate only ever adds to a sample, so the minimum is the closest to the
  /// network's (with the signal isolate off, as many busy pings in a row still
  /// inflate it). 2026-10-13.
  int get signalRttMinMs => signalRtt.minMs;

  /// The recent round trips, their count and how they were timed (2026-10-13).
  GravixSignalRtt get signalRtt {
    final sc = engine.signalClient;
    return GravixSignalRtt(recentMs: sc.rttRecent, count: sc.rttCount, networkOnly: sc.rttRecentNetworkOnly);
  }

  /// Sends one signalling ping now (2026-10-13), so a fresh [signalRttMs] is
  /// known one round trip later instead of at the next periodic ping (every
  /// 5 s on Gravix Cloud). For an app whose own work just ended -- a join
  /// done, its startup work over -- and whose earlier samples may carry that
  /// work's delay ([signalRtt]`.networkOnly` false). Returns whether a ping
  /// was sent: not when the room's signal connection is not up, when the
  /// server asked for no pings, or within 1 s of the last ping (its pong is on
  /// its way).
  bool requestSignalPing() => engine.signalClient.requestPing();
}

/// The signalling round trip's recent samples (`room.signalRtt`, 2026-10-13).
///
/// Field 2026-10-13 (a phone 6-10 ms from the SFU): joins tapped right after an
/// app opened read 221-1710 ms, the same joins from a settled app 10-30 ms --
/// the app's own startup work was counted. Over the signal isolate a sample is
/// the network's ([networkOnly]); otherwise an app that shows the number can
/// skip samples taken while it was busy ([count] tells new samples from old)
/// and show the [minMs] of the rest.
@immutable
class GravixSignalRtt {
  const GravixSignalRtt({required this.recentMs, required this.count, required this.networkOnly});

  /// How many recent samples [recentMs] keeps.
  static const window = SignalClient.rttWindow;

  /// The last [window] round trips of the current signal connection, ms,
  /// oldest first; empty before its first pong (a reconnect starts a new list).
  final List<int> recentMs;

  /// Round trips measured since the room's signal client was created; only
  /// grows. The samples taken since an earlier read are the last
  /// `count - earlierCount` of [recentMs] (at most all of them).
  final int count;

  /// Every sample in [recentMs] was timed in the signal isolate (the network
  /// only); false when one was timed on the app's isolate (its own delay
  /// included), and with no samples.
  final bool networkOnly;

  /// The last sample, ms (0: none).
  int get lastMs => recentMs.isEmpty ? 0 : recentMs.last;

  /// The smallest of [recentMs], ms (0: none).
  int get minMs => recentMs.isEmpty ? 0 : recentMs.reduce((a, b) => a < b ? a : b);

  @override
  String toString() => 'GravixSignalRtt(recent: $recentMs, count: $count, networkOnly: $networkOnly)';
}

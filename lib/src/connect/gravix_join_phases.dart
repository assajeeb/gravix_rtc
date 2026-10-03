// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../rtc_core/src/core/room.dart';
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
  /// platform has one.
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
          _note(GravixJoinPhase.wsOpen, {'standby': ?outcome});
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
  int get signalRttMs => engine.signalClient.rtt;
}

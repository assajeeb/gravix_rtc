// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.8 public join-phase hooks for apps that drive Room themselves (until
// now they read @internal room.engine.signalClient events for a join trace). The
// signal / engine events are emitted on a real Room's emitters; the room-event
// mapping (published / subscribed) goes through the debugNote* entry points,
// because a LocalTrackPublishedEvent needs a live publication.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Room room;
  late GravixJoinPhases phases;
  late List<GravixJoinPhaseEvent> seen;

  setUp(() {
    room = Room();
    seen = [];
    phases = room.watchJoinPhases(onPhase: seen.add);
  });

  tearDown(() async {
    await phases.dispose();
    await room.dispose();
  });

  const connected = rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected;

  test('signal + engine phases in order, with detail', () async {
    final signal = room.engine.signalClient;
    signal.events.emit(const SignalConnectingEvent());
    await _flush();
    signal.events.emit(const SignalConnectedEvent());
    await _flush();
    // (the engine's own JoinResponse handler would build peer connections: the
    // mapping is driven directly)
    phases.debugNoteJoinResponse(lk_rtc.JoinResponse(serverRegion: 'sgp1', fastPublish: true, subscriberPrimary: true));
    room.engine.events.emit(const EngineSubscriberPeerStateUpdatedEvent(state: connected, isPrimary: true));
    await _flush();
    room.engine.events.emit(const EnginePublisherPeerStateUpdatedEvent(state: connected, isPrimary: false));
    await _flush();

    expect(seen.map((e) => e.phase), [
      GravixJoinPhase.wsConnecting,
      GravixJoinPhase.wsOpen,
      GravixJoinPhase.joinResponse,
      GravixJoinPhase.peerConnected,
      GravixJoinPhase.subscriberConnected,
      GravixJoinPhase.publisherConnected,
    ]);
    final jr = phases.reached[GravixJoinPhase.joinResponse]!;
    expect(jr.detail['serverRegion'], 'sgp1');
    expect(jr.detail['fastPublish'], true);
    expect(jr.detail['subscriberPrimary'], true);
    expect(phases.reached[GravixJoinPhase.peerConnected]!.detail['transport'], 'subscriber');
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].elapsed >= seen[i - 1].elapsed, isTrue);
    }
  });

  test('a state other than connected is not a phase', () async {
    room.engine.events.emit(
      const EngineSubscriberPeerStateUpdatedEvent(
        state: rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
        isPrimary: true,
      ),
    );
    await _flush();
    expect(seen, isEmpty);
  });

  test('each phase once per join; reset starts a new join', () async {
    room.engine.signalClient.events.emit(const SignalConnectingEvent());
    await _flush();
    room.engine.signalClient.events.emit(const SignalConnectingEvent());
    await _flush();
    expect(seen.length, 1);
    phases.reset();
    expect(phases.reached, isEmpty);
    room.engine.signalClient.events.emit(const SignalConnectingEvent());
    await _flush();
    expect(seen.length, 2);
  });

  test('published / subscribed per kind; cameraLiveAt = later of published and publisher connected', () async {
    phases.debugNoteLocalPublished(TrackType.AUDIO, source: 'microphone');
    phases.debugNoteLocalPublished(TrackType.VIDEO, source: 'camera');
    phases.debugNoteRemoteSubscribed(TrackType.AUDIO);
    phases.debugNoteRemoteSubscribed(TrackType.VIDEO);
    phases.debugNoteRemoteSubscribed(TrackType.VIDEO);
    expect(phases.cameraLiveAt, isNull, reason: 'publisher not connected yet');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    phases.debugNotePeerConnected(publisher: true, isPrimary: false);
    expect(seen.map((e) => e.phase), [
      GravixJoinPhase.localAudioPublished,
      GravixJoinPhase.localVideoPublished,
      GravixJoinPhase.remoteAudioSubscribed,
      GravixJoinPhase.remoteVideoSubscribed,
      GravixJoinPhase.publisherConnected,
    ]);
    expect(phases.reached[GravixJoinPhase.localVideoPublished]!.detail['source'], 'camera');
    expect(phases.cameraLiveAt, phases.reached[GravixJoinPhase.publisherConnected]!.elapsed);
    expect(phases.micLiveAt, phases.reached[GravixJoinPhase.publisherConnected]!.elapsed);
  });

  test('publisher primary: peerConnected AND publisherConnected', () {
    phases.debugNotePeerConnected(publisher: true, isPrimary: true);
    expect(seen.map((e) => e.phase), [GravixJoinPhase.peerConnected, GravixJoinPhase.publisherConnected]);
    expect(seen.first.detail['transport'], 'publisher');
  });

  test('startedAt in the past (the tap) counts from there', () {
    final p = room.watchJoinPhases(startedAt: DateTime.now().subtract(const Duration(milliseconds: 400)));
    p.debugNoteRemoteSubscribed(TrackType.AUDIO);
    expect(p.reached[GravixJoinPhase.remoteAudioSubscribed]!.elapsed.inMilliseconds, greaterThanOrEqualTo(400));
    unawaited(p.dispose());
  });

  test('stream delivers the same events; dispose stops everything; a throwing onPhase is contained', () async {
    final fromStream = <GravixJoinPhase>[];
    final sub = phases.events.listen((e) => fromStream.add(e.phase));
    final throwing = room.watchJoinPhases(onPhase: (_) => throw StateError('app bug'));
    room.engine.signalClient.events.emit(const SignalConnectingEvent());
    await _flush();
    expect(fromStream, [GravixJoinPhase.wsConnecting]);
    expect(throwing.reached.keys, [GravixJoinPhase.wsConnecting]);
    await phases.dispose();
    await throwing.dispose();
    room.engine.signalClient.events.emit(const SignalConnectedEvent());
    await _flush();
    expect(seen.length, 1);
    await sub.cancel();
  });

  test('signalRttMs reads the signal client round trip (0 before the first pong)', () {
    expect(room.signalRttMs, 0);
  });

  test('toJson', () {
    phases.debugNoteLocalPublished(TrackType.VIDEO, source: 'camera');
    final j = phases.reached[GravixJoinPhase.localVideoPublished]!.toJson();
    expect(j['phase'], 'localVideoPublished');
    expect(j['detail'], {'source': 'camera'});
    expect(j['ms'], isA<int>());
  });
}

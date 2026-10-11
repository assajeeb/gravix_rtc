// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// F5 (device test 2026-10-10, r123: Wi-Fi flapping 2 s off / 3 s on, viewer):
// a new full restart (B) began while the previous one (A) was still finishing.
// A's EngineRestartedEvent handler was waiting in its microphone republish; B
// replaced the session, which ended that wait; A's tail then took B's fresh
// "announced" set, set it to null, announced the host as JOINED (who never
// left) and emitted RoomReconnectedEvent for the superseded restart; B's
// handler, back from its awaits, hit `_restartAnnounced!.addAll(kept)`:
// "Null check operator used on a null value" (room.dart:1003), unhandled. Twice
// in one run.
//
// The restart state is per restart now: a superseded restart's tail touches
// nothing of the new one and emits neither ParticipantConnected nor
// RoomReconnected.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

lk_models.ParticipantInfo host() => lk_models.ParticipantInfo(
  sid: 'PA_host',
  identity: 'host',
  state: lk_models.ParticipantInfo_State.ACTIVE,
  tracks: [
    lk_models.TrackInfo(sid: 'TR_cam', type: lk_models.TrackType.VIDEO, source: lk_models.TrackSource.CAMERA),
    lk_models.TrackInfo(sid: 'TR_mic', type: lk_models.TrackType.AUDIO, source: lk_models.TrackSource.MICROPHONE),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    GravixEngineMicMute.debugReset(supported: () => false);
  });
  tearDown(GravixEngineMicMute.debugReset);

  Room? room;
  tearDown(() async => room?.dispose());

  void subscribeHost(Room r) {
    for (final (sid, kind) in [('TR_cam', 'video'), ('TR_mic', 'audio')]) {
      final t = FakeMediaTrack(sid, kind: kind);
      r.engine.events.emit(
        EngineTrackAddedEvent(
          track: t,
          stream: FakeMediaStream([t], id: 'PA_host|$sid'),
          receiver: FakeReceiver(),
        ),
      );
    }
  }

  test('a full restart that starts while the previous one is finishing: no crash, no "host joined"', () async {
    // (an unhandled error in a room handler fails this test: the base crashed
    // with "Null check operator used on a null value" in the keep branch)
    {
      final server = FakeSignalServer()..joinResponse = ((_) => fakeJoinResponse(others: [host()]));
      final pcs = FakePcFactory();
      final r = room = await connectedFakeRoom(server, pcs);
      subscribeHost(r);
      expect(
        await eventually(() => r.remoteParticipants['host']!.trackPublications.values.every((p) => p.track != null)),
        isTrue,
      );
      // a muted mic (stopAudioCaptureOnMute): every restart republishes it
      final mic = LocalAudioTrack(
        TrackSource.microphone,
        FakeMediaStream([FakeMediaTrack('mic-1')]),
        FakeMediaTrack('mic-1'),
        const AudioCaptureOptions(),
      );
      await r.localParticipant!.publishAudioTrack(mic);
      await mic.mute(stopOnMute: true);

      final log = <String>[];
      r.events.listen((e) {
        if (e is ParticipantConnectedEvent) log.add('+${e.participant.identity}');
        if (e is ParticipantDisconnectedEvent) log.add('-${e.participant.identity}');
        if (e is RoomReconnectingEvent) log.add('reconnecting');
        if (e is RoomReconnectedEvent) log.add('reconnected');
      });

      // restart A: its republish waits for a TrackPublished that never comes
      final sessionA = server.sockets.length;
      server.holdAddTrack = (ws) => server.sockets.indexOf(ws) == sessionA;
      autoConnectPcs(pcs);
      await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      expect(
        await eventually(
          () => server.sockets.length > sessionA && server.sockets[sessionA].sent.any((q) => q.hasAddTrack()),
          timeout: const Duration(seconds: 4),
        ),
        isTrue,
      );
      subscribeHost(r); // A's subscriber delivers the host again
      await settle(50);
      // restart B starts while A's EngineRestartedEvent handler is still running
      await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      expect(await eventually(() => log.contains('reconnected'), timeout: const Duration(seconds: 4)), isTrue);
      subscribeHost(r);
      await settle(300);

      expect(log.where((e) => e.startsWith('+')), isEmpty, reason: 'base: +host (the host never left)');
      expect(log.where((e) => e.startsWith('-')), isEmpty);
      expect(log.where((e) => e == 'reconnected').length, 1, reason: 'only the restart that finished reports it');
      expect(identical(r.remoteParticipants['host'], r.remoteParticipants['host']), isTrue);
      expect(r.remoteParticipants.keys, ['host']);
      expect(r.localParticipant!.audioTrackPublications.length, 1);
    }
  });
}

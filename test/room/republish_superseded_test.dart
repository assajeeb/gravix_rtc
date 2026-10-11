// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// F4 (device test 2026-10-10, r056 / r059): a second full rejoin started while
// the first one was still republishing the muted microphone. The first
// republish waited 10 s for a TrackPublished that the replaced socket never
// delivered ("TrackPublishException Failed to publish track",
// LocalTrackRepublishFailedEvent), and the second rejoin found nothing to
// republish: the viewer ended with NO microphone publication.
//
// A republish that belongs to a superseded session is abandoned at once and
// redone on the new session; after any sequence of rejoins the muted mic is
// published (muted) exactly once.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    GravixEngineMicMute.debugReset(supported: () => false);
  });
  tearDown(GravixEngineMicMute.debugReset);

  Room? room;
  tearDown(() async => room?.dispose());

  test('a rejoin during the previous rejoin\'s republish: the muted mic ends up published exactly once', () async {
    final server = FakeSignalServer();
    final pcs = FakePcFactory();
    final r = room = await connectedFakeRoom(server, pcs);
    final mic = LocalAudioTrack(
      TrackSource.microphone,
      FakeMediaStream([FakeMediaTrack('mic-1')]),
      FakeMediaTrack('mic-1'),
      const AudioCaptureOptions(),
    );
    await r.localParticipant!.publishAudioTrack(mic);
    await mic.mute(stopOnMute: true);

    final failures = <LocalTrackRepublishFailedEvent>[];
    var reconnected = 0;
    r.events.on<LocalTrackRepublishFailedEvent>(failures.add);
    r.events.on<RoomReconnectedEvent>((_) => reconnected++);

    // rejoin A: its socket never answers the republish's AddTrack (the session
    // is replaced before it does)
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
      reason: 'rejoin A is republishing the mic',
    );
    // rejoin B starts while A's republish is in flight
    await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => reconnected >= 1, timeout: const Duration(seconds: 4)), isTrue);
    await settle(500);

    final mics = r.localParticipant!.audioTrackPublications.where((p) => p.source == TrackSource.microphone).toList();
    expect(mics.length, 1, reason: 'base: none (the mic was lost between the sessions)');
    expect(mics.single.muted, isTrue);
    expect(identical(mics.single.track, mic), isTrue);
    expect(failures, isEmpty, reason: 'base: TrackPublishException after the publish timeout');
    final last = server.sockets.last;
    expect(last.sent.where((q) => q.hasAddTrack()).length, 1, reason: 'published once on the live session');
  });

  test('three rejoins in a row, the first two superseded mid-republish: still exactly one muted mic', () async {
    final server = FakeSignalServer();
    final pcs = FakePcFactory();
    final r = room = await connectedFakeRoom(server, pcs);
    final mic = LocalAudioTrack(
      TrackSource.microphone,
      FakeMediaStream([FakeMediaTrack('mic-1')]),
      FakeMediaTrack('mic-1'),
      const AudioCaptureOptions(),
    );
    await r.localParticipant!.publishAudioTrack(mic);
    await mic.mute(stopOnMute: true);
    final failures = <LocalTrackRepublishFailedEvent>[];
    r.events.on<LocalTrackRepublishFailedEvent>(failures.add);

    final held = <int>{};
    server.holdAddTrack = (ws) => held.contains(server.sockets.indexOf(ws));
    autoConnectPcs(pcs);
    for (var i = 0; i < 2; i++) {
      final session = server.sockets.length;
      held.add(session);
      await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      expect(
        await eventually(
          () => server.sockets.length > session && server.sockets[session].sent.any((q) => q.hasAddTrack()),
          timeout: const Duration(seconds: 4),
        ),
        isTrue,
      );
    }
    await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(
      await eventually(
        () => r.localParticipant!.audioTrackPublications.isNotEmpty,
        timeout: const Duration(seconds: 4),
      ),
      isTrue,
    );
    await settle(500);
    final mics = r.localParticipant!.audioTrackPublications.toList();
    expect(mics.length, 1);
    expect(mics.single.muted, isTrue);
    expect(failures, isEmpty);
  });
}

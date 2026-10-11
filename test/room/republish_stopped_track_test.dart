// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// S6, field 2026-10-09 03:50:13.919 (Pakhi viewer): the full rejoin threw an
// unhandled "addTransceiver(): track is null" in rePublishAllTracks. The viewer
// had a muted microphone published with stopAudioCaptureOnMute (the default):
// the mute stopped the capture, and the rejoin handed that dead native track to
// addTransceiver. The handler then never reached RoomReconnectedEvent.
//
// Now a stopped muted track is republished muted WITHOUT a capture (a
// transceiver with no track; the unmute restarts the capture on its sender),
// and a track that still fails is reported, never thrown.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
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
    // the plain (disable + stop) mute path, as on a phone without the module mute
    GravixEngineMicMute.debugReset(supported: () => false);
  });
  tearDown(GravixEngineMicMute.debugReset);

  Room? room;
  tearDown(() async => room?.dispose());

  Future<(Room, FakeSignalServer, FakePcFactory, LocalAudioTrack)> mutedMicRoom({RoomOptions? options}) async {
    final server = FakeSignalServer();
    final pcs = FakePcFactory();
    final r = await connectedFakeRoom(server, pcs, roomOptions: options);
    final mic = LocalAudioTrack(
      TrackSource.microphone,
      FakeMediaStream([FakeMediaTrack('mic-1')]),
      FakeMediaTrack('mic-1'),
      const AudioCaptureOptions(),
    );
    await r.localParticipant!.publishAudioTrack(mic);
    await mic.mute(stopOnMute: true); // stopAudioCaptureOnMute: the capture is stopped
    expect(mic.isActive, isFalse);
    expect((mic.mediaStreamTrack as FakeMediaTrack).stopped, isTrue);
    return (r, server, pcs, mic);
  }

  test('a full rejoin republishes the stopped muted mic muted, without a capture; the room reconnects', () async {
    final (r, server, pcs, mic) = await mutedMicRoom();
    room = r;
    final events = <String>[];
    r.events.on<RoomReconnectedEvent>((_) => events.add('reconnected'));
    r.events.on<LocalTrackRepublishFailedEvent>((e) => events.add('failed ${e.error}'));
    final errors = <Object>[];
    autoConnectPcs(pcs);
    await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    await eventually(() => events.isNotEmpty, timeout: const Duration(seconds: 4));
    await settle(50);
    expect(errors, isEmpty);
    expect(events, ['reconnected']);
    // republished: a muted publication on the new connection, no capture behind it
    final pub = r.localParticipant!.audioTrackPublications.single;
    expect(pub.muted, isTrue);
    expect(identical(pub.track, mic), isTrue);
    final added = pcs.publisher.added.single;
    expect(added.track, isNull, reason: 'the dead native track must not reach addTransceiver');
    expect(added.kind, isNotNull);
    expect(mic.sender, isNotNull, reason: 'the unmute restarts the capture on this sender');
    expect(mic.isActive, isFalse, reason: 'the microphone stays off while muted');
    final addTracks = server.sockets.last.sent.where((q) => q.hasAddTrack()).toList();
    expect(addTracks.single.addTrack.muted, isTrue);
  });

  test('republishStoppedTracksMuted: false keeps the 0.4.14 path but never throws out of the rejoin', () async {
    final (r, _, pcs, _) = await mutedMicRoom(
      options: RoomOptions(
        reconnectPolicy: FastPolicy(),
        recovery: const GravixRecoveryOptions(republishStoppedTracksMuted: false),
      ),
    );
    room = r;
    final events = <String>[];
    r.events.on<RoomReconnectedEvent>((_) => events.add('reconnected'));
    r.events.on<LocalTrackRepublishFailedEvent>((e) => events.add('failed'));
    autoConnectPcs(pcs);
    await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    await eventually(() => events.contains('reconnected'), timeout: const Duration(seconds: 4));
    expect(events, ['failed', 'reconnected']);
  });
}

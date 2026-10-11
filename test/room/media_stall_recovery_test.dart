// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// R1 + S4 end to end in a Room (fake signal server and peer connections; the
// receiver stats the remote tracks poll are emitted by the test).
// Field 2026-10-09: media stopped at 03:49:52, ICE noticed at 03:49:59, the
// resume at 03:50:01 brought no new video, the full rejoin came at 03:50:11.
//  - R1: a subscribed camera with no packet (and no audio packet either) for
//    stallNoPacketsFor -> a resume at once.
//  - S4: after a resume, no new decoded frame for noVideoFor -> a full rejoin.
//  - guards: a muted / paused / disabled video never triggers anything.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/stats/stats.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/remote/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/remote/video.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

const fast = GravixRecoveryOptions(
  stallNoPacketsFor: Duration(milliseconds: 300),
  stallMinInterval: Duration(seconds: 2),
  noVideoFor: Duration(milliseconds: 600),
  noVideoWindow: Duration(seconds: 3),
  noVideoMinInterval: Duration(seconds: 10),
);

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
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  Room? room;
  tearDown(() async => room?.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';

  /// A viewer watching `host` (camera + mic, both subscribed and active).
  Future<(Room, RemoteVideoTrack, RemoteAudioTrack)> watching({
    GravixRecoveryOptions recovery = fast,
    lk_rtc.StreamState? streamState = lk_rtc.StreamState.ACTIVE,
  }) async {
    server = FakeSignalServer()
      ..joinResponse = ((_) => fakeJoinResponse(others: [host()]))
      ..answerOffers = true;
    pcs = FakePcFactory();
    final r = await connectedFakeRoom(
      server,
      pcs,
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
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
    final p = r.remoteParticipants['host']!;
    expect(await eventually(() => p.trackPublications.values.every((e) => e.track != null)), isTrue);
    if (streamState != null) {
      server.last.deliver(
        lk_rtc.SignalResponse(
          streamStateUpdate: lk_rtc.StreamStateUpdate(
            streamStates: [
              for (final sid in ['TR_cam', 'TR_mic'])
                lk_rtc.StreamStateInfo(participantSid: 'PA_host', trackSid: sid, state: streamState),
            ],
          ),
        ),
      );
    }
    await settle();
    return (
      r,
      p.trackPublications['TR_cam']!.track as RemoteVideoTrack,
      p.trackPublications['TR_mic']!.track as RemoteAudioTrack,
    );
  }

  void videoStats(RemoteVideoTrack t, num packets, num frames) => t.events.emit(
    VideoReceiverStatsEvent(
      stats: VideoReceiverStats('in', 0)
        ..packetsReceived = packets
        ..framesDecoded = frames,
      currentBitrate: 0,
    ),
  );
  void audioStats(RemoteAudioTrack t, num packets) => t.events.emit(
    AudioReceiverStatsEvent(stats: AudioReceiverStats('in', 0)..packetsReceived = packets, currentBitrate: 0),
  );

  test('R1: camera and audio silent for the stall time -> a resume at once (not after ICE gives up)', () async {
    final (r, cam, mic) = await watching();
    room = r;
    final dials = server.dials.length;
    videoStats(cam, 100, 10);
    audioStats(mic, 50);
    await settle(350);
    audioStats(mic, 50);
    videoStats(cam, 100, 10);
    expect(
      await eventually(() => server.dials.skip(dials).any(isResume), timeout: const Duration(seconds: 2)),
      isTrue,
      reason: 'base: nothing until ICE reports disconnected',
    );
  });

  test('R1 works when the server never reported a stream state (no ACTIVE update)', () async {
    final (r, cam, mic) = await watching(streamState: null);
    room = r;
    final dials = server.dials.length;
    videoStats(cam, 100, 10);
    audioStats(mic, 50);
    await settle(350);
    audioStats(mic, 50);
    videoStats(cam, 100, 10);
    expect(
      await eventually(() => server.dials.skip(dials).any(isResume), timeout: const Duration(seconds: 2)),
      isTrue,
      reason: 'the publication defaults to paused until the server says otherwise',
    );
  });

  test('R1 guard: a stream the server paused never triggers', () async {
    final (r, cam, mic) = await watching(streamState: lk_rtc.StreamState.PAUSED);
    room = r;
    final dials = server.dials.length;
    for (var i = 0; i < 4; i++) {
      videoStats(cam, 100, 10);
      audioStats(mic, 50);
      await settle(200);
    }
    expect(server.dials.length, dials);
  });

  test('R1 guard: a muted camera (or a paused stream) never triggers', () async {
    final (r, cam, mic) = await watching();
    room = r;
    // the host mutes the camera (a participant update carries a remote mute)
    final info = host()
      ..tracks[0].muted = true
      ..version = 2;
    server.last.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [info])));
    await settle();
    final dials = server.dials.length;
    for (var i = 0; i < 4; i++) {
      videoStats(cam, 100, 10);
      audioStats(mic, 50);
      await settle(200);
    }
    expect(server.dials.length, dials);
  });

  test('S4: after a resume, no new decoded frame -> one full rejoin', () async {
    final (r, cam, mic) = await watching(recovery: fast.copyWith(earlyStallDetection: false));
    room = r;
    // a resume (any cause): the subscriber comes back, packets arrive, no frame decodes
    final dials = server.dials.length;
    var reconnected = 0;
    r.events.on<RoomReconnectedEvent>((_) => reconnected++);
    await r.engine.handleReconnect(ClientDisconnectReason.signal);
    expect(await eventually(() => server.dials.skip(dials).any(isResume)), isTrue);
    expect(await eventually(() => reconnected > 0), isTrue);
    autoConnectPcs(pcs);
    for (var i = 0; i < 5; i++) {
      videoStats(cam, 200 + i * 5, 20); // stale retransmits, frames stuck at 20
      audioStats(mic, 60 + i);
      await settle(200);
    }
    expect(
      await eventually(() => server.dials.skip(dials).any((u) => !isResume(u)), timeout: const Duration(seconds: 2)),
      isTrue,
      reason: 'base: a resumed session with no video stays black',
    );
  });

  test('switches off: nothing', () async {
    final (r, cam, mic) = await watching(recovery: fast.copyWith(earlyStallDetection: false, noVideoWatchdog: false));
    room = r;
    final dials = server.dials.length;
    for (var i = 0; i < 4; i++) {
      videoStats(cam, 100, 10);
      audioStats(mic, 50);
      await settle(200);
    }
    expect(server.dials.length, dials);
  });
}

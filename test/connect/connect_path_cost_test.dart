// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-14, device A/B (0.4.16 vs 0.4.18, the same app, n=5 each, all UDP):
// 0.4.18 joined later (audio host roomConnected +249 ms, viewer roomConnected
// +157 ms, viewer first video RTP +217 ms, camera / mic live +196 / +184 ms).
// The connect path's only new native work in 0.4.18 is the ICE transport watch
// (GravixRecoveryOptions.iceTransportWatch): it read the selected candidate
// pair (pc.getStats, on both connections) the moment a connection connected,
// i.e. in the middle of the join. WebRTC gathers stats on its signalling thread
// (and blocks the network / worker threads for the transport stats), so the
// join's own next steps on that thread -- the subscriber's answer, the
// publisher's offer/answer, the first media -- waited behind it.
//
// Now the first reading waits GravixIceTransportWatch.firstReadDelay (3 s)
// after a connection connected; no stats are read on the join path.
//
// This file uses only APIs that 0.4.16 has, so it runs against both versions
// (RESULT lines: getStats calls during the join and Dart-side connect time).

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_join_mic.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

lk_rtc.JoinResponse _join({required bool subscriberPrimary}) => lk_rtc.JoinResponse(
  room: lk_models.Room(name: 'r', sid: 'RM_r'),
  participant: lk_models.ParticipantInfo(
    sid: 'PA_me',
    identity: 'me',
    permission: lk_models.ParticipantPermission(canPublish: true, canSubscribe: true),
  ),
  subscriberPrimary: subscriberPrimary,
  fastPublish: true,
  serverVersion: '1.9.0',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    GravixEngineMicMute.debugReset(supported: () => false);
  });
  tearDown(GravixEngineMicMute.debugReset);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  Room? room;
  tearDown(() async {
    await room?.dispose();
    room = null;
  });

  int statsCalls() => pcs.all.fold(0, (n, pc) => n + pc.getStatsCalls);

  Future<(int, int)> join({required bool subscriberPrimary, bool joinMic = false}) async {
    server = FakeSignalServer()
      ..answerOffers = true
      ..joinResponse = (_) => _join(subscriberPrimary: subscriberPrimary);
    pcs = FakePcFactory();
    autoConnectPcs(pcs);
    final options = RoomOptions(reconnectPolicy: FastPolicy());
    final engine = Engine(
      connectOptions: ConnectOptions(timeouts: fastTimeouts()),
      roomOptions: options,
      signalClient: SignalClient(server.connect),
      peerConnectionCreate: pcs.create,
    );
    final r = room = Room(engine: engine, roomOptions: options);
    final sw = Stopwatch()..start();
    await r.connect(
      'wss://blr1.example',
      'tok',
      connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0),
      joinMicrophone: joinMic
          ? GravixJoinMicrophone(
              createTrack: () async {
                final m = FakeMediaTrack('mic');
                return LocalAudioTrack(TrackSource.microphone, FakeMediaStream([m]), m, const AudioCaptureOptions());
              },
            )
          : null,
    );
    final connectMs = sw.elapsedMilliseconds;
    // the join's tail: the publisher connection, the first subscriptions
    await settle(1500);
    return (statsCalls(), connectMs);
  }

  for (final (name, subPrimary, mic) in [
    ('viewer (subscriber primary, nothing published)', true, false),
    ('audio host (subscriber primary, join microphone)', true, true),
    ('host (publisher primary, join microphone)', false, true),
  ]) {
    test('$name: no getStats on the join path (connect + 1.5 s)', () async {
      final (calls, ms) = await join(subscriberPrimary: subPrimary, joinMic: mic);
      // ignore: avoid_print
      print('RESULT $name: getStats during the join=$calls, connect()=${ms}ms (fakes)');
      expect(calls, 0, reason: 'a getStats on the join path delays the join on a phone');
    });
  }
}

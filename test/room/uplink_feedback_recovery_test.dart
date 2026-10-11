// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// uplinkFeedbackStallFor end to end in a Room (fake signal server and peer
// connections; the sender stats the local tracks poll are emitted by the test).
// Emulator 2026-10-11 r402 / r407: a host whose publisher PC moved to ICE-TCP
// without a restart got no RTCP back from the SFU (no PLI -> no keyframe), and
// its viewers saw black video for 15.8 s / 32.5 s. A resume (ICE restart) makes
// the SFU select again.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/stats/stats.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

const fast = GravixRecoveryOptions(uplinkFeedbackStallFor: Duration(milliseconds: 300));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  Room? room;
  tearDown(() async => room?.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';

  Future<(Room, LocalAudioTrack)> hosting({GravixRecoveryOptions recovery = fast}) async {
    server = FakeSignalServer();
    final r = await connectedFakeRoom(
      server,
      FakePcFactory(),
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
    final mic = LocalAudioTrack(
      TrackSource.microphone,
      FakeMediaStream([FakeMediaTrack('mic-1')]),
      FakeMediaTrack('mic-1'),
      const AudioCaptureOptions(),
    );
    await r.localParticipant!.publishAudioTrack(mic);
    await settle();
    return (r, mic);
  }

  void sent(LocalAudioTrack mic, num packets, String? rr) => mic.events.emit(
    AudioSenderStatsEvent(
      stats: AudioSenderStats('out', 0)
        ..packetsSent = packets
        ..remoteReportMarker = rr,
      currentBitrate: 0,
    ),
  );

  test('sending with no new receiver report from the SFU -> a resume (not after the SFU ICE times out)', () async {
    final (r, mic) = await hosting();
    room = r;
    final dials = server.dials.length;
    sent(mic, 100, 'rr1');
    await settle(350);
    sent(mic, 200, 'rr1');
    expect(
      await eventually(() => server.dials.skip(dials).any(isResume), timeout: const Duration(seconds: 2)),
      isTrue,
      reason: 'base: nothing; the host stays black for its viewers until the SFU gives up',
    );
  });

  test('reports keep coming -> no resume', () async {
    final (r, mic) = await hosting();
    room = r;
    final dials = server.dials.length;
    for (var i = 0; i < 4; i++) {
      sent(mic, 100 * (i + 1), 'rr$i');
      await settle(150);
    }
    await settle(300);
    expect(server.dials.skip(dials).any(isResume), isFalse);
  });

  test('muted mic -> no resume', () async {
    final (r, mic) = await hosting();
    room = r;
    await mic.mute(stopOnMute: false);
    await settle();
    final dials = server.dials.length;
    sent(mic, 100, 'rr1');
    await settle(350);
    sent(mic, 200, 'rr1');
    await settle(400);
    expect(server.dials.skip(dials).any(isResume), isFalse);
  });

  test('uplinkFeedbackStallFor: Duration.zero (rollback) -> no resume', () async {
    final (r, mic) = await hosting(recovery: const GravixRecoveryOptions(uplinkFeedbackStallFor: Duration.zero));
    room = r;
    final dials = server.dials.length;
    sent(mic, 100, 'rr1');
    await settle(350);
    sent(mic, 200, 'rr1');
    await settle(400);
    expect(server.dials.skip(dials).any(isResume), isFalse);
  });

  test('after a full rejoin the republished mic is still watched', () async {
    server = FakeSignalServer();
    final pcs = FakePcFactory();
    final r = await connectedFakeRoom(
      server,
      pcs,
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: fast),
    );
    room = r;
    final mic = LocalAudioTrack(
      TrackSource.microphone,
      FakeMediaStream([FakeMediaTrack('mic-1')]),
      FakeMediaTrack('mic-1'),
      const AudioCaptureOptions(),
    );
    await r.localParticipant!.publishAudioTrack(mic);
    final first = r.localParticipant!.audioTrackPublications.single;
    var reconnected = 0;
    r.events.on<RoomReconnectedEvent>((_) => reconnected++);
    autoConnectPcs(pcs);
    await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    await eventually(() => reconnected > 0, timeout: const Duration(seconds: 4));
    await settle(100);
    final again = r.localParticipant!.audioTrackPublications.single;
    expect(identical(again.track, mic), isTrue, reason: 'test setup: the same track republished');
    expect(identical(again, first), isFalse, reason: 'test setup: a new publication');
    final dials = server.dials.length;
    sent(mic, 1000, 'rr9');
    await settle(350);
    sent(mic, 1100, 'rr9');
    expect(
      await eventually(() => server.dials.skip(dials).any(isResume), timeout: const Duration(seconds: 2)),
      isTrue,
      reason: 'the watch must follow the new publication',
    );
  });

  test('the sender stats parser reads the remote report (changes with every receiver report)', () {
    rtc.StatsReport out() => rtc.StatsReport('OT1', 'outbound-rtp', 1000, {'packetsSent': 500, 'remoteId': 'RI1'});
    final a = audioSenderStatsFrom([
      out(),
      rtc.StatsReport('RI1', 'remote-inbound-rtp', 990, {
        'roundTripTimeMeasurements': 7,
        'totalRoundTripTime': 0.35,
        'packetsLost': 2,
      }),
    ])!;
    final b = audioSenderStatsFrom([
      out(),
      rtc.StatsReport('RI1', 'remote-inbound-rtp', 1990, {
        'roundTripTimeMeasurements': 8,
        'totalRoundTripTime': 0.40,
        'packetsLost': 2,
      }),
    ])!;
    final none = audioSenderStatsFrom([out()])!;
    expect(a.remoteReportMarker, isNotNull);
    expect(b.remoteReportMarker, isNot(a.remoteReportMarker));
    expect(none.remoteReportMarker, isNull);
  });
}

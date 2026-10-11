// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// EMU-OLD 2026-10-11, row n10 (SIMULATED, rooted Android 14 emulator, 33a1032
// example debug build, 30 % uplink loss): during a full rejoin the debug-only
// 5 s video stats dump (GravixRoomService.dumpVideoStats, kDebugMode) asked the
// old camera sender for its stats, flutter_webrtc threw
//   Unable to RTCRtpSenderNative::getStats: peerConnectionGetStats():
//   peerConnection is null
// and nothing caught it: 2 "Unhandled Exception" lines from a Timer.periodic.
// A debug metric must never throw; the room may be rejoining under it.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/video.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/video_parameters.dart';
import 'package:gravix_rtc/src/room/gravix_room_service.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    installCameraChannelMocks();
  });

  Room? room;
  tearDown(() async {
    await room?.dispose();
    room = null;
  });

  Future<FakeCamPcFactory> hostRoom() async {
    final server = FakeSignalServer()..answerOffers = true;
    final pcs = FakeCamPcFactory();
    final r = room = await connectedFakeRoom(server, pcs);
    final cam = FakeMediaTrack('cam-1', kind: 'video');
    await r.localParticipant!.publishVideoTrack(
      LocalVideoTrack(
        TrackSource.camera,
        FakeMediaStream([cam], id: 'cam-stream-1'),
        cam,
        const CameraCaptureOptions(params: VideoParametersPresets.h540_169),
      ),
      publishOptions: GravixRoomService.videoPublishOptionsFor(lowData: false),
    );
    return pcs;
  }

  test('the camera sender\'s peer connection is gone (a rejoin): the stats dump does not throw', () async {
    final pcs = await hostRoom();
    pcs.camPublisher.camSenders.single.statsError =
        'Unable to RTCRtpSenderNative::getStats: peerConnectionGetStats(): peerConnection is null';
    await expectLater(GravixRoomService.dumpVideoStatsFor(room!), completes);
  });

  test('stats available: the dump reads them', () async {
    final pcs = await hostRoom();
    expect(pcs.camPublisher.camSenders.single.statsError, isNull);
    await expectLater(GravixRoomService.dumpVideoStatsFor(room!), completes);
  });
}

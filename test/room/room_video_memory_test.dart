// Owner, 2026-11-04 (Gulf test):
//  R2: camera off, or no video left in the room: stay on the current region, no reconnect.
//  R3: REJOINING a room with no video goes back to the audio region, a fresh join by the normal
//      path; rejoining one that still has video goes straight to a video region.
// The memory used to last the whole app run, whatever the room looked like at the leave.
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/room/gravix_room_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

const doh = 'wss://doh1.gravixcloud.run';
const sgp = 'wss://sgp1.gravixcloud.run';

RegionUrlProvider _list() => RegionUrlProvider(url: doh, token: 'tok')
  ..setServerReportedRegions(
    lk_rtc.RegionSettings(
      regions: [
        lk_rtc.RegionInfo(region: 'doh1', url: doh, distance: Int64(0)),
        lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(1)),
      ],
    ),
  );

lk_models.ParticipantInfo _host({bool video = true, bool muted = false, int version = 1}) => lk_models.ParticipantInfo(
  sid: 'PA_host',
  identity: 'host',
  state: lk_models.ParticipantInfo_State.ACTIVE,
  version: version,
  tracks: [
    if (video) lk_models.TrackInfo(sid: 'TR_host', type: lk_models.TrackType.VIDEO, muted: muted),
    lk_models.TrackInfo(sid: 'TR_hostmic', type: lk_models.TrackType.AUDIO),
  ],
);

lk_rtc.SignalResponse _update(lk_models.ParticipantInfo p) =>
    lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [p]));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  GravixRoomService? svc;

  setUp(() {
    installRecoveryChannelMocks();
    installCameraCaptureMocks();
    gravixClearRegionMeasurement();
    gravixNoteRegionDirectory(const [
      GravixRegionUrl(region: 'doh1', url: doh, media: ['audio']),
      GravixRegionUrl(region: 'sgp1', url: sgp),
    ]);
    gravixMediaAutoDetect = true;
    lines.clear();
    GravixRegionLog.sink = lines.add;
  });
  tearDown(() async {
    GravixRegionLog.sink = null;
    await svc?.disconnect();
    svc = null;
  });

  group('the memory', () {
    test('an entry ends after 10 minutes', () {
      final t = DateTime(2026, 11, 4, 3, 0);
      gravixNoteRoomHasVideo('r1', now: t);
      expect(gravixRoomHadVideo('r1', now: t.add(const Duration(minutes: 9, seconds: 59))), isTrue);
      expect(gravixRoomHadVideo('r1', now: t.add(const Duration(minutes: 10, seconds: 1))), isFalse);
      expect(gravixRoomsWithVideoCount(), 0, reason: 'nothing kept for nothing');
    });

    test('a muted camera carries no video', () {
      expect(gravixInfosCarryVideo([_host(muted: true)]), isFalse);
      expect(gravixInfosCarryVideo([_host()]), isTrue);
    });
  });

  group('through the service', () {
    Future<(GravixRoomService, FakeSignalServer)> joined({required lk_rtc.JoinResponse Function(Uri) join}) async {
      final server = FakeSignalServer()
        ..joinResponse = join
        ..answerOffers = true
        ..answerMetadata = true;
      final pcs = FakeCamPcFactory();
      autoConnectPcs(pcs);
      final s = svc = GravixRoomService(
        reconnectPolicy: FastPolicy(),
        createRoom: (options) => Room(
          engine: Engine(
            connectOptions: ConnectOptions(timeouts: fastTimeouts()),
            roomOptions: options,
            signalClient: SignalClient(server.connect),
            peerConnectionCreate: pcs.create,
          ),
          roomOptions: options,
        ),
        connectRoom: (room, u, token) {
          room.gravixRegionHints = [GravixRegionUrl(region: u.contains('doh1') ? 'doh1' : 'sgp1', url: u)];
          room.engine.setRegionUrlProvider(_list());
          return room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
        },
      );
      expect(await s.connect(url: 'wss://doh1.example', token: 'tok', publishMic: false), isTrue);
      return (s, server);
    }

    test('video left the room before the leave: forgotten, the next join is audio', () async {
      final (s, server) = await joined(
        join: (uri) => fakeJoinResponse(others: uri.host == 'doh1.example' ? [_host()] : [_host()]),
      );
      expect(await eventually(() => s.room!.connectedRegion == 'sgp1'), isTrue, reason: lines.join('\n'));
      expect(gravixRoomHadVideo('r'), isTrue);
      server.sockets.last.deliver(_update(_host(video: false, version: 2)));
      await eventually(() => s.room!.remoteParticipants['host']!.videoTrackPublications.isEmpty);
      await s.disconnect();
      expect(gravixRoomHadVideo('r'), isFalse, reason: 'R3');
      lines.clear();
      expect(gravixJoinMedia(room: 'r'), GravixRoomMedia.audio);
    });

    test('the room still has remote video at the leave: remembered, the next join is video', () async {
      final (s, _) = await joined(join: (uri) => fakeJoinResponse(others: [_host()]));
      expect(await eventually(() => s.room!.connectedRegion == 'sgp1'), isTrue, reason: lines.join('\n'));
      await s.disconnect();
      expect(gravixRoomHadVideo('r'), isTrue);
      expect(gravixJoinMedia(room: 'r'), GravixRoomMedia.video);
    });

    test('own camera on at the leave counts, though the service turns it off leaving', () async {
      final (s, _) = await joined(join: (uri) => fakeJoinResponse());
      expect(await s.setCameraEnabled(true), isTrue, reason: lines.join('\n'));
      expect(s.room!.connectedRegion, 'sgp1');
      await s.disconnect();
      expect(gravixRoomHadVideo('r'), isTrue);
    });

    test('own camera turned off before the leave: no reconnect (R2), and forgotten at the leave (R3)', () async {
      final (s, server) = await joined(join: (uri) => fakeJoinResponse());
      expect(await s.setCameraEnabled(true), isTrue, reason: lines.join('\n'));
      final dials = server.dials.length;
      expect(await s.setCameraEnabled(false), isTrue);
      await settle(300);
      expect(server.dials.length, dials, reason: 'R2: stay on the current region');
      expect(s.room!.connectedRegion, 'sgp1');
      await s.disconnect();
      expect(gravixRoomHadVideo('r'), isFalse);
    });

    test('R2: the last remote video gone mid-call: no reconnect', () async {
      final (s, server) = await joined(join: (uri) => fakeJoinResponse(others: [_host()]));
      expect(await eventually(() => s.room!.connectedRegion == 'sgp1'), isTrue, reason: lines.join('\n'));
      await settle(100);
      final dials = server.dials.length;
      server.sockets.last.deliver(_update(_host(video: false, version: 2)));
      await settle(400);
      expect(server.dials.length, dials);
      expect(s.room!.connectedRegion, 'sgp1');
    });
  });

  test('a room left by the server is settled too', () async {
    final server = FakeSignalServer()..joinResponse = ((uri) => fakeJoinResponse());
    final pcs = FakePcFactory();
    final r = await connectedFakeRoom(server, pcs, url: 'wss://sgp1.example');
    r.gravixRegionHints = const [GravixRegionUrl(region: 'sgp1', url: 'wss://sgp1.example')];
    gravixNoteRoomHasVideo('r');
    await r.disconnect();
    expect(gravixRoomHadVideo('r'), isFalse);
    await r.dispose();
  });
}

// Per-region media, auto-detect (2026-11-04): nobody has to declare a room's media. A join
// goes to the fastest region, audio-only ones included, and the session moves once when the
// room turns out to carry video.
import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';

import '../support/fake_rtc.dart';

const _regionsUrl = 'https://console.example.test/v1/regions';
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

lk_models.ParticipantInfo _peer(String identity, lk_models.TrackType type) => lk_models.ParticipantInfo(
  sid: 'PA_$identity',
  identity: identity,
  state: lk_models.ParticipantInfo_State.ACTIVE,
  tracks: [lk_models.TrackInfo(sid: 'TR_$identity', type: type)],
);

lk_rtc.SignalResponse _update(lk_models.ParticipantInfo p) =>
    lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [p]));

Future<void> _measure(Map<String, Object?> body, Map<String, int?> rtt) => gravixMeasureRegions(
  regionsUrl: _regionsUrl,
  fetchDirectory: (_) async => GravixRegionDirectory.fromJson(json.decode(json.encode(body))),
  sampler: (r) async => rtt[r.region] == null ? null : Duration(milliseconds: rtt[r.region]!),
  store: GravixMemoryRegionListStore(),
  budget: const Duration(seconds: 5),
  networkType: () async => 'unknown',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  setUp(() {
    installRecoveryChannelMocks();
    gravixClearRegionMeasurement();
    gravixNoteRegionDirectory(const [
      GravixRegionUrl(region: 'doh1', url: doh, media: ['audio']),
      GravixRegionUrl(region: 'sgp1', url: sgp),
    ]);
    gravixMediaAutoDetect = true;
    lines.clear();
    GravixRegionLog.sink = lines.add;
  });
  tearDown(() {
    GravixRegionLog.sink = null;
    gravixMediaAutoDetect = true;
  });

  group('join media', () {
    test('nothing declared: audio, so the fastest region can be an audio-only one', () {
      expect(gravixJoinMedia(), GravixRoomMedia.audio);
      expect(lines, contains('[GravixRegion] media media=audio cause=auto'));
    });

    test('a join camera or a camera grant is video, as before', () {
      expect(gravixJoinMedia(enableVideo: true), GravixRoomMedia.video);
    });

    test('declared always wins over auto', () {
      expect(gravixJoinMedia(declared: GravixRoomMedia.video), GravixRoomMedia.video);
      expect(gravixJoinMedia(declared: GravixRoomMedia.audio), GravixRoomMedia.audio);
    });

    test('the off switch restores the old default', () {
      gravixMediaAutoDetect = false;
      expect(gravixJoinMedia(), GravixRoomMedia.video);
      expect(lines, contains('[GravixRegion] media media=video cause=default'));
    });

    test('a room seen with video this run goes straight to a region that carries it', () {
      gravixNoteRoomHasVideo('APP1_r1');
      expect(gravixRoomHadVideo('APP1_r1'), isTrue);
      expect(gravixRoomHadVideo('APP1_r2'), isFalse);
      expect(gravixJoinMedia(room: 'APP1_r1'), GravixRoomMedia.video);
      expect(lines, contains('[GravixRegion] media media=video cause=room-had-video'));
      expect(gravixJoinMedia(room: 'APP1_r2'), GravixRoomMedia.audio);
    });

    test('an explicit audio declaration ignores the memory, the app knows its room', () {
      gravixNoteRoomHasVideo('APP1_r1');
      expect(gravixJoinMedia(declared: GravixRoomMedia.audio, room: 'APP1_r1'), GravixRoomMedia.audio);
    });

    test('the memory stays bounded', () {
      for (var i = 0; i < 1000; i++) {
        gravixNoteRoomHasVideo('room$i');
      }
      expect(gravixRoomHadVideo('room999'), isTrue);
      expect(gravixRoomsWithVideoCount(), lessThanOrEqualTo(500));
    });
  });

  group('the session moves when the room carries video', () {
    Room? room;
    tearDown(() async => room?.dispose());

    Future<(Room, FakeSignalServer)> on(
      String url,
      String region, {
      GravixRecoveryOptions? recovery,
      lk_rtc.JoinResponse Function(Uri)? join,
    }) async {
      final server = FakeSignalServer()..joinResponse = join ?? ((uri) => fakeJoinResponse());
      final pcs = FakePcFactory();
      final r = room = await connectedFakeRoom(
        server,
        pcs,
        url: url,
        roomOptions: recovery == null ? null : RoomOptions(recovery: recovery),
      );
      r.gravixRegionHints = [GravixRegionUrl(region: region, url: url)];
      r.gravixJoinMedia = GravixRoomMedia.audio;
      r.engine.setRegionUrlProvider(_list());
      autoConnectPcs(pcs);
      return (r, server);
    }

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));
    bool moved() => lines.any((l) => l.contains('mediaFailover') && l.contains('reason=moved'));

    test('video starting mid-call on an audio-only region moves once', () async {
      final (r, server) = await on('wss://doh1.example', 'doh1');
      server.sockets.last.deliver(_update(_peer('host', lk_models.TrackType.VIDEO)));
      expect(await eventually(moved), isTrue, reason: lines.join('\n'));
      expect(lines.where((l) => l.contains('mediaFailover') && l.contains('-> sgp1')).length, 1);
      expect(lines.any((l) => l.contains('cause=room-has-video')), isTrue);
      expect(r.gravixJoinMedia, GravixRoomMedia.video);
    });

    test('video already in the room at join moves once connected', () async {
      final server = FakeSignalServer()
        ..joinResponse = (uri) => fakeJoinResponse(others: [_peer('host', lk_models.TrackType.VIDEO)]);
      final pcs = FakePcFactory();
      final r = room = fakeRoom(server, pcs);
      r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example')];
      r.gravixJoinMedia = GravixRoomMedia.audio;
      r.engine.setRegionUrlProvider(_list());
      await r.connect(
        'wss://doh1.example',
        'tok',
        connectOptions: ConnectOptions(timeouts: fastTimeouts(peerConnection: const Duration(seconds: 10))),
      );
      expect(await eventually(moved), isTrue, reason: lines.join('\n'));
      expect(gravixRoomHadVideo('r'), isTrue, reason: 'a later join of this room goes straight to a video region');
    });

    test('the move goes to the fastest measured region with video, not the first listed', () async {
      const blrUrl = 'wss://blr1.gravixcloud.run';
      await _measure(
        {
          'regions': [
            {
              'region': 'doh1',
              'url': doh,
              'media': ['audio'],
            },
            {'region': 'sgp1', 'url': sgp},
            {'region': 'blr1', 'url': blrUrl},
          ],
        },
        {'doh1': 20, 'sgp1': 180, 'blr1': 60},
      );
      final (_, server) = await on('wss://doh1.example', 'doh1');
      room!.engine.setRegionUrlProvider(
        RegionUrlProvider(url: doh, token: 'tok')..setServerReportedRegions(
          lk_rtc.RegionSettings(
            regions: [
              lk_rtc.RegionInfo(region: 'doh1', url: doh, distance: Int64(0)),
              lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(1)),
              lk_rtc.RegionInfo(region: 'blr1', url: blrUrl, distance: Int64(2)),
            ],
          ),
        ),
      );
      server.sockets.last.deliver(_update(_peer('host', lk_models.TrackType.VIDEO)));
      expect(await eventually(moved), isTrue, reason: lines.join('\n'));
      expect(lines.any((l) => l.contains('mediaFailover') && l.contains('-> blr1')), isTrue, reason: lines.join('\n'));
      expect(server.dials.any((u) => u.host == 'blr1.gravixcloud.run'), isTrue);
    });

    test('video seen before the room name is known is still remembered', () async {
      final server = FakeSignalServer();
      server.joinResponse = (uri) {
        // Seen in the Flutter simulation: the update beats the join response's handling.
        server.sockets.last.deliver(_update(_peer('host', lk_models.TrackType.VIDEO)));
        return fakeJoinResponse();
      };
      final pcs = FakePcFactory();
      final r = room = fakeRoom(server, pcs);
      r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example')];
      r.gravixJoinMedia = GravixRoomMedia.audio;
      r.engine.setRegionUrlProvider(_list());
      await r.connect(
        'wss://doh1.example',
        'tok',
        connectOptions: ConnectOptions(timeouts: fastTimeouts(peerConnection: const Duration(seconds: 10))),
      );
      expect(await eventually(moved), isTrue, reason: lines.join('\n'));
      expect(await eventually(() => gravixRoomHadVideo('r')), isTrue);
    });

    test('audio tracks never move anyone', () async {
      final (_, server) = await on('wss://doh1.example', 'doh1');
      server.sockets.last.deliver(_update(_peer('host', lk_models.TrackType.AUDIO)));
      await settle();
      expect(moved(), isFalse);
    });

    test('a region that carries video never moves, but remembers nothing costly', () async {
      final (_, server) = await on('wss://sgp1.example', 'sgp1');
      server.sockets.last.deliver(_update(_peer('host', lk_models.TrackType.VIDEO)));
      await settle();
      expect(lines.any((l) => l.contains('mediaFailover')), isFalse);
    });

    test('the option off keeps the session where it is', () async {
      final (_, server) = await on(
        'wss://doh1.example',
        'doh1',
        recovery: const GravixRecoveryOptions(mediaRefusalFailover: false),
      );
      server.sockets.last.deliver(_update(_peer('host', lk_models.TrackType.VIDEO)));
      await settle();
      expect(moved(), isFalse);
    });

    test('auto-detect off keeps the session where it is', () async {
      gravixMediaAutoDetect = false;
      final (_, server) = await on('wss://doh1.example', 'doh1');
      server.sockets.last.deliver(_update(_peer('host', lk_models.TrackType.VIDEO)));
      await settle();
      expect(moved(), isFalse);
    });
  });
}

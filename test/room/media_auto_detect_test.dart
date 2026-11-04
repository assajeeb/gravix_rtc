// Per-region media, auto-detect (2026-11-04): nobody has to declare a room's media. A join
// goes to the fastest region, audio-only ones included, and the session moves once when the
// room turns out to carry video.
import 'dart:async';
import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/room/gravix_room_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/exceptions.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/music_voice_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/video.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/video_parameters.dart';

import '../support/fake_camera.dart';
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

  // Owner's design (2026-11-04): the camera or a screen share turned on, on a region known not to
  // carry video, moves FIRST, with nothing tried there; then it publishes on the new region.
  group('turning video on moves first', () {
    Room? room;
    tearDown(() async => room?.dispose());

    setUp(installCameraCaptureMocks);

    Future<(Room, FakeSignalServer)> on(
      String url,
      String region, {
      GravixRecoveryOptions? recovery,
      RegionUrlProvider? provider,
    }) async {
      final server = FakeSignalServer()
        ..joinResponse = ((uri) => fakeJoinResponse())
        ..answerOffers = true;
      final pcs = FakeCamPcFactory();
      final r = room = await connectedFakeRoom(
        server,
        pcs,
        url: url,
        roomOptions: recovery == null ? null : RoomOptions(recovery: recovery),
      );
      r.gravixRegionHints = [GravixRegionUrl(region: region, url: url)];
      r.gravixJoinMedia = GravixRoomMedia.audio;
      r.engine.setRegionUrlProvider(provider ?? _list());
      autoConnectPcs(pcs);
      return (r, server);
    }

    Iterable<lk_rtc.AddTrackRequest> addTracksOn(FakeSignalServer s, String host) => [
      for (final ws in s.sockets.where((w) => w.uri.host == host))
        for (final q in ws.sent.where((q) => q.hasAddTrack())) q.addTrack,
    ];

    Iterable<String> moves() => lines.where((l) => l.contains('mediaFailover') && l.contains('reason=moved'));

    test('nothing is tried on the region, and the call returns the camera, up, on the new one', () async {
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final pub = await r.localParticipant!.setCameraEnabled(true);
      expect(pub, isNotNull, reason: lines.join('\n'));
      expect(pub!.track, isA<LocalVideoTrack>());
      expect(r.localParticipant!.getTrackPublicationBySource(TrackSource.camera), same(pub));
      expect(addTracksOn(server, 'doh1.example'), isEmpty);
      expect(
        addTracksOn(server, 'sgp1.gravixcloud.run').where((a) => a.type == lk_models.TrackType.VIDEO),
        hasLength(1),
      );
      expect(
        lines,
        contains('[GravixRegion] mediaFailover media=video from=doh1 -> sgp1 reason=moved cause=camera-on'),
      );
      expect(lines.any((l) => l.contains('mediaRefused')), isFalse, reason: 'nothing was refused');
      expect(
        lines.any((l) => l.startsWith('[GravixRegion] videoEnable source=camera ok region=sgp1')),
        isTrue,
        reason: lines.join('\n'),
      );
      expect(r.connectedRegion, 'sgp1');
      expect(r.gravixJoinMedia, GravixRoomMedia.video);
      expect(captureCount(), 1, reason: 'one camera opened');
    });

    test('remote participants return after the move', () async {
      final peer = _peer('guest', lk_models.TrackType.AUDIO);
      final server = FakeSignalServer()
        ..joinResponse = ((uri) => fakeJoinResponse(others: [peer]))
        ..answerOffers = true;
      final pcs = FakeCamPcFactory();
      final r = room = await connectedFakeRoom(server, pcs, url: 'wss://doh1.example');
      r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example')];
      r.engine.setRegionUrlProvider(_list());
      autoConnectPcs(pcs);
      await r.localParticipant!.setCameraEnabled(true);
      expect(r.remoteParticipants.keys, contains('guest'));
    });

    // Published 0.8.0, emulator, 3 of 3: the service's call returned about 150 ms after the call,
    // with isCameraEnabled false for good, while the camera came up on the new region.
    group('through the room service', () {
      GravixRoomService? svc;
      tearDown(() async {
        await svc?.dispose();
        svc = null;
      });

      Future<(GravixRoomService, FakeSignalServer)> service(String url, String region, {bool refuse = false}) async {
        final server = FakeSignalServer()
          ..joinResponse = ((uri) => fakeJoinResponse())
          ..answerOffers = true
          ..answerMetadata = true;
        final pcs = FakeCamPcFactory();
        autoConnectPcs(pcs);
        final s = svc = GravixRoomService(
          applyMic: (_) async {},
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
          connectRoom: (room, u, token) =>
              room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0)),
        );
        expect(await s.connect(url: url, token: 'tok', publishMic: false), isTrue);
        final r = room = s.room!;
        r.gravixRegionHints = [GravixRegionUrl(region: region, url: url)];
        r.engine.setRegionUrlProvider(_list());
        if (refuse) {
          server.holdAddTrack = (ws) => ws.uri.host == Uri.parse(url).host;
          final first = server.sockets.last;
          unawaited(() async {
            await eventually(() => first.sent.any((q) => q.hasAddTrack()));
            first.deliver(
              lk_rtc.SignalResponse(
                requestResponse: lk_rtc.RequestResponse(
                  reason: lk_rtc.RequestResponse_Reason.NOT_ALLOWED,
                  message: 'media_not_allowed',
                  addTrack: first.sent.firstWhere((q) => q.hasAddTrack()).addTrack,
                ),
              ),
            );
          }());
        }
        return (s, server);
      }

      void cameraIsUp(GravixRoomService s) {
        expect(s.isCameraEnabled.value, isTrue, reason: lines.join('\n'));
        final pub = s.localParticipant!.getTrackPublicationBySource(TrackSource.camera);
        expect(pub, isNotNull);
        expect(pub!.muted, isFalse);
        expect(s.room!.connectedRegion, 'sgp1');
      }

      test('move first: when the call returns the camera is live and isCameraEnabled is true', () async {
        final (s, server) = await service('wss://doh1.example', 'doh1');
        expect(s.isCameraEnabled.value, isFalse);
        final done = s.setCameraEnabled(true);
        expect(s.isCameraEnabled.value, isFalse);
        expect(await done, isTrue);
        cameraIsUp(s);
        expect(addTracksOn(server, 'doh1.example'), isEmpty);
        expect(addTracksOn(server, 'sgp1.gravixcloud.run'), hasLength(1));
      });

      test('a refused publish: the same, with no false failure', () async {
        gravixNoteRegionDirectory(const [
          GravixRegionUrl(region: 'doh1', url: doh),
          GravixRegionUrl(region: 'sgp1', url: sgp),
        ]);
        final (s, server) = await service('wss://doh1.example', 'doh1', refuse: true);
        expect(await s.setCameraEnabled(true), isTrue, reason: lines.join('\n'));
        cameraIsUp(s);
        expect(addTracksOn(server, 'sgp1.gravixcloud.run'), hasLength(1));
      });

      test('isCameraEnabled does not wait for the facing write, which may take 5 s', () async {
        final (s, server) = await service('wss://doh1.example', 'doh1');
        server.answerMetadata = false;
        unawaited(s.setCameraEnabled(true));
        expect(await eventually(() => s.isCameraEnabled.value), isTrue, reason: lines.join('\n'));
        cameraIsUp(s);
      });

      test('no region with video: false, the state stays off, and the camera stays closed', () async {
        gravixNoteRegionDirectory(const [
          GravixRegionUrl(region: 'doh1', url: doh, media: ['audio']),
          GravixRegionUrl(region: 'sgp1', url: sgp, media: ['audio']),
        ]);
        final (s, _) = await service('wss://doh1.example', 'doh1');
        expect(await s.setCameraEnabled(true), isFalse);
        expect(s.isCameraEnabled.value, isFalse);
        expect(captureCount(), 0);
      });
    });

    test('calls side by side share one move and one camera', () async {
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final pubs = await Future.wait([
        r.localParticipant!.setCameraEnabled(true),
        r.localParticipant!.setCameraEnabled(true),
      ]);
      expect(pubs[0], isNotNull);
      expect(identical(pubs[0], pubs[1]), isTrue);
      expect(moves(), hasLength(1), reason: lines.join('\n'));
      expect(server.dials.where((u) => u.host == 'sgp1.gravixcloud.run'), hasLength(1));
      expect(captureCount(), 1);
    });

    test('an app\'s own track goes the same way, a screen share says so in the log', () async {
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final m = FakeMediaTrack('screen-1', kind: 'video');
      final track = LocalVideoTrack(
        TrackSource.screenShareVideo,
        FakeMediaStream([m], id: 'screen-stream'),
        m,
        const ScreenShareCaptureOptions(params: VideoParametersPresets.h540_169),
      );
      final pub = await r.localParticipant!.publishVideoTrack(track);
      expect(pub.track, same(track));
      expect(addTracksOn(server, 'doh1.example'), isEmpty);
      expect(
        lines,
        contains('[GravixRegion] mediaFailover media=video from=doh1 -> sgp1 reason=moved cause=screen-on'),
      );
    });

    test('the target is the fastest measured region with video', () async {
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
      final (r, server) = await on(
        'wss://doh1.example',
        'doh1',
        provider: RegionUrlProvider(url: doh, token: 'tok')
          ..setServerReportedRegions(
            lk_rtc.RegionSettings(
              regions: [
                lk_rtc.RegionInfo(region: 'doh1', url: doh, distance: Int64(0)),
                lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(1)),
                lk_rtc.RegionInfo(region: 'blr1', url: blrUrl, distance: Int64(2)),
              ],
            ),
          ),
      );
      expect(await r.localParticipant!.setCameraEnabled(true), isNotNull, reason: lines.join('\n'));
      expect(
        lines,
        contains('[GravixRegion] mediaFailover media=video from=doh1 -> blr1 reason=moved cause=camera-on'),
      );
      expect(addTracksOn(server, 'blr1.gravixcloud.run'), isNotEmpty);
    });

    test('no region with video: a clear failure at once, no dial, no camera opened', () async {
      gravixNoteRegionDirectory(const [
        GravixRegionUrl(region: 'doh1', url: doh, media: ['audio']),
        GravixRegionUrl(region: 'sgp1', url: sgp, media: ['audio']),
      ]);
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final sw = Stopwatch()..start();
      await expectLater(
        r.localParticipant!.setCameraEnabled(true),
        throwsA(isA<TrackPublishException>().having((e) => '$e', 'text', contains('media_not_allowed'))),
      );
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(server.dials.where((u) => u.host != 'doh1.example'), isEmpty);
      expect(addTracksOn(server, 'doh1.example'), isEmpty);
      expect(captureCount(), 0);
      expect(r.localParticipant!.gravixCameraWanted, isFalse, reason: 'a later move must not turn it on by itself');
      expect(lines.any((l) => l.startsWith('[GravixRegion] videoEnable source=camera fail')), isTrue);
      expect(r.connectionState, ConnectionState.connected, reason: 'audio stays where it is');
    });

    test('mediaRefusalFailover off: a clear failure at once, no publish tried', () async {
      final (r, server) = await on(
        'wss://doh1.example',
        'doh1',
        recovery: const GravixRecoveryOptions(mediaRefusalFailover: false),
      );
      final sw = Stopwatch()..start();
      await expectLater(r.localParticipant!.setCameraEnabled(true), throwsA(isA<TrackPublishException>()));
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(server.dials.where((u) => u.host != 'doh1.example'), isEmpty);
      expect(addTracksOn(server, 'doh1.example'), isEmpty);
      expect(lines.any((l) => l.contains('stay reason=option-off cause=camera-on')), isTrue, reason: lines.join('\n'));
    });

    test('auto-detect off: the proactive step is gone, the publish goes to the region as today', () async {
      gravixMediaAutoDetect = false;
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final pub = await r.localParticipant!.setCameraEnabled(true);
      expect(pub, isNotNull);
      expect(addTracksOn(server, 'doh1.example'), hasLength(1));
      expect(moves(), isEmpty);
    });

    test('a region of unknown media publishes as today', () async {
      final (r, server) = await on('wss://xyz1.example', 'xyz1');
      expect(await r.localParticipant!.setCameraEnabled(true), isNotNull);
      expect(addTracksOn(server, 'xyz1.example'), hasLength(1));
      expect(moves(), isEmpty);
    });

    test('a region carrying video publishes as today', () async {
      final (r, server) = await on('wss://sgp1.example', 'sgp1');
      expect(await r.localParticipant!.setCameraEnabled(true), isNotNull);
      expect(addTracksOn(server, 'sgp1.example'), hasLength(1));
      expect(moves(), isEmpty);
    });

    test('the camera turned off and on again after the move stays on the new region', () async {
      final (r, server) = await on('wss://doh1.example', 'doh1');
      await r.localParticipant!.setCameraEnabled(true);
      await r.localParticipant!.setCameraEnabled(false);
      await r.localParticipant!.setCameraEnabled(true);
      expect(moves(), hasLength(1));
      expect(server.dials.where((u) => u.host == 'sgp1.gravixcloud.run'), hasLength(1));
    });

    test('a muted mic comes back muted, and stays so with the camera up', () async {
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final m = FakeMediaTrack('mic-1');
      final mic = LocalAudioTrack(
        TrackSource.microphone,
        FakeMediaStream([m], id: 'mic-stream'),
        m,
        const AudioCaptureOptions(),
      );
      final lp = r.localParticipant!;
      final pub = await lp.publishAudioTrack(mic);
      await pub.mute(stopOnMute: false);
      expect(mic.muted, isTrue);
      await lp.setCameraEnabled(true);
      final after = addTracksOn(server, 'sgp1.gravixcloud.run').where((a) => a.type == lk_models.TrackType.AUDIO);
      expect(after, hasLength(1), reason: 'the mic follows the session');
      expect(after.single.muted, isTrue);
      expect(mic.muted, isTrue);
      final now = lp.getTrackPublicationBySource(TrackSource.microphone);
      expect(now, isNotNull);
      expect(now!.muted, isTrue);
    });

    test('Android\'s engine mute holds through the move: the module never lets the mic go', () async {
      final calls = <bool>[];
      GravixEngineMicMute.debugReset(
        supported: () => true,
        setNative: (mute) async {
          calls.add(mute);
          return true;
        },
      );
      addTearDown(GravixEngineMicMute.debugReset);
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final m = FakeMediaTrack('mic-1');
      final mic = LocalAudioTrack(
        TrackSource.microphone,
        FakeMediaStream([m], id: 'mic-stream'),
        m,
        const AudioCaptureOptions(),
      );
      final lp = r.localParticipant!;
      final pub = await lp.publishAudioTrack(mic);
      await pub.mute(stopOnMute: false);
      expect(calls, [true]);
      await lp.setCameraEnabled(true);
      expect(
        addTracksOn(server, 'sgp1.gravixcloud.run').where((a) => a.type == lk_models.TrackType.AUDIO).single.muted,
        isTrue,
      );
      expect(calls, [true, true], reason: 'asserted again on the new session, never released');
      expect(GravixEngineMicMute.engaged, isTrue);
      expect(mic.muted, isTrue);
      expect(mic.uplinkCapped, isTrue, reason: 'the new sender');
    });

    test('the engine mute refused on the new session: the track goes silent the old way', () async {
      final calls = <bool>[];
      GravixEngineMicMute.debugReset(
        supported: () => true,
        setNative: (mute) async {
          calls.add(mute);
          return calls.length == 1;
        },
      );
      addTearDown(GravixEngineMicMute.debugReset);
      final (r, _) = await on('wss://doh1.example', 'doh1');
      final m = FakeMediaTrack('mic-1');
      final mic = LocalAudioTrack(
        TrackSource.microphone,
        FakeMediaStream([m], id: 'mic-stream'),
        m,
        const AudioCaptureOptions(),
      );
      final lp = r.localParticipant!;
      final pub = await lp.publishAudioTrack(mic);
      await pub.mute(stopOnMute: false);
      await lp.setCameraEnabled(true);
      expect(m.enabled, isFalse, reason: 'never live on the new session');
      expect(mic.muted, isTrue);
    });

    test('a voice-only mute (room music) stays live on the wire, with the voice still zeroed', () async {
      final calls = <bool>[];
      GravixEngineMicMute.debugReset(
        supported: () => true,
        setNative: (mute) async {
          calls.add(mute);
          return true;
        },
      );
      addTearDown(GravixEngineMicMute.debugReset);
      GravixMusicVoiceMute.predicate = (_) => true;
      addTearDown(() => GravixMusicVoiceMute.predicate = null);
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final m = FakeMediaTrack('mic-1');
      final mic = LocalAudioTrack(
        TrackSource.microphone,
        FakeMediaStream([m], id: 'mic-stream'),
        m,
        const AudioCaptureOptions(),
      );
      final lp = r.localParticipant!;
      final pub = await lp.publishAudioTrack(mic);
      await pub.mute(stopOnMute: false);
      await lp.setCameraEnabled(true);
      final after = addTracksOn(server, 'sgp1.gravixcloud.run').where((a) => a.type == lk_models.TrackType.AUDIO);
      expect(after.single.muted, isFalse);
      expect(mic.voiceOnlyMuted, isTrue);
      expect(mic.uplinkCapped, isFalse);
      expect(calls.where((c) => !c), isEmpty);
      expect(GravixEngineMicMute.engaged, isTrue);
    });

    test('a live mic comes back live', () async {
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final m = FakeMediaTrack('mic-1');
      final mic = LocalAudioTrack(
        TrackSource.microphone,
        FakeMediaStream([m], id: 'mic-stream'),
        m,
        const AudioCaptureOptions(),
      );
      final lp = r.localParticipant!;
      await lp.publishAudioTrack(mic);
      await lp.setCameraEnabled(true);
      final after = addTracksOn(server, 'sgp1.gravixcloud.run').where((a) => a.type == lk_models.TrackType.AUDIO);
      expect(after.single.muted, isFalse);
      expect(lp.getTrackPublicationBySource(TrackSource.microphone)!.muted, isFalse);
    });

    test('a mic turned on during the move waits for it, so one mic goes out, on the new region', () async {
      final (r, server) = await on('wss://doh1.example', 'doh1');
      final lp = r.localParticipant!;
      final camera = lp.setCameraEnabled(true);
      await Future<void>.delayed(Duration.zero);
      final micPub = await lp.setMicrophoneEnabled(true);
      await camera;
      expect(micPub, isNotNull);
      expect(addTracksOn(server, 'doh1.example'), isEmpty);
      expect(
        addTracksOn(server, 'sgp1.gravixcloud.run').where((a) => a.type == lk_models.TrackType.AUDIO),
        hasLength(1),
      );
    });
  });
}

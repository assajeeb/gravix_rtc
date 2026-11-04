// Gulf test 2026-11-04, step b (Motorola, room gulf-test-b): the room already carried video,
// so the session moved while the join's microphone was publishing. addTrack ended with
// GravixSessionReplacedException, nothing tried again, and after the move: app_mic_on true,
// no publication, and for the whole step nobody heard the user. A microphone or camera wanted
// during a join a move interrupts goes out on the new session, with no app action.
import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/room/gravix_room_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

const doh = 'wss://doh1.gravixcloud.run';
const sgp = 'wss://sgp1.gravixcloud.run';
const dohHost = 'doh1.example';

RegionUrlProvider _list() => RegionUrlProvider(url: doh, token: 'tok')
  ..setServerReportedRegions(
    lk_rtc.RegionSettings(
      regions: [
        lk_rtc.RegionInfo(region: 'doh1', url: doh, distance: Int64(0)),
        lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(1)),
      ],
    ),
  );

lk_models.ParticipantInfo _videoPeer() => lk_models.ParticipantInfo(
  sid: 'PA_host',
  identity: 'host',
  state: lk_models.ParticipantInfo_State.ACTIVE,
  tracks: [lk_models.TrackInfo(sid: 'TR_host', type: lk_models.TrackType.VIDEO)],
);

Iterable<lk_rtc.AddTrackRequest> _addTracksOn(FakeSignalServer server, String host, lk_models.TrackType type) => server
    .sockets
    .where((w) => w.uri.host == host)
    .expand((w) => w.sent)
    .where((q) => q.hasAddTrack() && q.addTrack.type == type)
    .map((q) => q.addTrack);

/// A microphone whose start the test holds: a recorder start, about 0.15 s on a phone.
class _SlowStartMic extends LocalAudioTrack {
  _SlowStartMic(this.gate, FakeMediaTrack t) : super(TrackSource.microphone, FakeMediaStream([t]), t, const AudioCaptureOptions());
  final Future<void> gate;
  @override
  Future<bool> start() async {
    await gate;
    return super.start();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  Room? room;
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
    await room?.dispose();
    room = null;
  });

  Future<(Room, FakeSignalServer)> onDoha({lk_rtc.JoinResponse Function(Uri)? join, Duration? newSessionPcs}) async {
    final server = FakeSignalServer()
      ..joinResponse = join ?? ((uri) => fakeJoinResponse())
      ..answerOffers = true;
    final pcs = FakeCamPcFactory();
    autoConnectPcs(pcs);
    if (newSessionPcs != null) {
      final connect = pcs.onCreate!;
      var made = 0;
      pcs.onCreate = (pc) {
        if (++made <= 2) return connect(pc);
        Timer(newSessionPcs, () => connect(pc));
      };
    }
    final r = room = Room(
      engine: Engine(
        connectOptions: ConnectOptions(timeouts: fastTimeouts()),
        roomOptions: RoomOptions(reconnectPolicy: FastPolicy()),
        signalClient: SignalClient(server.connect),
        peerConnectionCreate: pcs.create,
      ),
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy()),
    );
    r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example')];
    r.gravixJoinMedia = GravixRoomMedia.audio;
    r.engine.setRegionUrlProvider(_list());
    await r.connect(
      'wss://doh1.example',
      'tok',
      connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0),
    );
    return (r, server);
  }

  /// The old session never answers an AddTrack: what field step b hit in the 200 ms between
  /// the mic's AddTrack and the move.
  void holdAddTracksOnDoha(FakeSignalServer server) => server.holdAddTrack = (ws) => ws.uri.host == 'doh1.example';

  void videoStarts(FakeSignalServer server) => server.sockets.last.deliver(
    lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [_videoPeer()])),
  );

  test('a mic publishing when the move starts goes out on the new session; the call says so', () async {
    final (r, server) = await onDoha();
    holdAddTracksOnDoha(server);
    final lp = r.localParticipant!;
    final publishing = lp.setMicrophoneEnabled(true);
    expect(await eventually(() => _addTracksOn(server, 'doh1.example', lk_models.TrackType.AUDIO).isNotEmpty), isTrue);
    videoStarts(server);
    final pub = await publishing;
    expect(pub, isNotNull, reason: lines.join('\n'));
    expect(r.connectedRegion, 'sgp1');
    expect(lp.getTrackPublicationBySource(TrackSource.microphone), same(pub));
    expect(pub!.muted, isFalse);
    expect(pub.track!.isActive, isTrue, reason: 'a capture behind the new publication');
    expect(_addTracksOn(server, 'sgp1.gravixcloud.run', lk_models.TrackType.AUDIO), hasLength(1));
    expect(lines.any((l) => l.contains('mediaRepublish microphone')), isTrue, reason: lines.join('\n'));
  });

  // Simulator, 2026-11-04, 3 joins into a room with video: the publish passed its "a move under way?"
  // check, the recorder start took 150 ms, the move began meanwhile, and the AddTrack went out on the
  // NEW session, between its JoinResponse and the reconnect's republish. The republish sent the same
  // cid again; the SFU doesn't answer that, so 10 s later the publication was dropped: app_mic_on true,
  // track_published false for the rest of the call.
  test('a mic that lands on the new session before its republish is kept, with no second AddTrack', () async {
    final (r, server) = await onDoha(newSessionPcs: const Duration(milliseconds: 200));
    final lp = r.localParticipant!;
    final started = Completer<void>();
    final track = _SlowStartMic(started.future, FakeMediaTrack('mic-slow'));
    final publishing = lp.publishAudioTrack(track);
    await settle(20);
    server.afterJoin = (ws) {
      if (ws.uri.host == 'sgp1.gravixcloud.run') Timer(Duration.zero, started.complete);
    };
    // what the SFU does: a cid it already has on this session gets no answer
    server.holdAddTrack = (ws) => ws.sent.where((q) => q.hasAddTrack()).length > 1;
    videoStarts(server);
    final pub = await publishing;
    expect(await eventually(() => r.connectedRegion == 'sgp1'), isTrue, reason: lines.join('\n'));
    await settle(500);
    expect(_addTracksOn(server, 'sgp1.gravixcloud.run', lk_models.TrackType.AUDIO), hasLength(1), reason: lines.join('\n'));
    expect(lp.getTrackPublicationBySource(TrackSource.microphone), same(pub), reason: lines.join('\n'));
  });

  test('a mic muted while the move runs stays unpublished, and the call does not throw', () async {
    final (r, server) = await onDoha();
    holdAddTracksOnDoha(server);
    final lp = r.localParticipant!;
    final publishing = lp.setMicrophoneEnabled(true);
    await eventually(() => _addTracksOn(server, 'doh1.example', lk_models.TrackType.AUDIO).isNotEmpty);
    videoStarts(server);
    await eventually(() => server.sockets.last.uri.host == 'sgp1.gravixcloud.run');
    lp.gravixMicWanted = false; // what setMicrophoneEnabled(false) sets, without the queue
    expect(await publishing, isNull);
    await settle(100);
    expect(_addTracksOn(server, 'sgp1.gravixcloud.run', lk_models.TrackType.AUDIO), isEmpty);
    expect(lp.getTrackPublicationBySource(TrackSource.microphone), isNull);
  });

  test('a camera publishing when ANY full reconnect starts goes out on the new session', () async {
    final (r, server) = await onDoha();
    r.gravixRegionHints = const [GravixRegionUrl(region: 'sgp1', url: 'wss://doh1.example')]; // carries video
    server.holdAddTrack = (ws) => server.sockets.first == ws;
    final lp = r.localParticipant!;
    final publishing = lp.setCameraEnabled(true);
    await eventually(() => server.sockets.first.sent.any((q) => q.hasAddTrack()));
    r.engine.fullReconnectOnNext = true;
    unawaited(r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
    final pub = await publishing;
    expect(pub, isNotNull);
    expect(lp.getTrackPublicationBySource(TrackSource.camera), same(pub));
    expect(captureCount() - capturesStopped(), 1, reason: 'one camera open, the first closed');
  });

  // Emulator 2026-11-04 on 0.8.1, 3 of 12 joins: the publish began as the session went. The
  // transceiver hit the closed connection at once, but the error waited for the AddTrack, sent to
  // a dead socket, until its 10 s deadline: connect() took 11 s and the mic stayed off.
  test('a publish that begins while the session is being replaced does not sit out the deadline', () async {
    final (r, server) = await onDoha();
    r.gravixRegionHints = const [GravixRegionUrl(region: 'sgp1', url: 'wss://doh1.example')];
    final lp = r.localParticipant!;
    final dial = Completer<void>();
    server.onDial = (_) => dial.future;
    r.engine.fullReconnectOnNext = true;
    unawaited(r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
    await settle(50);
    final sw = Stopwatch()..start();
    final publishing = lp.setMicrophoneEnabled(true);
    await settle(100);
    dial.complete();
    final pub = await publishing;
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)), reason: 'base: the 10 s AddTrack deadline');
    expect(pub, isNotNull);
    expect(lp.getTrackPublicationBySource(TrackSource.microphone), same(pub));
  });

  test('an app\'s own mic track interrupted by a move goes out on the new session too', () async {
    final (r, server) = await onDoha();
    holdAddTracksOnDoha(server);
    final lp = r.localParticipant!;
    final m = FakeMediaTrack('own-mic', kind: 'audio');
    final mine = LocalAudioTrack(
      TrackSource.microphone,
      FakeMediaStream([m], id: 'own-stream'),
      m,
      const AudioCaptureOptions(),
    );
    final publishing = lp.publishAudioTrack(mine);
    await eventually(() => _addTracksOn(server, 'doh1.example', lk_models.TrackType.AUDIO).isNotEmpty);
    videoStarts(server);
    final pub = await publishing;
    expect(pub.track, same(mine));
    expect(_addTracksOn(server, 'sgp1.gravixcloud.run', lk_models.TrackType.AUDIO), hasLength(1));
  });

  group('through the room service', () {
    Future<(GravixRoomService, FakeSignalServer)> service({
      bool background = false,
      void Function(GravixRoomService s)? onMoveStarted,
    }) async {
      final server = FakeSignalServer()
        ..joinResponse = ((uri) => fakeJoinResponse(others: uri.host == dohHost ? [_videoPeer()] : []))
        ..answerOffers = true
        ..answerMetadata = true;
      // the mic's AddTrack waits on Doha until the room's video moved the session
      server.holdAddTrack = (ws) => ws.uri.host == dohHost;
      final pcs = FakeCamPcFactory();
      autoConnectPcs(pcs);
      late final GravixRoomService s;
      server.onDial = (uri) async {
        if (uri.host != dohHost) onMoveStarted?.call(s);
      };
      s = svc = GravixRoomService(
        reconnectPolicy: FastPolicy(),
        createRoom: (options) {
          final r = Room(
            engine: Engine(
              connectOptions: ConnectOptions(timeouts: fastTimeouts()),
              roomOptions: options,
              signalClient: SignalClient(server.connect),
              peerConnectionCreate: pcs.create,
            ),
            roomOptions: options,
          );
          return r;
        },
        connectRoom: (room, u, token) {
          room.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example')];
          room.engine.setRegionUrlProvider(_list());
          return room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
        },
      );
      expect(
        await s.connect(url: 'wss://doh1.example', token: 'tok', publishMic: true, publishInBackground: background),
        isTrue,
      );
      return (s, server);
    }

    void micIsLive(GravixRoomService s, FakeSignalServer server) {
      final pub = s.localParticipant!.getTrackPublicationBySource(TrackSource.microphone);
      expect(pub, isNotNull, reason: lines.join('\n'));
      expect(pub!.muted, isFalse);
      expect(s.isMicMuted.value, isFalse, reason: 'the app and the SDK agree');
      expect(s.room!.connectedRegion, 'sgp1');
      expect(_addTracksOn(server, 'sgp1.gravixcloud.run', lk_models.TrackType.AUDIO), hasLength(1));
    }

    test('field step b: a join into a room with video, mic on: the mic is live after the move', () async {
      final (s, server) = await service();
      micIsLive(s, server);
    });

    test('a mute tapped during the move wins: nothing goes out, the state says muted', () async {
      final tapped = Completer<void>();
      final connecting = service(
        background: true,
        onMoveStarted: (s) async {
          await s.setMicEnabled(false);
          tapped.complete();
        },
      );
      final (s, server) = await connecting;
      await tapped.future;
      await settle(300);
      expect(s.isMicMuted.value, isTrue);
      expect(s.localParticipant!.getTrackPublicationBySource(TrackSource.microphone)?.muted ?? true, isTrue);
      expect(_addTracksOn(server, 'sgp1.gravixcloud.run', lk_models.TrackType.AUDIO).where((a) => !a.muted), isEmpty);
    });

    test('the same with publishInBackground', () async {
      final (s, server) = await service(background: true);
      expect(
        await eventually(() => s.localParticipant?.getTrackPublicationBySource(TrackSource.microphone) != null),
        isTrue,
      );
      micIsLive(s, server);
    });
  });
}

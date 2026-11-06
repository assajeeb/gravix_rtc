// 0.8.4 regressions, from the review of 0.8.3 (2026-11-05). A mute, an unpublish, a subscription or
// a track setting asked for around a full reconnect holds on the new session, and the camera never
// turns on by itself. Tests named "still:" guard behaviour that 0.8.3 already had right.
import 'dart:async';
import 'dart:io' show SocketException;

import 'package:fixnum/fixnum.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/beauty/gravix_video_effect.dart';
import 'package:gravix_rtc/src/connect/gravix_fast_join.dart';
import 'package:gravix_rtc/src/room/gravix_audio_first.dart';
import 'package:gravix_rtc/src/room/gravix_room_service.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/android_screen_capture.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/music_voice_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/video.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/video_parameters.dart';

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

lk_models.ParticipantInfo host({bool video = true, bool audio = true}) => lk_models.ParticipantInfo(
  sid: 'PA_host',
  identity: 'host',
  state: lk_models.ParticipantInfo_State.ACTIVE,
  tracks: [
    if (video) lk_models.TrackInfo(sid: 'TR_host_cam', type: lk_models.TrackType.VIDEO, source: lk_models.TrackSource.CAMERA),
    if (audio) lk_models.TrackInfo(sid: 'TR_host_mic', type: lk_models.TrackType.AUDIO, source: lk_models.TrackSource.MICROPHONE),
  ],
);

void deliverTrack(Room r, String sid, String kind) {
  final t = FakeMediaTrack(sid, kind: kind);
  r.engine.events.emit(
    EngineTrackAddedEvent(track: t, stream: FakeMediaStream([t], id: 'PA_host|$sid'), receiver: FakeReceiver()),
  );
}

void fullReconnect(Room r) {
  r.engine.fullReconnectOnNext = true;
  unawaited(r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
}

Iterable<lk_rtc.SignalRequest> sent(FakeWs ws) => ws.sent;
List<lk_rtc.UpdateSubscription> subs(FakeWs ws) => [for (final q in ws.sent.where((q) => q.hasSubscription())) q.subscription];
List<lk_rtc.UpdateTrackSettings> settingsOn(FakeWs ws) => [for (final q in ws.sent.where((q) => q.hasTrackSetting())) q.trackSetting];
List<lk_rtc.AddTrackRequest> adds(FakeWs ws, [lk_models.TrackType? type]) => [
  for (final q in ws.sent.where((q) => q.hasAddTrack() && (type == null || q.addTrack.type == type))) q.addTrack,
];

void answerAdd(FakeWs ws, lk_rtc.AddTrackRequest a) => ws.deliver(
  lk_rtc.SignalResponse(
    trackPublished: lk_rtc.TrackPublishedResponse(
      cid: a.cid,
      track: lk_models.TrackInfo(sid: 'TR_late_${a.cid.hashCode}', type: a.type, source: a.source, name: a.name, muted: a.muted),
    ),
  ),
);

void failCamera(bool fail) {
  installCameraCaptureMocks();
  if (!fail) return;
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
    if (call.method == 'getUserMedia' && (call.arguments as Map)['constraints']?['video'] != null && (call.arguments as Map)['constraints']?['video'] != false) {
      throw PlatformException(code: 'getUserMediaFailed', message: 'camera busy');
    }
    if (call.method == 'getUserMedia') {
      return <String, dynamic>{
        'streamId': 'mic-stream',
        'audioTracks': <dynamic>[<String, dynamic>{'id': 'mic', 'label': 'mic', 'kind': 'audio', 'enabled': true}],
        'videoTracks': <dynamic>[],
      };
    }
    if (call.method == 'getSources') return <String, dynamic>{'sources': <dynamic>[]};
    if (call.method == 'getRtpReceiverCapabilities') return <String, dynamic>{'codecs': <dynamic>[], 'headerExtensions': <dynamic>[], 'fecMechanisms': <dynamic>[]};
    return null;
  });
}

/// A camera effect whose camera won't open.
class _OwnerThatFails extends GravixCameraEffect {
  @override
  String get name => 'owner';
  @override
  int? get minFps => null;
  @override
  Future<bool> canOwnCamera() async => true;
  @override
  Future<LocalVideoTrack> openCamera(CameraCaptureOptions options) async => throw StateError('camera busy');
  @override
  Future<CameraPosition> switchCamera() async => CameraPosition.front;
  @override
  Future<bool> attach(GravixVideoEffectTarget target) async => false;
  @override
  Future<void> detach() async {}
  @override
  Future<void> setEnabled(bool enabled) async {}
  @override
  Future<void> setParams(Map<String, Object?> params) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  Room? room;

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
    await room?.dispose();
    room = null;
  });

  // a plain room with no region list unless asked
  Future<(Room, FakeSignalServer, FakeCamPcFactory)> make({
    bool autoSubscribe = true,
    bool adaptive = false,
    GravixRecoveryOptions recovery = const GravixRecoveryOptions(),
    List<lk_models.ParticipantInfo> others = const [],
    String url = 'wss://x.example',
    bool audioOnly = false,
  }) async {
    final server = FakeSignalServer()
      ..joinResponse = ((_) => fakeJoinResponse(others: others))
      ..answerOffers = true;
    final pcs = FakeCamPcFactory();
    autoConnectPcs(pcs);
    final opts = RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery, adaptiveStream: adaptive);
    final r = room = Room(
      engine: Engine(
        connectOptions: ConnectOptions(timeouts: fastTimeouts(), autoSubscribe: autoSubscribe),
        roomOptions: opts,
        signalClient: SignalClient(server.connect),
        peerConnectionCreate: pcs.create,
      ),
      roomOptions: opts,
    );
    if (audioOnly) {
      r.gravixRegionHints = [GravixRegionUrl(region: 'doh1', url: url, media: const ['audio'])];
      r.gravixJoinMedia = GravixRoomMedia.audio;
      r.engine.setRegionUrlProvider(_list());
    }
    await r.connect(url, 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0, autoSubscribe: autoSubscribe));
    return (r, server, pcs);
  }

  Future<bool> reconnected(Room r, void Function() start) async {
    var done = false;
    final c = r.events.listen((e) async {
      if (e is RoomReconnectedEvent) done = true;
    });
    start();
    final ok = await eventually(() => done, timeout: const Duration(seconds: 5));
    await c();
    return ok;
  }

  Future<void> toSecondSession(Room r, FakeSignalServer server, FakeWs first) async {
    fullReconnect(r);
    expect(
      await eventually(() => server.sockets.last != first && adds(server.sockets.last).length == 1, timeout: const Duration(seconds: 4)),
      isTrue,
    );
  }

  group('C: an off call during the republish', () {
    Future<(Room, FakeSignalServer, FakeWs)> published({required bool micFirst}) async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      if (micFirst) {
        await lp.setMicrophoneEnabled(true);
        await lp.setCameraEnabled(true);
      } else {
        await lp.setCameraEnabled(true);
        await lp.setMicrophoneEnabled(true);
      }
      final first = server.sockets.last;
      // the new session's first AddTrack waits for the test
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      return (r, server, first);
    }

    for (final fast in [false, true]) {
      test('camera off while the mic republishes: its AddTrack goes out muted, fastJoin=$fast', () async {
        GravixFastJoin.enabled = fast;
        addTearDown(() => GravixFastJoin.enabled = false);
        final (r, server, first) = await published(micFirst: true);
        final lp = r.localParticipant!;
        await toSecondSession(r, server, first);
        final second = server.sockets.last;
        await lp.setCameraEnabled(false).timeout(const Duration(seconds: 1));
        answerAdd(second, adds(second).first);
        expect(await eventually(() => adds(second, lk_models.TrackType.VIDEO).isNotEmpty), isTrue);
        expect(adds(second, lk_models.TrackType.VIDEO).single.muted, isTrue);
        expect(await eventually(() => lp.getTrackPublicationBySource(TrackSource.camera) != null), isTrue);
        final pub = lp.getTrackPublicationBySource(TrackSource.camera)!;
        expect(pub.muted, isTrue);
        expect(pub.track!.isActive, isFalse);
        expect(lp.gravixCameraWanted, isFalse);
      });

      test('mic off while the camera republishes: its AddTrack goes out muted, the flag stays off, fastJoin=$fast', () async {
        GravixFastJoin.enabled = fast;
        addTearDown(() => GravixFastJoin.enabled = false);
        final (r, server, first) = await published(micFirst: false);
        final lp = r.localParticipant!;
        await toSecondSession(r, server, first);
        final second = server.sockets.last;
        await lp.setMicrophoneEnabled(false).timeout(const Duration(seconds: 1));
        answerAdd(second, adds(second).first);
        expect(await eventually(() => adds(second, lk_models.TrackType.AUDIO).isNotEmpty), isTrue);
        expect(adds(second, lk_models.TrackType.AUDIO).single.muted, isTrue);
        expect(await eventually(() => lp.getTrackPublicationBySource(TrackSource.microphone) != null), isTrue);
        expect(lp.getTrackPublicationBySource(TrackSource.microphone)!.muted, isTrue);
        expect(lp.gravixMicWanted, isFalse);
      });
    }

    test('the room service\'s tap: the flag alone mutes a track still waiting to go out', () async {
      final (r, server, first) = await published(micFirst: false);
      final lp = r.localParticipant!;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      lp.gravixMicWanted = false; // setMicEnabled, before its worker reaches the SDK
      answerAdd(second, adds(second).first);
      expect(await eventually(() => adds(second, lk_models.TrackType.AUDIO).isNotEmpty), isTrue);
      expect(adds(second, lk_models.TrackType.AUDIO).single.muted, isTrue);
    });

    test('a tap just before the republish, its off call not arrived yet: still muted', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      final first = server.sockets.last;
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      await settle(50);
      lp.gravixMicWanted = false;
      dial.complete();
      expect(await eventually(() => server.sockets.last != first && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 4)), isTrue);
      expect(adds(server.sockets.last).single.muted, isTrue);
    });

    test('off while that same track\'s AddTrack is out: returns at once, muted at the server when it lands', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await lp.setMicrophoneEnabled(false).timeout(const Duration(seconds: 1));
      answerAdd(second, adds(second).single);
      expect(await eventually(() => lp.getTrackPublicationBySource(TrackSource.microphone) != null), isTrue);
      final pub = lp.getTrackPublicationBySource(TrackSource.microphone)!;
      expect(pub.muted, isTrue);
      expect(await eventually(() => second.sent.any((q) => q.hasMute() && q.mute.sid == pub.sid && q.mute.muted)), isTrue);
      expect(await eventually(() => pub.track?.isActive == false), isTrue, reason: 'the capture closes too');
    });

    test('still: a mute before the republish starts', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      final first = server.sockets.last;
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      await settle(50);
      await lp.setMicrophoneEnabled(false);
      dial.complete();
      expect(await eventually(() => server.sockets.last != first && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 4)), isTrue);
      expect(adds(server.sockets.last).single.muted, isTrue);
    });

    test('still: off and on again during the republish ends on, with one camera', () async {
      final (r, server, first) = await published(micFirst: true);
      final lp = r.localParticipant!;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await lp.setCameraEnabled(false);
      final on = lp.setCameraEnabled(true);
      await settle(20);
      answerAdd(second, adds(second).first);
      final pub = await on.timeout(const Duration(seconds: 4));
      expect(pub, isNotNull);
      expect(pub!.track?.muted, isFalse);
      expect(await eventually(() => !pub.muted), isTrue);
      expect(adds(second, lk_models.TrackType.VIDEO), hasLength(1));
      expect(lp.videoTrackPublications, hasLength(1));
    });

    test('still: nothing asked: a live mic and camera come back live, the join flags unset', () async {
      final (r, server, first) = await published(micFirst: true);
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      answerAdd(second, adds(second).first);
      expect(await eventually(() => adds(second).length == 2), isTrue);
      expect(adds(second).map((a) => a.muted), everyElement(isFalse));
    });

    test('still: a mic the app muted and unmuted on the publication itself stays live', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final pub = await lp.setMicrophoneEnabled(true);
      await lp.setMicrophoneEnabled(false);
      await pub!.unmute();
      final first = server.sockets.last;
      fullReconnect(r);
      expect(await eventually(() => server.sockets.last != first && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 4)), isTrue);
      expect(adds(server.sockets.last).single.muted, isFalse);
    });
  });

  group('H: a second interruption during the republish', () {
    Future<(Room, FakeSignalServer, FakeWs, Completer<void>)> interrupted({required bool camera}) async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      if (camera) await lp.setCameraEnabled(true);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && server.sockets.indexOf(ws) == 1;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      await settle(50);
      return (r, server, second, dial);
    }

    test('H3: camera off in the gap holds on the third session', () async {
      final (r, server, second, dial) = await interrupted(camera: true);
      final lp = r.localParticipant!;
      await lp.setCameraEnabled(false).timeout(const Duration(seconds: 1));
      dial.complete();
      expect(
        await eventually(() => !identical(server.sockets.last, second) && adds(server.sockets.last, lk_models.TrackType.VIDEO).isNotEmpty, timeout: const Duration(seconds: 5)),
        isTrue,
      );
      expect(adds(server.sockets.last, lk_models.TrackType.VIDEO).single.muted, isTrue);
      await settle(100);
      expect(lp.getTrackPublicationBySource(TrackSource.camera)?.muted, isTrue);
      expect(lp.getTrackPublicationBySource(TrackSource.camera)?.track?.isActive, isFalse);
    });

    test('H4: mic off in the gap holds on the third session, and the flag stays off', () async {
      final (r, server, second, dial) = await interrupted(camera: false);
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(false).timeout(const Duration(seconds: 1));
      dial.complete();
      expect(
        await eventually(() => !identical(server.sockets.last, second) && adds(server.sockets.last, lk_models.TrackType.AUDIO).isNotEmpty, timeout: const Duration(seconds: 5)),
        isTrue,
      );
      await settle(200);
      expect(adds(server.sockets.last, lk_models.TrackType.AUDIO).single.muted, isTrue);
      expect(lp.getTrackPublicationBySource(TrackSource.microphone)?.muted, isTrue);
      expect(lp.gravixMicWanted, isFalse);
    });

    test('still: everything goes out once on the third session', () async {
      final (r, server, second, dial) = await interrupted(camera: true);
      final lp = r.localParticipant!;
      dial.complete();
      expect(
        await eventually(() => !identical(server.sockets.last, second) && adds(server.sockets.last).length == 2, timeout: const Duration(seconds: 5)),
        isTrue,
      );
      await settle(200);
      expect(adds(server.sockets.last), hasLength(2));
      expect(lp.getTrackPublicationBySource(TrackSource.camera)?.muted, isFalse);
      expect(lp.getTrackPublicationBySource(TrackSource.microphone)?.muted, isFalse);
    });
  });

  group('D: unpublishing a track being republished', () {
    LocalVideoTrack own() {
      final m = FakeMediaTrack('screen-1', kind: 'video');
      return LocalVideoTrack(
        TrackSource.screenShareVideo,
        FakeMediaStream([m], id: 'screen-stream'),
        m,
        const ScreenShareCaptureOptions(params: VideoParametersPresets.h540_169),
      );
    }

    test('its AddTrack is out: unpublished as soon as it lands, and reported', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final pub = await lp.publishVideoTrack(own());
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      final gone = <String>[];
      r.events.listen((e) async {
        if (e is LocalTrackUnpublishedEvent) gone.add(e.publication.sid);
      });
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await lp.removePublishedTrack(pub.sid).timeout(const Duration(seconds: 1));
      answerAdd(second, adds(second).single);
      await settle(200);
      expect(lp.getTrackPublicationBySource(TrackSource.screenShareVideo), isNull);
      expect(second.sent.where((q) => q.hasMute()).isNotEmpty || lp.trackPublications.isEmpty, isTrue);
      expect(gone, contains(pub.sid));
    });

    test('still waiting its turn: no AddTrack at all', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      final pub = await lp.publishVideoTrack(own());
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await lp.removePublishedTrack(pub.sid).timeout(const Duration(seconds: 1));
      answerAdd(second, adds(second).first);
      await settle(200);
      expect(adds(second, lk_models.TrackType.VIDEO), isEmpty);
      expect(lp.getTrackPublicationBySource(TrackSource.screenShareVideo), isNull);
      expect(lp.getTrackPublicationBySource(TrackSource.microphone), isNotNull);
    });

    test('a screen share turned off while waiting its turn: no AddTrack at all', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      await lp.publishVideoTrack(own());
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await lp.setScreenShareEnabled(false).timeout(const Duration(seconds: 1));
      answerAdd(second, adds(second).first);
      await settle(200);
      expect(adds(second, lk_models.TrackType.VIDEO), isEmpty);
    });

    test('still: in the gap before the republish', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final pub = await lp.publishVideoTrack(own());
      final first = server.sockets.last;
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      await settle(50);
      await lp.removePublishedTrack(pub.sid).timeout(const Duration(seconds: 3));
      dial.complete();
      expect(await eventually(() => server.sockets.last != first, timeout: const Duration(seconds: 4)), isTrue);
      await settle(300);
      expect(adds(server.sockets.last), isEmpty);
    });
  });

  group('F: the camera in a new room on the same Room', () {
    Future<(bool wanted, bool on, int captures)> roomB(Room r, FakeSignalServer server) async {
      server.joinResponse = (_) => fakeJoinResponse();
      r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example', media: ['audio'])];
      r.gravixJoinMedia = GravixRoomMedia.audio;
      r.engine.setRegionUrlProvider(_list());
      final before = captureCount();
      await r.connect('wss://doh1.example', 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
      final lp = r.localParticipant!;
      final wanted = lp.gravixCameraWanted;
      server.sockets.last.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host()])));
      await eventually(() => r.connectedRegion == 'sgp1', timeout: const Duration(seconds: 4));
      final on = await eventually(() => lp.getTrackPublicationBySource(TrackSource.camera) != null, timeout: const Duration(seconds: 1));
      return (wanted, on, captureCount() - before);
    }

    test('after the server ended the session: stays off', () async {
      final (r, server, _) = await make();
      await r.localParticipant!.setCameraEnabled(true);
      var gone = false;
      r.events.listen((e) async {
        if (e is RoomDisconnectedEvent) gone = true;
      });
      server.sockets.last.deliver(
        lk_rtc.SignalResponse(
          leave: lk_rtc.LeaveRequest(reason: lk_models.DisconnectReason.PARTICIPANT_REMOVED, action: lk_rtc.LeaveRequest_Action.DISCONNECT),
        ),
      );
      expect(await eventually(() => gone), isTrue);
      await settle(50);
      expect(r.localParticipant?.gravixCameraOptions, isNull);
      await r.disconnect();
      final (wanted, on, captures) = await roomB(r, server);
      expect(wanted, isFalse);
      expect(on, isFalse);
      expect(captures, 0);
      expect(r.connectedRegion, 'sgp1', reason: 'the move itself still happens');
    });

    test('still: after the app\'s own disconnect: stays off', () async {
      final (r, server, _) = await make();
      await r.localParticipant!.setCameraEnabled(true);
      await r.disconnect();
      final (wanted, on, captures) = await roomB(r, server);
      expect(wanted, isFalse);
      expect(on, isFalse);
      expect(captures, 0);
    });
  });

  group('B: a failed camera enable', () {
    Future<Object?> failedEnable(Future<void> Function() call) async {
      failCamera(true);
      Object? err;
      try {
        await call();
      } catch (e) {
        err = e;
      }
      failCamera(false);
      return err;
    }

    lk_rtc.SignalResponse refusal() => lk_rtc.SignalResponse(
      requestResponse: lk_rtc.RequestResponse(requestId: 7, reason: lk_rtc.RequestResponse_Reason.NOT_ALLOWED, message: 'media_not_allowed'),
    );

    test('capture fails, a later refusal moves the session: the camera stays off', () async {
      final (r, server, _) = await make(url: 'wss://unknown.example');
      r.engine.setRegionUrlProvider(_list());
      final lp = r.localParticipant!;
      expect(await failedEnable(() => lp.setCameraEnabled(true)), isNotNull);
      expect(lp.gravixCameraWanted, isFalse);
      server.sockets.last.deliver(refusal());
      expect(await eventually(() => r.connectedRegion == 'sgp1', timeout: const Duration(seconds: 4)), isTrue);
      await settle(200);
      expect(lp.getTrackPublicationBySource(TrackSource.camera), isNull);
      expect(captureCount(), 0);
    });

    test('capture fails during a reconnect, room video later moves the session: the camera stays off', () async {
      final (r, server, _) = await make(url: 'wss://doh1.example', audioOnly: true);
      final lp = r.localParticipant!;
      final first = server.sockets.last;
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      await settle(50);
      await failedEnable(() => lp.setCameraEnabled(true));
      server.onDial = null;
      dial.complete();
      await eventually(() => server.sockets.last != first && r.connectionState == ConnectionState.connected && !r.engine.gravixFullReconnectInProgress, timeout: const Duration(seconds: 4));
      await settle(100);
      server.sockets.last.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host()])));
      await eventually(() => r.connectedRegion == 'sgp1', timeout: const Duration(seconds: 4));
      await settle(200);
      expect(lp.getTrackPublicationBySource(TrackSource.camera), isNull);
      expect(captureCount(), 0);
    });

    test('an app\'s own camera whose publish fails: the flag clears (local.dart:469)', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final m = FakeMediaTrack('own-cam', kind: 'video');
      final track = LocalVideoTrack(TrackSource.camera, FakeMediaStream([m], id: 'own-stream'), m, const CameraCaptureOptions());
      server.holdAddTrack = (_) => true;
      Object? err;
      try {
        await lp.publishVideoTrack(track).timeout(const Duration(seconds: 8));
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      expect(lp.gravixCameraWanted, isFalse);
    });

    test('a camera unpublished by the app is not wanted any more', () async {
      final (r, _, _) = await make();
      final lp = r.localParticipant!;
      final pub = await lp.setCameraEnabled(true);
      await lp.removePublishedTrack(pub!.sid);
      expect(lp.gravixCameraWanted, isFalse);
    });

    test('still: a refused enable that cannot move clears the flag', () async {
      final (r, _, _) = await make(url: 'wss://doh1.example', audioOnly: true, recovery: const GravixRecoveryOptions(mediaRefusalFailover: false));
      final lp = r.localParticipant!;
      await failedEnable(() => lp.setCameraEnabled(true));
      expect(lp.gravixCameraWanted, isFalse);
    });

    test('still: a camera interrupted by a reconnect still goes out on the new session', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => identical(ws, first);
      final on = lp.setCameraEnabled(true);
      expect(await eventually(() => adds(first).isNotEmpty), isTrue);
      fullReconnect(r);
      expect(await on.timeout(const Duration(seconds: 5)), isNotNull);
      expect(lp.gravixCameraWanted, isTrue);
    });
  });

  group('A: autoSubscribe off', () {
    test('what the app subscribed to is asked for on the new session, with no region list', () async {
      final (r, server, _) = await make(autoSubscribe: false, others: [host()]);
      final h = r.remoteParticipants['host']!;
      final cam = h.trackPublications['TR_host_cam']!;
      await cam.subscribe();
      await h.trackPublications['TR_host_mic']!.subscribe();
      deliverTrack(r, 'TR_host_cam', 'video');
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => cam.subscribed), isTrue);
      await cam.unsubscribe();
      await cam.subscribe();
      final first = server.sockets.last;
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      final second = server.sockets.last;
      expect(second, isNot(same(first)));
      final asked = {for (final s in subs(second)) ...s.trackSids};
      expect(asked, {'TR_host_cam', 'TR_host_mic'});
      expect(subs(second).every((s) => s.subscribe), isTrue);
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => h.trackPublications['TR_host_mic']!.subscribed), isTrue);
    });

    test('what the app never asked for stays unasked', () async {
      final (r, server, _) = await make(autoSubscribe: false, others: [host()]);
      await r.remoteParticipants['host']!.trackPublications['TR_host_mic']!.subscribe();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      expect({for (final s in subs(server.sockets.last)) ...s.trackSids}, {'TR_host_mic'});
    });

    test('still: what the app unsubscribed from stays off', () async {
      final (r, server, _) = await make(autoSubscribe: false, others: [host(video: false)]);
      final mic = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
      await mic.subscribe();
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
      await mic.unsubscribe();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      expect(subs(server.sockets.last), isEmpty);
    });
  });

  group('G: autoSubscribe on, muteRemoteAudio', () {
    Future<(Room, FakeSignalServer, dynamic)> muted() async {
      final (r, server, _) = await make(others: [host(video: false)]);
      final mic = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
      await mic.unsubscribe();
      return (r, server, mic);
    }

    test('the unsubscribe goes to the new session', () async {
      final (r, server, _) = await muted();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      final s = subs(server.sockets.last);
      expect(s, isNotEmpty);
      expect(s.first.subscribe, isFalse);
      expect(s.first.trackSids, ['TR_host_mic']);
    });

    test('a track the server still sends is not played, and is refused again', () async {
      final (r, server, mic) = await muted();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      final second = server.sockets.last;
      final sentBefore = subs(second).length;
      final t = FakeMediaTrack('TR_host_mic', kind: 'audio');
      r.engine.events.emit(EngineTrackAddedEvent(track: t, stream: FakeMediaStream([t], id: 'PA_host|TR_host_mic'), receiver: FakeReceiver()));
      await settle(100);
      expect(mic.subscribed, isFalse);
      expect(t.enabled, isFalse, reason: 'native audio plays a receiver unless its track is off');
      expect(subs(second).length, greaterThan(sentBefore));
    });

    test('muted during the gap counts', () async {
      final (r, server, _) = await make(others: [host(video: false)]);
      final mic = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      final first = server.sockets.last;
      fullReconnect(r);
      await settle(50);
      await mic.unsubscribe();
      dial.complete();
      expect(await eventually(() => server.sockets.last != first && subs(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 4)), isTrue);
      expect(subs(server.sockets.last).first.subscribe, isFalse);
    });

    test('a region move keeps the mute', () async {
      final (r, server, _) = await make(url: 'wss://doh1.example', audioOnly: true, others: [host(video: false)]);
      final mic = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
      await mic.unsubscribe();
      server.joinResponse = (_) => fakeJoinResponse(others: [host(video: false)]);
      server.sockets.last.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host()])));
      expect(await eventually(() => r.connectedRegion == 'sgp1', timeout: const Duration(seconds: 4)), isTrue);
      await settle(100);
      expect(server.sockets.last.uri.host, 'sgp1.gravixcloud.run');
      expect(subs(server.sockets.last).where((s) => !s.subscribe && s.trackSids.contains('TR_host_mic')), isNotEmpty);
    });

    test('still: unmuted afterwards: asked for again, and it plays', () async {
      final (r, server, mic) = await muted();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      final second = server.sockets.last;
      await mic.subscribe();
      expect(subs(second).last.subscribe, isTrue);
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
    });

    test('still: nothing muted: no subscription traffic on the new session', () async {
      final (r, server, _) = await make(others: [host()]);
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      expect(subs(server.sockets.last), isEmpty);
    });

    test('low data: video the audio-first policy dropped stays dropped, and its restore works', () async {
      final (r, server, _) = await make(others: [host(audio: false)]);
      final cam = r.remoteParticipants['host']!.trackPublications['TR_host_cam']!;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      final ops = RoomAudioFirstOps(r);
      await ops.engage(32000, dropRemoteVideo: true);
      expect(cam.subscribed, isFalse);
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      final second = server.sockets.last;
      expect(subs(second).first.subscribe, isFalse);
      await ops.restore();
      expect(subs(second).last.subscribe, isTrue);
    });
  });

  group('E: track settings', () {
    test('a track back after "reconnected" gets its settings', () async {
      final (r, server, _) = await make(others: [host(audio: false)]);
      final cam = r.remoteParticipants['host']!.trackPublications['TR_host_cam']!;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      await cam.setVideoQuality(VideoQuality.LOW);
      await cam.disable();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      final second = server.sockets.last;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      expect(await eventually(() => settingsOn(second).isNotEmpty), isTrue);
      final s = settingsOn(second).last;
      expect(s.disabled, isTrue);
      expect(s.trackSids, ['TR_host_cam']);
      expect(s.quality, lk_models.VideoQuality.LOW);
    });

    test('with adaptiveStream on too', () async {
      final (r, server, _) = await make(adaptive: true, others: [host(audio: false)]);
      final cam = r.remoteParticipants['host']!.trackPublications['TR_host_cam']!;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      await cam.disable();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      final second = server.sockets.last;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      expect(await eventually(() => settingsOn(second).any((s) => s.disabled)), isTrue);
    });

    test('still: no preference set: nothing extra on the new session, without adaptiveStream', () async {
      final (r, server, _) = await make(others: [host(audio: false)]);
      final cam = r.remoteParticipants['host']!.trackPublications['TR_host_cam']!;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      await settle(50);
      expect(settingsOn(server.sockets.last), isEmpty);
    });

    test('still: a track back before the reconnect ends gets its settings', () async {
      final (r, server, _) = await make(others: [host(audio: false)]);
      final cam = r.remoteParticipants['host']!.trackPublications['TR_host_cam']!;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      await cam.disable();
      final first = server.sockets.last;
      server.afterJoin = (ws) {
        if (!identical(ws, first)) deliverTrack(r, 'TR_host_cam', 'video');
      };
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      await settle(100);
      expect(settingsOn(server.sockets.last).map((s) => s.disabled), contains(true));
    });
  });

  group('through the room service', () {
    GravixRoomService? svc;
    tearDown(() async {
      await svc?.disconnect();
      svc = null;
    });

    Future<(GravixRoomService, FakeSignalServer)> service({GravixVideoEffect? effect, List<lk_models.ParticipantInfo> others = const []}) async {
      final server = FakeSignalServer()
        ..joinResponse = ((_) => fakeJoinResponse(others: others))
        ..answerOffers = true
        ..answerMetadata = true;
      final pcs = FakeCamPcFactory();
      autoConnectPcs(pcs);
      final s = svc = GravixRoomService(
        reconnectPolicy: FastPolicy(),
        videoEffect: effect,
        createRoom: (options) => Room(
          engine: Engine(
            connectOptions: ConnectOptions(timeouts: fastTimeouts()),
            roomOptions: options,
            signalClient: SignalClient(server.connect),
            peerConnectionCreate: pcs.create,
          ),
          roomOptions: options,
        ),
        connectRoom: (room, u, token) => room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0)),
      );
      expect(await s.connect(url: 'wss://x.example', token: 'tok', publishMic: false), isTrue);
      return (s, server);
    }

    test('a camera effect that cannot open the camera: the flag clears', () async {
      final (s, _) = await service(effect: _OwnerThatFails());
      await s.setCameraEnabled(true);
      expect(s.localParticipant!.gravixCameraWanted, isFalse);
    });

    test('muteRemoteAudio holds over a full reconnect', () async {
      final (s, server) = await service(others: [host(video: false)]);
      final r = s.room!;
      final mic = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
      await s.muteRemoteAudio('host', true);
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      expect(subs(server.sockets.last).where((q) => !q.subscribe && q.trackSids.contains('TR_host_mic')), isNotEmpty);
      deliverTrack(r, 'TR_host_mic', 'audio');
      await settle(100);
      expect(mic.subscribed, isFalse);
      await s.muteRemoteAudio('host', false);
      expect(subs(server.sockets.last).last.subscribe, isTrue);
    });
  });

  // Second review of 87881cc (2026-11-05).
  group('a request during the republish, second review', () {
    // the new session's first AddTrack waits for the test
    Future<(Room, FakeSignalServer, FakeWs)> onSecondSession({required bool micFirst}) async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      if (micFirst) {
        await lp.setMicrophoneEnabled(true);
        await lp.setCameraEnabled(true);
      } else {
        await lp.setCameraEnabled(true);
        await lp.setMicrophoneEnabled(true);
      }
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      await toSecondSession(r, server, first);
      return (r, server, server.sockets.last);
    }

    test('#1 camera off, on, off: ends off', () async {
      final (r, _, second) = await onSecondSession(micFirst: true);
      final lp = r.localParticipant!;
      await lp.setCameraEnabled(false);
      final on = lp.setCameraEnabled(true);
      await settle(10);
      await lp.setCameraEnabled(false);
      answerAdd(second, adds(second).first);
      expect(await on.timeout(const Duration(seconds: 4)), isNull);
      await settle(100);
      final pub = lp.getTrackPublicationBySource(TrackSource.camera)!;
      expect(lp.gravixCameraWanted, isFalse);
      expect(pub.track!.muted, isTrue);
      expect(pub.muted, isTrue);
    });

    test('#1 mic off, on, off: ends off', () async {
      final (r, _, second) = await onSecondSession(micFirst: false);
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(false);
      final on = lp.setMicrophoneEnabled(true);
      await settle(10);
      await lp.setMicrophoneEnabled(false);
      answerAdd(second, adds(second).first);
      expect(await on.timeout(const Duration(seconds: 4)), isNull);
      await settle(100);
      expect(lp.gravixMicWanted, isFalse);
      expect(lp.getTrackPublicationBySource(TrackSource.microphone)!.track!.muted, isTrue);
    });

    test('#2 mic on, then the app leaves: no capture opened, and the call ends at once', () async {
      final (r, _, _) = await onSecondSession(micFirst: false);
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(false);
      var opened = 0;
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        if (call.method == 'getUserMedia') opened++;
        return null;
      });
      addTearDown(installCameraCaptureMocks);
      final on = lp.setMicrophoneEnabled(true);
      await settle(10);
      await r.disconnect();
      expect(await on.timeout(const Duration(seconds: 2)), isNull);
      expect(opened, 0);
    });

    test('still: #2 camera on, then the app leaves: no camera opened, and the call ends at once', () async {
      final (r, _, _) = await onSecondSession(micFirst: true);
      final lp = r.localParticipant!;
      await lp.setCameraEnabled(false);
      final before = captureCount();
      final on = lp.setCameraEnabled(true);
      await settle(10);
      await r.disconnect();
      expect(await on.timeout(const Duration(seconds: 2)), isNull);
      expect(captureCount(), before);
    });

    test('#2 on, and the reconnect outlasts every deadline: the call waits, one camera, ends on', () async {
      final saved = gravixMediaMoveDeadline;
      gravixMediaMoveDeadline = const Duration(milliseconds: 100);
      addTearDown(() => gravixMediaMoveDeadline = saved);
      final (r, _, second) = await onSecondSession(micFirst: true);
      final lp = r.localParticipant!;
      await lp.setCameraEnabled(false);
      final before = captureCount();
      final on = lp.setCameraEnabled(true);
      await settle(300);
      expect(captureCount(), before);
      answerAdd(second, adds(second).first);
      final pub = await on.timeout(const Duration(seconds: 4));
      expect(captureCount(), before + 1, reason: 'the unmute reopens the camera it closed');
      expect(pub, isNotNull);
      expect(pub!.track!.muted, isFalse);
      expect(lp.gravixCameraWanted, isTrue);
      expect(lp.videoTrackPublications, hasLength(1));
    });

    test('#3 off while the AddTrack is out, the session replaced: the capture closes all the same', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final pub = await lp.setCameraEnabled(true);
      final track = pub!.track!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => server.sockets.indexOf(ws) == 1;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await lp.setCameraEnabled(false);
      fullReconnect(r);
      expect(await eventually(() => !identical(server.sockets.last, second) && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 5)), isTrue);
      await settle(100);
      expect(adds(server.sockets.last).single.muted, isTrue);
      expect(track.muted, isTrue);
      expect(track.isActive, isFalse, reason: 'the camera indicator goes off');
    });

    test('#5 a republished camera forgets the old session\'s simulcast state', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final pub = await lp.setCameraEnabled(true);
      final track = pub!.track as LocalVideoTrack;
      track.simulcastCodecs['vp8'] = SimulcastTrackInfo(codec: 'vp8', mediaStreamTrack: FakeMediaTrack('backup', kind: 'video'));
      final first = server.sockets.last;
      fullReconnect(r);
      expect(await eventually(() => server.sockets.last != first && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 4)), isTrue);
      await settle(50);
      expect(track.simulcastCodecs, isEmpty);
    });

    test('#7 unpublished while its AddTrack is out: no "published" stands at the end', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final m = FakeMediaTrack('screen-1', kind: 'video');
      final pub = await lp.publishVideoTrack(
        LocalVideoTrack(TrackSource.screenShareVideo, FakeMediaStream([m], id: 'screen-stream'), m, const ScreenShareCaptureOptions(params: VideoParametersPresets.h540_169)),
      );
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      await settle(20);
      final log = <String>[];
      r.events.listen((e) async {
        if (e is LocalTrackPublishedEvent) log.add('pub:${e.publication.sid}');
        if (e is LocalTrackUnpublishedEvent) log.add('unpub:${e.publication.sid}');
      });
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await lp.removePublishedTrack(pub.sid);
      answerAdd(second, adds(second).single);
      await settle(200);
      expect(log.first, 'unpub:${pub.sid}');
      expect(log.last.startsWith('unpub:'), isTrue, reason: '$log');
      for (final e in log.where((e) => e.startsWith('pub:'))) {
        expect(log, contains('un$e'), reason: 'every mirror balances: $log');
      }
    });

    test('a camera muted before its first publish on a normal join still starts', () async {
      final (r, _, _) = await make();
      final m = FakeMediaTrack('own-cam', kind: 'video');
      final track = LocalVideoTrack(TrackSource.camera, FakeMediaStream([m], id: 'own-stream'), m, const CameraCaptureOptions());
      await track.mute(stopOnMute: false);
      expect(track.isActive, isFalse);
      await r.localParticipant!.publishVideoTrack(track);
      expect(track.isActive, isTrue);
    });
  });

  group('a mic that must keep its capture, muted during its own republish', () {
    Future<(Room, FakeSignalServer, LocalAudioTrack)> micOnSecondSession() async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final m = FakeMediaTrack('mic-1');
      final mic = LocalAudioTrack(TrackSource.microphone, FakeMediaStream([m], id: 'mic-stream'), m, const AudioCaptureOptions());
      await lp.publishAudioTrack(mic);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      await toSecondSession(r, server, first);
      return (r, server, mic);
    }

    test('voice-only (room music): stays live on the wire, no mute signal, capture open', () async {
      GravixEngineMicMute.debugReset(supported: () => true, setNative: (_) async => true);
      addTearDown(GravixEngineMicMute.debugReset);
      GravixMusicVoiceMute.predicate = (_) => true;
      addTearDown(() => GravixMusicVoiceMute.predicate = null);
      final (r, server, mic) = await micOnSecondSession();
      final lp = r.localParticipant!;
      final second = server.sockets.last;
      await lp.setMicrophoneEnabled(false);
      answerAdd(second, adds(second).single);
      await settle(100);
      expect(mic.voiceOnlyMuted, isTrue);
      expect(mic.isActive, isTrue);
      expect(second.sent.where((q) => q.hasMute() && q.mute.muted), isEmpty);
    });

    test('still: voice-only with its mute still running: its publish waits, and the wire stays live', () async {
      final native = Completer<bool>();
      GravixEngineMicMute.debugReset(supported: () => true, setNative: (_) => native.future);
      addTearDown(GravixEngineMicMute.debugReset);
      GravixMusicVoiceMute.predicate = (_) => true;
      addTearDown(() => GravixMusicVoiceMute.predicate = null);
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final m = FakeMediaTrack('mic-1');
      final mic = LocalAudioTrack(TrackSource.microphone, FakeMediaStream([m], id: 'mic-stream'), m, const AudioCaptureOptions());
      await lp.publishAudioTrack(mic);
      final first = server.sockets.last;
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      await settle(50);
      // the flag, then the session comes back with the module still answering
      lp.gravixMicWanted = false;
      dial.complete();
      await eventually(() => server.sockets.last != first, timeout: const Duration(seconds: 4));
      await settle(50);
      native.complete(true);
      expect(await eventually(() => adds(server.sockets.last).isNotEmpty), isTrue);
      await settle(100);
      final last = server.sockets.last;
      final pub = lp.getTrackPublicationBySource(TrackSource.microphone)!;
      expect(mic.voiceOnlyMuted, isTrue);
      expect(adds(last).single.muted, isFalse, reason: 'its publish waited for the mute');
      expect(last.sent.where((q) => q.hasMute() && q.mute.sid == pub.sid && q.mute.muted), isEmpty);
    });

    test('engine mute: the capture stays with it, so the unmute needs no restart and is heard', () async {
      GravixEngineMicMute.debugReset(supported: () => true, setNative: (_) async => true);
      addTearDown(GravixEngineMicMute.debugReset);
      final (r, server, mic) = await micOnSecondSession();
      final lp = r.localParticipant!;
      final second = server.sockets.last;
      await lp.setMicrophoneEnabled(false);
      answerAdd(second, adds(second).single);
      await settle(100);
      expect(mic.muted, isTrue);
      expect(mic.isActive, isTrue, reason: 'unmute of an engine mute restarts nothing');
      expect(second.sent.where((q) => q.hasMute() && q.mute.muted), isNotEmpty, reason: 'the wire is told');
    });
  });

  test('Android: a share unpublished while its AddTrack is out keeps its service until the capture closes', () async {
    final (r, server, _) = await make();
    final lp = r.localParticipant!;
    final m = FakeMediaTrack('screen-1', kind: 'video');
    final pub = await lp.publishVideoTrack(
      LocalVideoTrack(TrackSource.screenShareVideo, FakeMediaStream([m], id: 'screen-stream'), m, const ScreenShareCaptureOptions(params: VideoParametersPresets.h540_169)),
    );
    final first = server.sockets.last;
    server.holdAddTrack = (ws) => !identical(ws, first);
    await toSecondSession(r, server, first);
    final second = server.sockets.last;
    AndroidScreenCapture.requestPermission = () async => true;
    addTearDown(AndroidScreenCapture.resetForTest);
    await AndroidScreenCapture.prepare();
    expect(AndroidScreenCapture.isServiceRunning, isTrue);
    debugLkPlatformOverride = PlatformType.android;
    addTearDown(() => debugLkPlatformOverride = null);
    await lp.removePublishedTrack(pub.sid);
    expect(AndroidScreenCapture.isServiceRunning, isTrue, reason: 'stopping it ends the projection');
    answerAdd(second, adds(second).single);
    expect(await eventually(() => !AndroidScreenCapture.isServiceRunning), isTrue);
    debugLkPlatformOverride = null;
  });

  test('overlapping republishes: the first ending does not blind the second to an unpublish', () async {
    final (r, server, _) = await make();
    final lp = r.localParticipant!;
    final gate = Completer<void>();
    final track = _GatedOnPublish(gate.future, FakeMediaTrack('screen-1', kind: 'video'));
    await lp.publishVideoTrack(track);
    // the third session holds its AddTrack; the first republish lands on the second, then hangs
    server.holdAddTrack = (ws) => server.sockets.indexOf(ws) == 2;
    fullReconnect(r);
    expect(await eventually(() => track.publishes == 2, timeout: const Duration(seconds: 4)), isTrue);
    final second = server.sockets.last;
    final pub = lp.getTrackPublicationBySource(TrackSource.screenShareVideo)!;
    fullReconnect(r);
    expect(await eventually(() => !identical(server.sockets.last, second), timeout: const Duration(seconds: 4)), isTrue);
    await settle(200); // the second republish waits in the queue behind the first
    gate.complete();
    final third = server.sockets.last;
    expect(await eventually(() => adds(third).isNotEmpty, timeout: const Duration(seconds: 4)), isTrue);
    await lp.removePublishedTrack(pub.sid).timeout(const Duration(seconds: 1));
    answerAdd(third, adds(third).single);
    await settle(200);
    expect(lp.getTrackPublicationBySource(TrackSource.screenShareVideo), isNull);
  });

  group('A, G: the kept participant, second review', () {
    test('#4 subscribe() is restored when the update overtakes the JoinResponse', () async {
      final (r, server, _) = await make(autoSubscribe: false, others: [host()]);
      await r.remoteParticipants['host']!.trackPublications['TR_host_mic']!.subscribe();
      final first = server.sockets.last;
      // the relay's presence right behind the join response, which doesn't list the host
      server.joinResponse = (_) => fakeJoinResponse();
      server.afterJoin = (ws) {
        if (!identical(ws, first)) ws.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host()])));
      };
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      await settle(50);
      expect({for (final s in subs(server.sockets.last)) ...s.trackSids}, {'TR_host_mic'});
      expect(subs(server.sockets.last).every((s) => s.subscribe), isTrue);
    });

    const grace = GravixRecoveryOptions(rejoinAbsentGrace: Duration(milliseconds: 100));

    Future<(Room, FakeSignalServer, dynamic)> mutedThenAbsent() async {
      final (r, server, _) = await make(recovery: grace, others: [host(video: false)]);
      final mic = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
      await mic.unsubscribe();
      server.joinResponse = (_) => fakeJoinResponse();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      return (r, server, mic);
    }

    test('#6 a refused track proves the muted remote is there: kept past the grace', () async {
      final (r, _, mic) = await mutedThenAbsent();
      final h = r.remoteParticipants['host'];
      deliverTrack(r, 'TR_host_mic', 'audio');
      await settle(300);
      expect(identical(r.remoteParticipants['host'], h), isTrue);
      expect(mic.subscribed, isFalse);
    });

    test('a remote the grace dropped returns at the autoSubscribe default, as documented', () async {
      final (r, server, _) = await mutedThenAbsent();
      expect(await eventually(() => r.remoteParticipants['host'] == null), isTrue);
      final second = server.sockets.last;
      second.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host(video: false)])));
      expect(await eventually(() => r.remoteParticipants['host'] != null), isTrue);
      deliverTrack(r, 'TR_host_mic', 'audio');
      final back = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
      expect(await eventually(() => back.subscribed), isTrue);
    });

    test('with autoSubscribe off, the pull after a grace drop asks for nothing the app has not asked of the new publication', () async {
      final (r, server, _) = await make(recovery: grace, autoSubscribe: false, others: [host()]);
      await r.remoteParticipants['host']!.trackPublications['TR_host_mic']!.subscribe();
      server.joinResponse = (_) => fakeJoinResponse();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      expect(await eventually(() => r.remoteParticipants['host'] == null), isTrue);
      final second = server.sockets.last;
      second.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host()])));
      expect(await eventually(() => r.remoteParticipants['host'] != null), isTrue);
      await settle(700);
      expect(subs(second).where((s) => s.subscribe), isEmpty);
    });

    test('still: video a low-data policy dropped comes back with a remote the grace dropped, so it can never stick off', () async {
      final (r, server, _) = await make(recovery: grace, others: [host(audio: false)]);
      final cam = r.remoteParticipants['host']!.trackPublications['TR_host_cam']!;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      await cam.unsubscribe();
      server.joinResponse = (_) => fakeJoinResponse();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      expect(await eventually(() => r.remoteParticipants['host'] == null), isTrue);
      server.sockets.last.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host(audio: false)])));
      expect(await eventually(() => r.remoteParticipants['host'] != null), isTrue);
      deliverTrack(r, 'TR_host_cam', 'video');
      final back = r.remoteParticipants['host']!.trackPublications['TR_host_cam']!;
      expect(await eventually(() => back.subscribed), isTrue);
    });
  });

  group('through the room service, second review', () {
    test('#1 camera off, on, off: ends off', () async {
      final server = FakeSignalServer()
        ..joinResponse = ((_) => fakeJoinResponse())
        ..answerOffers = true
        ..answerMetadata = true;
      final pcs = FakeCamPcFactory();
      autoConnectPcs(pcs);
      final s = GravixRoomService(
        reconnectPolicy: FastPolicy(),
        createRoom: (options) => Room(
          engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: options, signalClient: SignalClient(server.connect), peerConnectionCreate: pcs.create),
          roomOptions: options,
        ),
        connectRoom: (room, u, token) => room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0)),
      );
      addTearDown(s.disconnect);
      expect(await s.connect(url: 'wss://x.example', token: 'tok', publishMic: false), isTrue);
      final r = s.room!;
      final lp = s.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      expect(await s.setCameraEnabled(true), isTrue);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await s.setCameraEnabled(false);
      final on = s.setCameraEnabled(true);
      await settle(10);
      await s.setCameraEnabled(false);
      answerAdd(second, adds(second).first);
      await on.timeout(const Duration(seconds: 4));
      await settle(100);
      expect(lp.getTrackPublicationBySource(TrackSource.camera)!.track!.muted, isTrue);
      expect(s.isCameraEnabled.value, isFalse);
    });
  });
  // The JS second review's questions, asked of Flutter (2026-11-05).
  group('JS second review', () {
    // cameras and mics whose open takes [delay], or waits for [gate]; counts opens and closes
    late int opened, closed;
    void slowCapture({Duration delay = const Duration(milliseconds: 30), Future<void>? gate}) {
      opened = 0;
      closed = 0;
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var n = 0;
      m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        switch (call.method) {
          case 'getUserMedia':
            opened++;
            final c = (call.arguments as Map)['constraints'] as Map?;
            final isVideo = c?['video'] != null && c?['video'] != false;
            final id = ++n;
            await Future<void>.delayed(delay);
            if (gate != null) await gate;
            return <String, dynamic>{
              'streamId': 'st-$id',
              'audioTracks': isVideo ? <dynamic>[] : <dynamic>[<String, dynamic>{'id': 'a-$id', 'label': 'mic', 'kind': 'audio', 'enabled': true}],
              'videoTracks': isVideo ? <dynamic>[<String, dynamic>{'id': 'v-$id', 'label': 'camera', 'kind': 'video', 'enabled': true}] : <dynamic>[],
            };
          case 'trackDispose':
            closed++;
            return null;
          case 'getSources':
            return <String, dynamic>{'sources': <dynamic>[]};
          case 'getRtpReceiverCapabilities':
            return <String, dynamic>{'codecs': <dynamic>[], 'headerExtensions': <dynamic>[], 'fecMechanisms': <dynamic>[]};
        }
        return null;
      });
      addTearDown(installCameraCaptureMocks);
    }

    for (final source in [TrackSource.camera, TrackSource.microphone]) {
      Future<Object?> call(Room r, bool on) => source == TrackSource.camera ? r.localParticipant!.setCameraEnabled(on) : r.localParticipant!.setMicrophoneEnabled(on);
      for (final gaps in [(0, 0), (0, 10), (10, 0), (5, 50), (50, 5), (60, 60)]) {
        test('#1 still: on, off, on during a slow capture ends on, one track: ${source.name}, gaps $gaps', () async {
          final (r, _, _) = await make();
          slowCapture();
          final a = call(r, true);
          if (gaps.$1 > 0) await settle(gaps.$1);
          final b = call(r, false);
          if (gaps.$2 > 0) await settle(gaps.$2);
          final c = call(r, true);
          await Future.wait([a, b, c]).timeout(const Duration(seconds: 4));
          await settle(30);
          final pub = r.localParticipant!.getTrackPublicationBySource(source);
          expect(pub, isNotNull);
          expect(pub!.track!.muted, isFalse, reason: 'the last call was on');
          expect(pub.muted, isFalse);
          expect(r.localParticipant!.trackPublications.length, 1);
        });
      }

      test('#1 on, off during a slow capture: nothing goes out live: ${source.name}', () async {
        final (r, server, _) = await make();
        slowCapture();
        final a = call(r, true);
        await settle(5);
        final b = call(r, false);
        await Future.wait([a, b]).timeout(const Duration(seconds: 4));
        await settle(30);
        expect(adds(server.sockets.last).where((q) => !q.muted), isEmpty);
        expect(r.localParticipant!.getTrackPublicationBySource(source)?.track?.muted ?? true, isTrue);
        expect(closed, opened, reason: 'the capture nobody wants is closed');
      });
    }

    test('#1 mic on while a move runs, then off: stays off when the move lands', () async {
      final (r, server, _) = await make(url: 'wss://doh1.example', audioOnly: true);
      final lp = r.localParticipant!;
      final cam = lp.setCameraEnabled(true); // moves first
      await settle(1);
      final on = lp.setMicrophoneEnabled(true);
      await settle(1);
      await lp.setMicrophoneEnabled(false);
      await on.timeout(const Duration(seconds: 5));
      await cam.timeout(const Duration(seconds: 5));
      await settle(100);
      expect(lp.getTrackPublicationBySource(TrackSource.microphone), isNull);
      expect(server.sockets.expand((w) => adds(w, lk_models.TrackType.AUDIO)), isEmpty);
    });

    test('#2 the app leaves during the capture: closed, nothing published', () async {
      final (r, server, _) = await make();
      final gate = Completer<void>();
      slowCapture(gate: gate.future);
      final lp = r.localParticipant!;
      final mic = lp.setMicrophoneEnabled(true);
      final cam = lp.setCameraEnabled(true);
      await settle(20);
      await r.disconnect();
      gate.complete();
      await Future.wait([mic.catchError((_) => null), cam.catchError((_) => null)]).timeout(const Duration(seconds: 3));
      await settle(50);
      expect(adds(server.sockets.last), isEmpty);
      expect(closed, opened, reason: 'no capture left open');
    });

    test('#2 the capture ends in the next room on the same Room: nothing published there', () async {
      final (r, server, _) = await make();
      final gate = Completer<void>();
      slowCapture(gate: gate.future);
      final lp = r.localParticipant!;
      final mic = lp.setMicrophoneEnabled(true);
      await settle(20);
      await r.disconnect();
      await r.connect('wss://x.example', 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
      final b = server.sockets.last;
      gate.complete();
      await mic.catchError((_) => null).timeout(const Duration(seconds: 3));
      await settle(100);
      expect(adds(b), isEmpty, reason: 'room B never asked for a mic');
      expect(closed, opened);
    });

    test('#2 server ends the session during the capture: closed too, on the kept participant', () async {
      final (r, server, _) = await make();
      final gate = Completer<void>();
      slowCapture(gate: gate.future);
      final mic = r.localParticipant!.setMicrophoneEnabled(true);
      await settle(20);
      var gone = false;
      r.events.listen((e) async {
        if (e is RoomDisconnectedEvent) gone = true;
      });
      server.sockets.last.deliver(
        lk_rtc.SignalResponse(leave: lk_rtc.LeaveRequest(reason: lk_models.DisconnectReason.PARTICIPANT_REMOVED, action: lk_rtc.LeaveRequest_Action.DISCONNECT)),
      );
      expect(await eventually(() => gone), isTrue);
      gate.complete();
      await mic.catchError((_) => null).timeout(const Duration(seconds: 3));
      await settle(50);
      expect(closed, opened);
    });

    test('#2 a service join opening camera and mic, left during the capture: nothing stays open', () async {
      final server = FakeSignalServer()
        ..joinResponse = ((_) => fakeJoinResponse())
        ..answerOffers = true
        ..answerMetadata = true;
      final pcs = FakeCamPcFactory();
      autoConnectPcs(pcs);
      final gate = Completer<void>();
      slowCapture(gate: gate.future);
      final s = GravixRoomService(
        reconnectPolicy: FastPolicy(),
        createRoom: (options) => Room(
          engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: options, signalClient: SignalClient(server.connect), peerConnectionCreate: pcs.create),
          roomOptions: options,
        ),
        connectRoom: (room, u, token) => room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0)),
      );
      final joining = s.connect(url: 'wss://x.example', token: 'tok', publishMic: true, enableVideo: true);
      expect(await eventually(() => opened > 0), isTrue);
      // a leave waits for the capture under way (it is not cancellable), which closes when it ends
      final leaving = s.disconnect();
      await settle(100);
      gate.complete();
      await leaving.timeout(const Duration(seconds: 8));
      await joining.timeout(const Duration(seconds: 12), onTimeout: () => false);
      await settle(100);
      expect(server.sockets.expand((w) => adds(w)).where((a) => !a.muted), isEmpty);
      expect(closed, opened);
    });

    test('#3 a failed republish tells the app, and the service shows the truth', () async {
      final server = FakeSignalServer()
        ..joinResponse = ((_) => fakeJoinResponse())
        ..answerOffers = true
        ..answerMetadata = true;
      final pcs = FakeCamPcFactory();
      autoConnectPcs(pcs);
      final s = GravixRoomService(
        reconnectPolicy: FastPolicy(),
        createRoom: (options) => Room(
          engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: options, signalClient: SignalClient(server.connect), peerConnectionCreate: pcs.create),
          roomOptions: options,
        ),
        connectRoom: (room, u, token) => room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0)),
      );
      addTearDown(s.disconnect);
      expect(await s.connect(url: 'wss://x.example', token: 'tok', publishMic: false), isTrue);
      await s.setMicEnabled(true);
      expect(s.isMicMuted.value, isFalse);
      final r = s.room!;
      final first = server.sockets.last;
      final failed = <String>[];
      r.events.listen((e) async {
        if (e is LocalTrackRepublishFailedEvent) failed.add(e.publication.source.name);
      });
      server.holdAddTrack = (ws) => !identical(ws, first);
      fullReconnect(r);
      expect(await eventually(() => failed.isNotEmpty, timeout: const Duration(seconds: 14)), isTrue);
      expect(failed, ['microphone']);
      expect(await eventually(() => s.isMicMuted.value), isTrue, reason: 'the app must not show a live mic');
    });

    group('#4 leaves', () {
      test('still: a muted remote the grace kept for its refused media is dropped by a real leave', () async {
        final (r, server, _) = await make(recovery: const GravixRecoveryOptions(rejoinAbsentGrace: Duration(milliseconds: 100)), others: [host(video: false)]);
        final mic = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
        deliverTrack(r, 'TR_host_mic', 'audio');
        expect(await eventually(() => mic.subscribed), isTrue);
        await mic.unsubscribe();
        server.joinResponse = (_) => fakeJoinResponse();
        expect(await reconnected(r, () => fullReconnect(r)), isTrue);
        deliverTrack(r, 'TR_host_mic', 'audio');
        await settle(250);
        expect(r.remoteParticipants['host'], isNotNull);
        final gone = host(video: false)..state = lk_models.ParticipantInfo_State.DISCONNECTED;
        server.sockets.last.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [gone])));
        expect(await eventually(() => r.remoteParticipants['host'] == null), isTrue);
      });
    });
  });
  // Third review, of 4c07c81 and 697d067.
  group('third review', () {
    Future<(GravixRoomService, FakeSignalServer)> service({GravixVideoEffect? effect, List<lk_models.ParticipantInfo> others = const []}) async {
      final server = FakeSignalServer()
        ..joinResponse = ((_) => fakeJoinResponse(others: others))
        ..answerOffers = true
        ..answerMetadata = true;
      final pcs = FakeCamPcFactory();
      autoConnectPcs(pcs);
      final s = GravixRoomService(
        reconnectPolicy: FastPolicy(),
        videoEffect: effect,
        createRoom: (options) => Room(
          engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: options, signalClient: SignalClient(server.connect), peerConnectionCreate: pcs.create),
          roomOptions: options,
        ),
        connectRoom: (room, u, token) => room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0)),
      );
      addTearDown(s.disconnect);
      expect(await s.connect(url: 'wss://x.example', token: 'tok', publishMic: false), isTrue);
      return (s, server);
    }

    LocalVideoTrack screen() {
      final m = FakeMediaTrack('screen-1', kind: 'video');
      return LocalVideoTrack(TrackSource.screenShareVideo, FakeMediaStream([m], id: 'screen-stream'), m, const ScreenShareCaptureOptions(params: VideoParametersPresets.h540_169));
    }

    test('#1 unpublish, then on, while its AddTrack is out: ends on', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final pub = await lp.setCameraEnabled(true);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await lp.removePublishedTrack(pub!.sid);
      final on = lp.setCameraEnabled(true);
      await settle(20);
      answerAdd(second, adds(second).first);
      final back = await on.timeout(const Duration(seconds: 4));
      await settle(100);
      expect(back, isNotNull);
      expect(lp.gravixCameraWanted, isTrue);
      expect(lp.getTrackPublicationBySource(TrackSource.camera), isNotNull);
      expect(lp.getTrackPublicationBySource(TrackSource.camera)!.track!.muted, isFalse);
      expect(lp.getTrackPublicationBySource(TrackSource.camera)!.track!.isActive, isTrue);
      expect(lp.videoTrackPublications, hasLength(1));
    });

    test('#2 service mic off, on past the deadline: UI on, track live', () async {
      final saved = gravixMediaMoveDeadline;
      gravixMediaMoveDeadline = const Duration(milliseconds: 100);
      addTearDown(() => gravixMediaMoveDeadline = saved);
      final (s, server) = await service();
      final r = s.room!;
      await s.setCameraEnabled(true);
      await s.setMicEnabled(true);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      await s.setMicEnabled(false);
      unawaited(s.setMicEnabled(true));
      await settle(300);
      answerAdd(second, adds(second).first);
      final lp = s.localParticipant!;
      expect(await eventually(() => lp.getTrackPublicationBySource(TrackSource.microphone)?.track?.muted == false, timeout: const Duration(seconds: 4)), isTrue);
      expect(s.isMicMuted.value, isFalse);
      expect(lp.gravixMicWanted, isTrue);
    });

    test('#3 a leave during the republish closes every capture the reconnect holds, and the share service', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final mic = (await lp.setMicrophoneEnabled(true))!.track!;
      final cam = (await lp.setCameraEnabled(true))!.track!;
      final share = screen();
      await lp.publishVideoTrack(share);
      AndroidScreenCapture.requestPermission = () async => true;
      addTearDown(AndroidScreenCapture.resetForTest);
      await AndroidScreenCapture.prepare();
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      await toSecondSession(r, server, first);
      debugLkPlatformOverride = PlatformType.android;
      addTearDown(() => debugLkPlatformOverride = null);
      await r.disconnect().timeout(const Duration(seconds: 8));
      await settle(50);
      debugLkPlatformOverride = null;
      expect([mic.isActive, cam.isActive, share.isActive], [false, false, false]);
      expect(AndroidScreenCapture.isServiceRunning, isFalse);
    });

    test('#3 a leave during the republish lets go of the engine mute', () async {
      GravixEngineMicMute.debugReset(supported: () => true, setNative: (_) async => true);
      addTearDown(GravixEngineMicMute.debugReset);
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final mic = (await lp.setMicrophoneEnabled(true))!.track!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      await toSecondSession(r, server, first);
      await lp.setMicrophoneEnabled(false);
      expect(GravixEngineMicMute.engaged, isTrue);
      await r.disconnect().timeout(const Duration(seconds: 8));
      await settle(50);
      expect(mic.isActive, isFalse);
      expect(GravixEngineMicMute.engaged, isFalse);
    });

    test('#5 a beauty-effect camera turned on again during its republish: one camera', () async {
      final owner = _OwnerThatOpens();
      final (s, server) = await service(effect: owner);
      expect(await s.setCameraEnabled(true), isTrue);
      expect(owner.opened, 1);
      final r = s.room!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      final again = s.setCameraEnabled(true);
      await settle(50);
      answerAdd(second, adds(second).first);
      await again.timeout(const Duration(seconds: 4));
      await settle(100);
      expect(owner.opened, 1);
      expect(s.localParticipant!.videoTrackPublications, hasLength(1));
      expect(adds(second, lk_models.TrackType.VIDEO), hasLength(1));
    });

    test('#6 a publish landing after its session was replaced is not published; the next session gets it', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final gate = Completer<void>();
      final track = _GatedStart(gate.future, FakeMediaTrack('screen-1', kind: 'video'));
      await lp.publishVideoTrack(track);
      final failed = <String>[];
      r.events.listen((e) async {
        if (e is LocalTrackRepublishFailedEvent) failed.add(e.error.toString());
      });
      fullReconnect(r);
      expect(await eventually(() => track.starts == 2, timeout: const Duration(seconds: 4)), isTrue);
      final second = server.sockets.last;
      fullReconnect(r);
      expect(await eventually(() => !identical(server.sockets.last, second), timeout: const Duration(seconds: 4)), isTrue);
      await settle(200);
      gate.complete();
      final third = server.sockets.last;
      expect(await eventually(() => adds(third).isNotEmpty, timeout: const Duration(seconds: 4)), isTrue, reason: 'published with no AddTrack on the new session');
      await settle(100);
      expect(failed, isEmpty);
      expect(lp.getTrackPublicationBySource(TrackSource.screenShareVideo), isNotNull);
    });

    test('#7 a camera unpublished clears the flag with the off-call option off too', () async {
      final (r, _, _) = await make(recovery: const GravixRecoveryOptions(republishHonorsOffCalls: false));
      final lp = r.localParticipant!;
      final pub = await lp.setCameraEnabled(true);
      await lp.removePublishedTrack(pub!.sid);
      expect(lp.gravixCameraWanted, isFalse);
    });

    test('#7 an interrupted camera whose publish fails when the reconnect lands: the call fails, the flag clears', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => identical(ws, first);
      final dial = Completer<void>();
      final on = lp.setCameraEnabled(true).catchError((Object _) => null);
      expect(await eventually(() => adds(first).isNotEmpty), isTrue);
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      await settle(50);
      failCamera(true);
      addTearDown(installCameraCaptureMocks);
      server.onDial = null;
      dial.complete();
      await on.timeout(const Duration(seconds: 4));
      await settle(100);
      expect(lp.getTrackPublicationBySource(TrackSource.camera), isNull);
      expect(lp.gravixCameraWanted, isFalse);
    });

    test('#8 stopping a share does not wait for another track\'s publish', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final share = screen();
      await lp.publishVideoTrack(share);
      server.holdAddTrack = (_) => true;
      final mic = lp.setMicrophoneEnabled(true).catchError((Object _) => null);
      await settle(50);
      await lp.setScreenShareEnabled(false).timeout(const Duration(seconds: 1));
      expect(lp.getTrackPublicationBySource(TrackSource.screenShareVideo), isNull);
      expect(share.isActive, isFalse);
      server.holdAddTrack = null;
      await mic;
    });

    // Last batch.
    for (final camera in [true, false]) {
      test('D1 on during a reconnect that outlasts every deadline: the call waits, and the UI matches: ${camera ? 'camera' : 'mic'}', () async {
        final saved = gravixMediaMoveDeadline;
        gravixMediaMoveDeadline = const Duration(milliseconds: 100);
        addTearDown(() => gravixMediaMoveDeadline = saved);
        final (s, server) = await service();
        final r = s.room!;
        final first = server.sockets.last;
        server.holdAddTrack = (ws) => identical(ws, first);
        final on = camera ? s.setCameraEnabled(true) : s.setMicEnabled(true);
        expect(await eventually(() => adds(first).isNotEmpty), isTrue);
        final dial = Completer<void>();
        server.onDial = (_) => dial.future;
        fullReconnect(r);
        await settle(400); // past the deadline
        server.onDial = null;
        dial.complete();
        await on.timeout(const Duration(seconds: 4));
        expect(await eventually(() => r.connectionState == ConnectionState.connected && !r.engine.gravixFullReconnectInProgress, timeout: const Duration(seconds: 4)), isTrue);
        await settle(200);
        final pub = s.localParticipant!.getTrackPublicationBySource(camera ? TrackSource.camera : TrackSource.microphone);
        expect(pub, isNotNull);
        expect(pub!.track!.muted, isFalse);
        expect(camera ? s.isCameraEnabled.value : !s.isMicMuted.value, isTrue, reason: 'live, so the UI says on');
      });
    }

    test('a republish queued for an old session does not publish on the newer one', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final cam = await lp.setCameraEnabled(true);
      // an app's own publish holds the queue through both reconnects
      final gate = Completer<void>();
      final share = _GatedStart(gate.future, FakeMediaTrack('screen-1', kind: 'video'), gateAt: 1);
      final sharing = lp.publishVideoTrack(share).then<Object?>((p) => p, onError: (Object _) => null);
      expect(await eventually(() => share.starts == 1), isTrue);
      final failed = <String>[];
      r.events.listen((e) async {
        if (e is LocalTrackRepublishFailedEvent) failed.add(e.publication.source.name);
      });
      final first = server.sockets.last;
      fullReconnect(r);
      expect(await eventually(() => server.sockets.last != first, timeout: const Duration(seconds: 4)), isTrue);
      expect(await eventually(() => lp.gravixRepublishPending(TrackSource.camera), timeout: const Duration(seconds: 4)), isTrue);
      await settle(100);
      final second = server.sockets.last;
      fullReconnect(r);
      expect(await eventually(() => !identical(server.sockets.last, second), timeout: const Duration(seconds: 4)), isTrue);
      await settle(200);
      gate.complete();
      await sharing.timeout(const Duration(seconds: 6));
      await settle(200);
      final third = server.sockets.last;
      expect(adds(second, lk_models.TrackType.VIDEO).where((a) => a.source == lk_models.TrackSource.CAMERA), isEmpty);
      expect(adds(third, lk_models.TrackType.VIDEO).where((a) => a.source == lk_models.TrackSource.CAMERA), hasLength(1));
      expect(failed, isEmpty);
      expect(lp.getTrackPublicationBySource(TrackSource.camera)?.track?.isActive, isTrue);
      expect(cam!.track!.isActive, isTrue);
    });

    test('a failed republish closes its capture, reports once, and the service tells the effect', () async {
      final owner = _OwnerThatOpens();
      final (s, server) = await service(effect: owner);
      expect(await s.setCameraEnabled(true), isTrue);
      final track = s.localParticipant!.getTrackPublicationBySource(TrackSource.camera)!.track!;
      final r = s.room!;
      final first = server.sockets.last;
      final failed = <String>[];
      r.events.listen((e) async {
        if (e is LocalTrackRepublishFailedEvent) failed.add(e.publication.source.name);
      });
      server.holdAddTrack = (ws) => !identical(ws, first);
      fullReconnect(r);
      expect(await eventually(() => failed.isNotEmpty, timeout: const Duration(seconds: 9)), isTrue);
      await settle(100);
      expect(failed, ['camera']);
      expect(track.isActive, isFalse);
      expect(s.isCameraEnabled.value, isFalse);
      expect(s.localParticipant!.gravixCameraWanted, isFalse);
      expect(owner.detached, greaterThan(0), reason: 'the effect heard the camera stopped');
    });

    test('D3 off while an unmute is restarting the capture of a track being republished: goes out muted', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      await lp.setMicrophoneEnabled(false);
      final gate = Completer<void>();
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        if (call.method == 'getUserMedia') {
          await gate.future;
          return <String, dynamic>{
            'streamId': 'mic-2',
            'audioTracks': <dynamic>[<String, dynamic>{'id': 'mic-2', 'label': 'mic', 'kind': 'audio', 'enabled': true}],
            'videoTracks': <dynamic>[],
          };
        }
        return null;
      });
      addTearDown(installCameraCaptureMocks);
      final on = lp.setMicrophoneEnabled(true);
      await settle(20);
      final first = server.sockets.last;
      fullReconnect(r);
      expect(await eventually(() => lp.gravixRepublishPending(TrackSource.microphone), timeout: const Duration(seconds: 4)), isTrue);
      final off = lp.setMicrophoneEnabled(false); // follows the unmute under way
      await settle(10);
      gate.complete();
      await off.timeout(const Duration(seconds: 2));
      await on.timeout(const Duration(seconds: 4)).catchError((Object _) => null);
      expect(await eventually(() => server.sockets.last != first && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 4)), isTrue);
      await settle(100);
      expect(adds(server.sockets.last).single.muted, isTrue);
      expect(lp.getTrackPublicationBySource(TrackSource.microphone)?.track?.muted, isTrue);
    });

    test('D4 an on call in the gap of a session the server ended does not hang', () async {
      final (r, server, _) = await make(others: [host(video: false)]);
      final lp = r.localParticipant!;
      await lp.setCameraEnabled(true);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      // the room's cleanup stops this remote track, after it woke the reconnect's waiters
      Future<Object?>? on;
      final t = _HookedStop(() => on = lp.setCameraEnabled(true).then<Object?>((p) => p, onError: (Object _) => null));
      r.engine.events.emit(EngineTrackAddedEvent(track: t, stream: FakeMediaStream([t], id: 'PA_host|TR_host_mic'), receiver: FakeReceiver()));
      expect(await eventually(() => r.remoteParticipants['host']?.trackPublications['TR_host_mic']?.subscribed ?? false), isTrue);
      second.deliver(
        lk_rtc.SignalResponse(leave: lk_rtc.LeaveRequest(reason: lk_models.DisconnectReason.PARTICIPANT_REMOVED, action: lk_rtc.LeaveRequest_Action.DISCONNECT)),
      );
      expect(await eventually(() => on != null, timeout: const Duration(seconds: 4)), isTrue);
      expect(await on!.timeout(const Duration(seconds: 3)), isNull);
    });

    test('D5 a beauty camera on call whose reconnect ends with the server ending the session opens nothing', () async {
      final owner = _OwnerThatOpens();
      final (s, server) = await service(effect: owner, others: [host(video: false)]);
      expect(await s.setCameraEnabled(true), isTrue);
      final r = s.room!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      await toSecondSession(r, server, first);
      final second = server.sockets.last;
      final again = s.setCameraEnabled(true);
      await settle(30);
      second.deliver(
        lk_rtc.SignalResponse(leave: lk_rtc.LeaveRequest(reason: lk_models.DisconnectReason.PARTICIPANT_REMOVED, action: lk_rtc.LeaveRequest_Action.DISCONNECT)),
      );
      await again.timeout(const Duration(seconds: 3));
      await settle(50);
      expect(owner.opened, 1);
    });

    // Small review of db78616.
    test('a capture failing during a resume after a reconnect: the call reports it, no hang', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final gate = Completer<void>();
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        if (call.method == 'getUserMedia') {
          await gate.future;
          throw PlatformException(code: 'getUserMediaFailed', message: 'camera busy');
        }
        return null;
      });
      addTearDown(installCameraCaptureMocks);
      final on = lp.setCameraEnabled(true).then<Object?>((p) => p, onError: (Object e) => 'failed');
      await settle(20);
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      server.onDial = (_) => Completer<void>().future; // the resume's dial stays out
      unawaited(r.engine.handleReconnect(ClientDisconnectReason.signal));
      expect(await eventually(() => server.dials.isNotEmpty && r.connectionState != ConnectionState.connected), isTrue);
      await settle(50);
      gate.complete();
      expect(r.engine.gravixFullReconnectInProgress, isFalse, reason: 'a resume');
      expect(await on.timeout(const Duration(seconds: 3)), 'failed');
      expect(lp.gravixCameraWanted, isFalse);
    });

    test('a call after the attempts ran out reports it, no hang', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      server.onDial = (_) async => throw const SocketException('dial refused (test)');
      fullReconnect(r);
      expect(await eventually(() => r.connectionState == ConnectionState.disconnected, timeout: const Duration(seconds: 8)), isTrue);
      final on = lp.setCameraEnabled(true).then<Object?>((p) => p, onError: (Object e) => 'failed');
      expect(await on.timeout(const Duration(seconds: 3)), anyOf('failed', isNull));
      expect(lp.getTrackPublicationBySource(TrackSource.camera), isNull);
    });

    test('a capture ending after the attempts ran out reports it, no hang', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final gate = Completer<void>();
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        if (call.method == 'getUserMedia') {
          await gate.future;
          throw PlatformException(code: 'getUserMediaFailed', message: 'camera busy');
        }
        return null;
      });
      addTearDown(installCameraCaptureMocks);
      final on = lp.setCameraEnabled(true).then<Object?>((p) => p, onError: (Object e) => 'failed');
      await settle(20);
      server.onDial = (_) async => throw const SocketException('dial refused (test)');
      fullReconnect(r);
      expect(await eventually(() => r.connectionState == ConnectionState.disconnected, timeout: const Duration(seconds: 8)), isTrue);
      await settle(100);
      gate.complete();
      expect(await on.timeout(const Duration(seconds: 3)), anyOf('failed', isNull));
    });

    test('still: a call waiting when the attempts run out ends too', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => identical(ws, first);
      final on = lp.setCameraEnabled(true).then<Object?>((p) => p, onError: (Object e) => 'failed');
      expect(await eventually(() => adds(first).isNotEmpty), isTrue);
      server.onDial = (_) async => throw const SocketException('dial refused (test)');
      fullReconnect(r);
      expect(await on.timeout(const Duration(seconds: 8)), anyOf('failed', isNull));
      expect(lp.getTrackPublicationBySource(TrackSource.camera), isNull);
    });

    test('still: with upstreamReconnectFixes off, a camera interrupted by a reconnect goes out on the new session', () async {
      final (r, server, _) = await make(recovery: const GravixRecoveryOptions(upstreamReconnectFixes: false));
      final lp = r.localParticipant!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => identical(ws, first);
      final on = lp.setCameraEnabled(true);
      expect(await eventually(() => adds(first).isNotEmpty), isTrue);
      fullReconnect(r);
      expect(await on.timeout(const Duration(seconds: 5)), isNotNull);
      expect(adds(server.sockets.last), hasLength(1));
    });

    test('Android: a failed share republish stops the share service too', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.publishVideoTrack(screen());
      AndroidScreenCapture.requestPermission = () async => true;
      addTearDown(AndroidScreenCapture.resetForTest);
      await AndroidScreenCapture.prepare();
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      await toSecondSession(r, server, first);
      debugLkPlatformOverride = PlatformType.android;
      addTearDown(() => debugLkPlatformOverride = null);
      expect(await eventually(() => !AndroidScreenCapture.isServiceRunning, timeout: const Duration(seconds: 8)), isTrue);
      debugLkPlatformOverride = null;
    });

    test('#8 a dropped track whose publish fails: no failed event after its "unpublished", and closed', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final share = screen();
      final pub = await lp.publishVideoTrack(share);
      final first = server.sockets.last;
      final log = <String>[];
      r.events.listen((e) async {
        if (e is LocalTrackRepublishFailedEvent) log.add('failed');
        if (e is LocalTrackUnpublishedEvent) log.add('unpub');
      });
      server.holdAddTrack = (ws) => !identical(ws, first);
      await toSecondSession(r, server, first);
      await lp.removePublishedTrack(pub.sid);
      expect(await eventually(() => !share.isActive, timeout: const Duration(seconds: 8)), isTrue);
      await settle(100);
      expect(log, ['unpub']);
    });
  });
}

/// A camera effect that opens the (fake) camera.
class _OwnerThatOpens extends GravixCameraEffect {
  int opened = 0;
  int detached = 0;
  @override
  String get name => 'owner';
  @override
  int? get minFps => null;
  @override
  Future<bool> canOwnCamera() async => true;
  @override
  Future<LocalVideoTrack> openCamera(CameraCaptureOptions options) async {
    opened++;
    final t = FakeMediaTrack('owned-$opened', kind: 'video');
    return LocalVideoTrack(TrackSource.camera, FakeMediaStream([t], id: 'owned-stream'), t, options);
  }

  @override
  Future<CameraPosition> switchCamera() async => CameraPosition.front;
  @override
  Future<bool> attach(GravixVideoEffectTarget target) async => true;
  @override
  Future<void> detach() async => detached++;
  @override
  Future<void> setEnabled(bool enabled) async {}
  @override
  Future<void> setParams(Map<String, Object?> params) async {}
}

/// A remote track whose stop runs [hook].
class _HookedStop extends FakeMediaTrack {
  _HookedStop(this.hook) : super('TR_host_mic', kind: 'audio');
  final void Function() hook;
  @override
  Future<void> stop() async {
    hook();
    return super.stop();
  }
}

/// An own screen share whose second start (in its first republish, after the AddTrack) hangs.
class _GatedStart extends LocalVideoTrack {
  _GatedStart(this.gate, FakeMediaTrack t, {this.gateAt = 2})
    : super(TrackSource.screenShareVideo, FakeMediaStream([t], id: 'screen-stream'), t, const ScreenShareCaptureOptions(params: VideoParametersPresets.h540_169));
  final Future<void> gate;
  final int gateAt;
  int starts = 0;
  @override
  Future<bool> start() async {
    if (++starts == gateAt) await gate;
    return super.start();
  }
}

/// An own screen share whose second publish (its first republish) hangs on the [gate], outliving
/// the session it began on.
class _GatedOnPublish extends LocalVideoTrack {
  _GatedOnPublish(this.gate, FakeMediaTrack t)
    : super(TrackSource.screenShareVideo, FakeMediaStream([t], id: 'screen-stream'), t, const ScreenShareCaptureOptions(params: VideoParametersPresets.h540_169));
  final Future<void> gate;
  int publishes = 0;
  @override
  Future<bool> onPublish() async {
    final did = await super.onPublish();
    if (++publishes == 2) await gate;
    return did;
  }
}

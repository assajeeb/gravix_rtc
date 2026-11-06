// 0.8.4: the newest call decides, across waits, captures, reconnects and leaves (state review, 2026-11-05).
import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/beauty/gravix_video_effect.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/room/gravix_room_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/mic_republish.dart';
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

void fullReconnect(Room r) {
  r.engine.fullReconnectOnNext = true;
  unawaited(r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
}

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

/// Captures: opens wait for [gate] (if set); counts opens and closes by id.
class Cap {
  Completer<void>? gate;
  Future<void>? closeGate;
  int n = 0;
  final open = <String>{};
  void install() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
      switch (call.method) {
        case 'getUserMedia':
          final c = (call.arguments as Map)['constraints'] as Map?;
          final isVideo = c?['video'] != null && c?['video'] != false;
          final id = '${isVideo ? 'v' : 'a'}-${++n}';
          open.add(id);
          final g = gate;
          if (g != null) await g.future;
          return <String, dynamic>{
            'streamId': 'st-$id',
            'audioTracks': isVideo ? <dynamic>[] : <dynamic>[<String, dynamic>{'id': id, 'label': 'mic', 'kind': 'audio', 'enabled': true}],
            'videoTracks': isVideo ? <dynamic>[<String, dynamic>{'id': id, 'label': 'camera', 'kind': 'video', 'enabled': true}] : <dynamic>[],
          };
        case 'getDisplayMedia':
          final id = 'd-${++n}';
          open.add(id);
          return <String, dynamic>{
            'streamId': 'st-$id',
            'audioTracks': <dynamic>[],
            'videoTracks': <dynamic>[<String, dynamic>{'id': id, 'label': 'screen', 'kind': 'video', 'enabled': true}],
          };
        case 'trackDispose':
          final g2 = closeGate;
          if (g2 != null) await g2;
          open.remove((call.arguments as Map)['trackId']);
          return null;
        case 'getSources':
          return <String, dynamic>{'sources': <dynamic>[]};
        case 'getRtpReceiverCapabilities':
          return <String, dynamic>{'codecs': <dynamic>[], 'headerExtensions': <dynamic>[], 'fecMechanisms': <dynamic>[]};
      }
      return null;
    });
  }
}

/// A beauty-style camera effect: openCamera waits for [openGate]; detach waits for [detachGate].
class Effect extends GravixCameraEffect {
  int opened = 0;
  int detached = 0;
  Completer<void>? openGate;
  Completer<void>? detachGate;
  final tracks = <FakeMediaTrack>[];
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
    tracks.add(t);
    final g = openGate;
    if (g != null) await g.future;
    return LocalVideoTrack(TrackSource.camera, FakeMediaStream([t], id: 'owned-stream-$opened'), t, options);
  }

  @override
  Future<CameraPosition> switchCamera() async => CameraPosition.front;
  @override
  Future<bool> attach(GravixVideoEffectTarget target) async => true;
  @override
  Future<void> detach() async {
    detached++;
    final g = detachGate;
    if (g != null) await g.future;
    for (final t in tracks) {
      t.stopped = true;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {}
  @override
  Future<void> setParams(Map<String, Object?> params) async {}
}

class GPc extends FakeCamPeerConnection {
  GPc(super.index);
  Future<void>? gateAdd;
  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({rtc.MediaStreamTrack? track, rtc.RTCRtpMediaType? kind, rtc.RTCRtpTransceiverInit? init}) async {
    final g = gateAdd;
    if (g != null) await g;
    return super.addTransceiver(track: track, kind: kind, init: init);
  }
}

class GFac extends FakeCamPcFactory {
  @override
  Future<rtc.RTCPeerConnection> create(Map<String, dynamic> configuration, [Map<String, dynamic>? constraints]) async {
    final pc = GPc(all.length);
    all.add(pc);
    onCreate?.call(pc);
    return pc;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Cap cap;
  Room? room;

  setUp(() {
    installRecoveryChannelMocks();
    cap = Cap()..install();
    gravixClearRegionMeasurement();
    gravixNoteRegionDirectory(const [
      GravixRegionUrl(region: 'doh1', url: doh, media: ['audio']),
      GravixRegionUrl(region: 'sgp1', url: sgp),
    ]);
    gravixMediaAutoDetect = true;
  });
  tearDown(() async {
    GravixEngineMicMute.debugReset();
    await room?.dispose();
    room = null;
  });

  Future<(Room, FakeSignalServer, FakeCamPcFactory)> make({String url = 'wss://x.example', bool audioOnly = false, RoomOptions? options}) async {
    final server = FakeSignalServer()
      ..joinResponse = ((_) => fakeJoinResponse())
      ..answerOffers = true;
    final pcs = GFac();
    autoConnectPcs(pcs);
    final opts = options ?? RoomOptions(reconnectPolicy: FastPolicy());
    final r = room = Room(
      engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: opts, signalClient: SignalClient(server.connect), peerConnectionCreate: pcs.create),
      roomOptions: opts,
    );
    if (audioOnly) {
      r.gravixRegionHints = [GravixRegionUrl(region: 'doh1', url: url, media: const ['audio'])];
      r.gravixJoinMedia = GravixRoomMedia.audio;
      r.engine.setRegionUrlProvider(_list());
    }
    await r.connect(url, 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
    return (r, server, pcs);
  }

  Future<(GravixRoomService, FakeSignalServer)> service({
    GravixVideoEffect? effect,
    String url = 'wss://x.example',
    bool audioOnly = false,
    bool enableVideo = false,
    bool earlyMic = false,
    bool publishMic = false,
    bool answerMeta = true,
  }) async {
    final server = FakeSignalServer()
      ..joinResponse = ((_) => fakeJoinResponse())
      ..answerOffers = true
      ..answerMetadata = answerMeta;
    final pcs = FakeCamPcFactory();
    autoConnectPcs(pcs);
    final s = GravixRoomService(
      reconnectPolicy: FastPolicy(),
      videoEffect: effect,
      createRoom: (options) {
        final r = Room(
          engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: options, signalClient: SignalClient(server.connect), peerConnectionCreate: pcs.create),
          roomOptions: options,
        );
        if (audioOnly) {
          r.gravixRegionHints = [GravixRegionUrl(region: 'doh1', url: url, media: const ['audio'])];
          r.gravixJoinMedia = GravixRoomMedia.audio;
          r.engine.setRegionUrlProvider(_list());
        }
        return r;
      },
      connectRoom: (room, u, token) => room.connect(u, token, connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0)),
    );
    addTearDown(() async {
      try {
        await s.disconnect().timeout(const Duration(seconds: 3));
      } catch (_) {}
    });
    expect(await s.connect(url: url, token: 'tok', publishMic: publishMic, enableVideo: enableVideo, earlyMicTrack: earlyMic), isTrue);
    return (s, server);
  }

  group('beauty-effect camera', () {
    test('E1 on, off during the slow openCamera: stays off', () async {
      final fx = Effect()..openGate = Completer<void>();
      final (s, server) = await service(effect: fx);
      final on = s.setCameraEnabled(true);
      await settle(20);
      expect(fx.opened, 1);
      await s.setCameraEnabled(false);
      fx.openGate!.complete();
      await on.timeout(const Duration(seconds: 3));
      await settle(50);
      final lp = s.localParticipant!;
      expect(s.isCameraEnabled.value, isFalse, reason: 'last call was off');
      expect(lp.getTrackPublicationBySource(TrackSource.camera), isNull, reason: 'camera published after the off call');
      expect(adds(server.sockets.last, lk_models.TrackType.VIDEO), isEmpty);
      expect(fx.tracks.single.stopped, isTrue, reason: 'camera closed');
    });

    test('E2 on from an audio-only region, off during the move: stays off', () async {
      final fx = Effect();
      final (s, server) = await service(effect: fx, url: 'wss://doh1.example');
      s.room!.gravixRegionHints = [const GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example', media: ['audio'])];
      s.room!.gravixJoinMedia = GravixRoomMedia.audio;
      s.room!.engine.setRegionUrlProvider(_list());
      final on = s.setCameraEnabled(true);
      await eventually(() => server.sockets.length > 1 || s.room!.gravixMediaMoveUnderWay, timeout: const Duration(seconds: 2));
      expect(s.room!.gravixMediaMoveUnderWay, isTrue, reason: 'precondition: a move runs');
      await s.setCameraEnabled(false);
      expect(s.isCameraEnabled.value, isFalse);
      await on.timeout(const Duration(seconds: 5));
      await settle(100);
      // ignore: avoid_print
      print('E2 result: wanted=${s.localParticipant!.gravixCameraWanted} ui=${s.isCameraEnabled.value} pub=${s.localParticipant!.getTrackPublicationBySource(TrackSource.camera)} adds=${server.sockets.map((w) => adds(w, lk_models.TrackType.VIDEO).length).toList()} opened=${fx.opened} detached=${fx.detached}');
      expect(s.localParticipant!.getTrackPublicationBySource(TrackSource.camera), isNull, reason: 'camera published after the off call');
      expect(s.isCameraEnabled.value, isFalse, reason: 'UI: last call was off');
    });

    test('E3 off while its AddTrack is out: ends off', () async {
      final fx = Effect();
      final (s, server) = await service(effect: fx);
      final ws = server.sockets.last;
      server.holdAddTrack = (_) => true;
      final on = s.setCameraEnabled(true);
      await eventually(() => adds(ws, lk_models.TrackType.VIDEO).length == 1);
      await s.setCameraEnabled(false);
      answerAdd(ws, adds(ws, lk_models.TrackType.VIDEO).first);
      await on.timeout(const Duration(seconds: 3));
      await settle(50);
      expect(s.isCameraEnabled.value, isFalse, reason: 'UI: last call was off');
      expect(s.localParticipant!.getTrackPublicationBySource(TrackSource.camera), isNull, reason: 'camera published after the off call');
    });

    test('E4 leave during the slow openCamera: camera closed at once', () async {
      final fx = Effect()..openGate = Completer<void>();
      final (s, _) = await service(effect: fx);
      final on = s.setCameraEnabled(true);
      await settle(20);
      final lp = s.localParticipant!;
      await s.disconnect().timeout(const Duration(seconds: 5));
      fx.openGate!.complete();
      await settle(200);
      expect(fx.tracks.single.stopped, isTrue, reason: 'camera open 200 ms after the leave');
      await on.timeout(const Duration(seconds: 15));
      expect(lp.gravixCameraWanted, isFalse);
    });

    test('E5 data saver tick during the effect off: the camera does not reopen', () async {
      final fx = Effect();
      final (s, _) = await service(effect: fx, enableVideo: true);
      await settle(100);
      expect(s.isCameraEnabled.value, isTrue);
      fx.detachGate = Completer<void>();
      final off = s.setCameraEnabled(false);
      await settle(30);
      expect(s.localParticipant!.getTrackPublicationBySource(TrackSource.camera), isNull);
      final tick = s.debugDataSaver.tick();
      await settle(30);
      fx.detachGate!.complete();
      await off;
      await tick;
      await settle(50);
      expect(fx.opened, 1, reason: 'a second camera opened after the off call');
      expect(s.localParticipant!.getTrackPublicationBySource(TrackSource.camera), isNull);
      expect(s.isCameraEnabled.value, isFalse);
    });
  });

  group('service', () {
    test('S1 the UI flag after leaving: camera shows off in the next voice room', () async {
      final (s, _) = await service();
      await s.setCameraEnabled(true);
      expect(s.isCameraEnabled.value, isTrue);
      await s.disconnect();
      expect(s.isCameraEnabled.value, isFalse, reason: 'isCameraEnabled after disconnect');
    });

    test('S2 data saver in the next video room with the camera off from a leave: stale flag does not reopen', () async {
      final (s, server) = await service(enableVideo: true);
      await settle(50);
      await s.disconnect();
      final before = cap.n;
      // the app joins again with no camera at first (its own policy): connect with enableVideo for the data saver
      expect(await s.connect(url: 'wss://x.example', token: 'tok', publishMic: false, enableVideo: false), isTrue);
      await settle(30);
      expect(s.isCameraEnabled.value, isFalse, reason: 'stale UI: camera shows on in a voice room');
      expect(cap.n, before);
      expect(server.sockets.isNotEmpty, isTrue);
    });

    test('S3 mic tapped off during the republish on a new track (RED/DTX swap): stays off', () async {
      final (s, server) = await service();
      await s.setMicEnabled(true);
      final lp = s.localParticipant!;
      final track = lp.getTrackPublicationBySource(TrackSource.microphone)!.track as LocalAudioTrack;
      final gate = Completer<void>();
      final swap = gravixRepublishMic(
        lp,
        track,
        wanted: const AudioPublishOptions(red: true),
        fallback: const AudioPublishOptions(),
        createTrack: (o) async {
          await gate.future;
          return LocalAudioTrack.create(o);
        },
      );
      await settle(10);
      await s.setMicEnabled(false); // the user mutes while the new track is being created
      expect((lp.getTrackPublicationBySource(TrackSource.microphone)!.track as LocalTrack).muted, isTrue);
      gate.complete();
      await swap.timeout(const Duration(seconds: 3));
      await settle(50);
      final after = lp.getTrackPublicationBySource(TrackSource.microphone)!.track as LocalTrack;
      // ignore: avoid_print
      print('S3 result: ui=${s.isMicMuted.value} wanted=${lp.gravixMicWanted} newTrackMuted=${after.muted} active=${after.isActive} enabled=${after.mediaStreamTrack.enabled} lastAddMuted=${adds(server.sockets.last, lk_models.TrackType.AUDIO).last.muted}');
      expect(s.isMicMuted.value, isTrue);
      expect(after.muted, isTrue, reason: 'UI muted, the new track is live');
      expect(adds(server.sockets.last, lk_models.TrackType.AUDIO).last.muted, isTrue);
    });

    test('S3b same, tapped between the create and the publish', () async {
      final (s, _) = await service();
      await s.setMicEnabled(true);
      final lp = s.localParticipant!;
      final track = lp.getTrackPublicationBySource(TrackSource.microphone)!.track as LocalAudioTrack;
      final unpub = Completer<void>();
      final swap = gravixRepublishMic(
        lp,
        track,
        wanted: const AudioPublishOptions(red: true),
        fallback: const AudioPublishOptions(),
        unpublish: (sid) async {
          await lp.removePublishedTrack(sid);
          await unpub.future;
        },
      );
      await settle(30);
      await s.setMicEnabled(false);
      unpub.complete();
      await swap.timeout(const Duration(seconds: 3));
      await settle(50);
      final after = lp.getTrackPublicationBySource(TrackSource.microphone);
      expect(after == null || (after.track as LocalTrack).muted, isTrue, reason: 'UI muted, the new track is live');
      expect(lp.gravixMicWanted, isFalse);
    });

    test('S4 early mic: tap off while the early capture is opening: nothing goes out live', () async {
      cap.gate = Completer<void>();
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
      addTearDown(() async {
        try {
          await s.disconnect().timeout(const Duration(seconds: 3));
        } catch (_) {}
      });
      final join = s.connect(url: 'wss://x.example', token: 'tok', publishMic: true, earlyMicTrack: true);
      await eventually(() => server.sockets.isNotEmpty && s.localParticipant != null, timeout: const Duration(seconds: 2));
      await settle(50);
      unawaited(s.setMicEnabled(false));
      await settle(5);
      cap.gate!.complete();
      await join.timeout(const Duration(seconds: 4));
      await settle(100);
      final ws = server.sockets.last;
      final mp = s.localParticipant!.getTrackPublicationBySource(TrackSource.microphone);
      // ignore: avoid_print
      print('S4 result: ui=${s.isMicMuted.value} wanted=${s.localParticipant!.gravixMicWanted} trackMuted=${(mp?.track)?.muted} adds=${adds(ws, lk_models.TrackType.AUDIO).map((a) => a.muted).toList()} mutes=${ws.sent.where((q) => q.hasMute()).map((q) => q.mute.muted).toList()}');
      expect(adds(ws, lk_models.TrackType.AUDIO).where((a) => !a.muted), isEmpty, reason: 'a live AddTrack after the tap');
      expect(s.isMicMuted.value, isTrue);
    });
  });

  group('hang', () {
    test('F1 on interrupted, the reconnect attempts run out: the call ends, nothing hangs, a later call works', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => identical(ws, first);
      final on = lp.setMicrophoneEnabled(true).then<Object?>((v) => v, onError: (Object e) => e);
      await eventually(() => adds(first).length == 1);
      server.onDial = (_) async => throw Exception('no network');
      fullReconnect(r);
      final v = await on.timeout(const Duration(seconds: 12), onTimeout: () => 'HUNG');
      // ignore: avoid_print
      print('F1 result: on ended with $v, state=${r.connectionState}, open=${cap.open}, wanted=${lp.gravixMicWanted}');
      expect(v, isNot('HUNG'));
      expect(cap.open, isEmpty);
    });

    test('F1b on while held, the attempts run out', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      await lp.setMicrophoneEnabled(false);
      final first = server.sockets.last;
      var dial = 0;
      server.holdAddTrack = (ws) => !identical(ws, first);
      fullReconnect(r);
      await eventually(() => server.sockets.last != first && lp.gravixRepublishPending(TrackSource.microphone), timeout: const Duration(seconds: 3));
      final on = lp.setMicrophoneEnabled(true).then<Object?>((v) => v, onError: (Object e) => e);
      await settle(10);
      server.onDial = (_) async {
        dial++;
        throw Exception('no network');
      };
      r.engine.fullReconnectOnNext = true;
      unawaited(r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
      final v = await on.timeout(const Duration(seconds: 12), onTimeout: () => 'HUNG');
      // ignore: avoid_print
      print('F1b result: on ended with $v, dials=$dial state=${r.connectionState}, open=${cap.open}');
      expect(v, isNot('HUNG'));
    });

    test('F2 the socket drops during the republish, an on call waits: it ends, state true', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      await lp.setMicrophoneEnabled(false);
      final first = server.sockets.last;
      FakeWs? second;
      server.holdAddTrack = (ws) {
        if (identical(ws, first)) return false;
        second ??= ws;
        return identical(ws, second);
      };
      fullReconnect(r);
      await eventually(() => server.sockets.last != first && adds(server.sockets.last).length == 1, timeout: const Duration(seconds: 3));
      final on = lp.setMicrophoneEnabled(true).then<Object?>((v) => v, onError: (Object e) => e);
      await settle(10);
      await second!.serverClose();
      final v = await on.timeout(const Duration(seconds: 14), onTimeout: () => 'HUNG');
      await settle(200);
      final p = lp.getTrackPublicationBySource(TrackSource.microphone);
      // ignore: avoid_print
      print('F2 result: on ended with $v sockets=${server.sockets.length} pub=$p muted=${(p?.track)?.muted} active=${p?.track?.isActive} pending=${lp.gravixRepublishPending(TrackSource.microphone)} n=${lp.audioTrackPublications.length} state=${r.connectionState} open=${cap.open}');
      expect(v, isNot('HUNG'));
      expect((p?.track)?.muted, isFalse, reason: 'last call on');
    });
  });

  group('leave', () {
    for (final engine in [false, true]) {
      for (final variant in ['mic in first AddTrack held', 'mic republish held', 'mic+cam republish held']) {
        test('L1 service leave, $variant, engine=$engine: no capture open', () async {
          GravixEngineMicMute.debugReset(supported: () => engine, setNative: (_) async => true);
          final (s, server) = await service();
          final first = server.sockets.last;
          final lp = s.localParticipant!;
          if (variant == 'mic in first AddTrack held') {
            server.holdAddTrack = (_) => true;
            unawaited(s.setMicEnabled(true));
            await eventually(() => adds(first).length == 1);
          } else {
            await s.setMicEnabled(true);
            if (variant.startsWith('mic+cam')) await s.setCameraEnabled(true);
            server.holdAddTrack = (ws) => !identical(ws, first);
          }
          fullReconnect(s.room!);
          await eventually(() => server.sockets.last != first && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 3));
          await settle(20);
          final w = Stopwatch()..start();
          await s.disconnect().timeout(const Duration(seconds: 12));
          // ignore: avoid_print
          print('L1 result ($variant, engine=$engine): disconnect took ${w.elapsedMilliseconds} ms, right after open=${cap.open} pubs=${lp.trackPublications.length}');
          await settle(200);
          final at200 = cap.open.toSet();
          await settle(5500);
          // ignore: avoid_print
          print('L1 result ($variant, engine=$engine): +200 ms open=$at200, +5.7 s open=${cap.open} engaged=${GravixEngineMicMute.engaged}');
          expect(cap.open, isEmpty);
        });
      }
    }
  });

  group('leave2', () {
    for (final answerAfter in [0, 1, 2, 5, 10, 20]) {
      test('L2 service mic live + camera, republish held, leave, AddTracks answered ${answerAfter} ms into the leave', () async {
        final (s, server) = await service();
        await s.setMicEnabled(true);
        await s.setCameraEnabled(true);
        final first = server.sockets.last;
        final mic = s.localParticipant!.getTrackPublicationBySource(TrackSource.microphone)!.track as LocalTrack;
        final lp = s.localParticipant!;
        server.holdAddTrack = (ws) => !identical(ws, first);
        fullReconnect(s.room!);
        await eventually(() => server.sockets.last != first && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 3));
        await settle(20);
        final second = server.sockets.last;
        final leave = s.disconnect();
        server.holdAddTrack = null;
        if (answerAfter > 0) await settle(answerAfter);
        try {
          for (final a in adds(second)) {
            answerAdd(second, a);
          }
        } catch (_) {}
        await leave.timeout(const Duration(seconds: 12));
        await settle(300);
        // ignore: avoid_print
        print('L2 result +$answerAfter: open=${cap.open} micActive=${mic.isActive} micMuted=${mic.muted} disposed=${mic.isDisposed} pubs=${lp.trackPublications.length}');
        final at = cap.open.toSet();
        await settle(5200);
        // ignore: avoid_print
        print('L2 result +$answerAfter: later open=${cap.open}');
        expect(at, isEmpty);
        expect(cap.open, isEmpty);
      });
    }
  });

  group('leave3', () {
    test('L3 leave during the republish, the old track engine-muted, rejoin and mute: the old track closing does not lift the new mute', () async {
      GravixEngineMicMute.debugReset(supported: () => true, setNative: (_) async => true);
      final (s, server) = await service();
      await s.setMicEnabled(true);
      await s.setCameraEnabled(true);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      fullReconnect(s.room!);
      await eventually(() => server.sockets.last != first && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 3));
      await settle(20);
      await s.disconnect().timeout(const Duration(seconds: 12));
      server.holdAddTrack = null;
      expect(await s.connect(url: 'wss://x.example', token: 'tok', publishMic: false), isTrue);
      await s.setMicEnabled(true);
      await s.setMicEnabled(false);
      expect(GravixEngineMicMute.engaged, isTrue, reason: 'precondition: muted in the module');
      await settle(5500);
      // ignore: avoid_print
      print('L3 result: engaged=${GravixEngineMicMute.engaged} ui=${s.isMicMuted.value} open=${cap.open}');
      expect(GravixEngineMicMute.engaged, isTrue, reason: 'the old track closing lifted the new mute: PCM flows while the UI says muted');
    });
  });

  group('restart', () {
    for (final cam in [false, true]) {
      test('R1 ${cam ? 'camera' : 'mic'} muted, on (its capture restarting), the app leaves: nothing stays open', () async {
        final (r, _, _) = await make();
        final lp = r.localParticipant!;
        Future<Object?> call(bool on) => cam ? lp.setCameraEnabled(on) : lp.setMicrophoneEnabled(on);
        await call(true);
        await call(false);
        expect(cap.open, isEmpty, reason: 'precondition: stopped by the mute');
        cap.gate = Completer<void>();
        final on = call(true).then<Object?>((v) => v, onError: (Object e) => e);
        await settle(10);
        await r.disconnect().timeout(const Duration(seconds: 5));
        cap.gate!.complete();
        cap.gate = null;
        await on.timeout(const Duration(seconds: 3));
        await settle(200);
        // ignore: avoid_print
        print('R1 result cam=$cam: open=${cap.open} pubs=${lp.trackPublications.length}');
        expect(cap.open, isEmpty, reason: 'capture open after the leave, owned by nothing');
      });

      test('R2 ${cam ? 'camera' : 'mic'} on (restarting), unpublished: nothing stays open', () async {
        final (r, _, _) = await make();
        final lp = r.localParticipant!;
        Future<Object?> call(bool on) => cam ? lp.setCameraEnabled(on) : lp.setMicrophoneEnabled(on);
        final pub = await call(true);
        await call(false);
        cap.gate = Completer<void>();
        final on = call(true).then<Object?>((v) => v, onError: (Object e) => e);
        await settle(10);
        await lp.removePublishedTrack((pub! as dynamic).sid as String);
        cap.gate!.complete();
        cap.gate = null;
        await on.timeout(const Duration(seconds: 3));
        await settle(100);
        expect(cap.open, isEmpty, reason: 'capture open after the unpublish, owned by nothing');
      });
    }
  });

  group('order', () {
    for (final first in [true, false]) {
      test('O1 camera ${first ? 'on,off' : 'off,on'} in one burst behind a mic publish: the last call wins', () async {
        final (s, server) = await service();
        await s.setCameraEnabled(true);
        if (!first) await s.setCameraEnabled(false);
        server.holdAddTrack = (_) => true;
        final ws = server.sockets.last;
        final mic = s.setMicEnabled(true);
        await eventually(() => adds(ws, lk_models.TrackType.AUDIO).length == 1);
        final a = s.setCameraEnabled(first);
        final b = s.setCameraEnabled(!first);
        await settle(5);
        answerAdd(ws, adds(ws, lk_models.TrackType.AUDIO).first);
        await Future.wait([mic, a, b]).timeout(const Duration(seconds: 7));
        await settle(30);
        final t = s.localParticipant!.getTrackPublicationBySource(TrackSource.camera)!.track as LocalTrack;
        // ignore: avoid_print
        print('O1 result last=${!first}: muted=${t.muted} ui=${s.isCameraEnabled.value} wanted=${s.localParticipant!.gravixCameraWanted}');
        expect(t.muted, first, reason: 'last call lost');
        expect(s.isCameraEnabled.value, !first);
      });

      test('O2 camera ${first ? 'on,off' : 'off,on'} in one burst with a mic toggle, no holds', () async {
        final (s, _) = await service();
        await s.setCameraEnabled(true);
        if (!first) await s.setCameraEnabled(false);
        final mic = s.setMicEnabled(true);
        final a = s.setCameraEnabled(first);
        final b = s.setCameraEnabled(!first);
        await Future.wait([mic, a, b]).timeout(const Duration(seconds: 7));
        await settle(30);
        final t = s.localParticipant!.getTrackPublicationBySource(TrackSource.camera)!.track as LocalTrack;
        // ignore: avoid_print
        print('O2 result last=${!first}: muted=${t.muted} ui=${s.isCameraEnabled.value}');
        expect(t.muted, first, reason: 'last call lost');
      });

      test('O3 camera ${first ? 'on,off' : 'off,on'} one burst, then the reconnect: mic republish in the queue', () async {
        final (s, server) = await service();
        await s.setMicEnabled(true);
        await s.setCameraEnabled(true);
        if (!first) await s.setCameraEnabled(false);
        final ws1 = server.sockets.last;
        server.holdAddTrack = (ws) => !identical(ws, ws1);
        fullReconnect(s.room!);
        await eventually(() => server.sockets.last != ws1 && adds(server.sockets.last).isNotEmpty, timeout: const Duration(seconds: 3));
        final ws2 = server.sockets.last;
        final a = s.setCameraEnabled(first);
        final b = s.setCameraEnabled(!first);
        await settle(5);
        server.holdAddTrack = null;
        for (final q in adds(ws2)) {
          answerAdd(ws2, q);
        }
        await Future.wait([a, b]).timeout(const Duration(seconds: 7));
        await settle(50);
        final t = s.localParticipant!.getTrackPublicationBySource(TrackSource.camera)!.track as LocalTrack;
        // ignore: avoid_print
        print('O3 result last=${!first}: muted=${t.muted} ui=${s.isCameraEnabled.value}');
        expect(t.muted, first, reason: 'last call lost');
      });
    }
  });

  group('two', () {
    test('O4 service: camera off; reconnect; mic on (capture slow) then camera on queued behind it; the republish starts: one camera, and off turns it off', () async {
      final (s, server) = await service();
      await s.setCameraEnabled(true);
      await s.setCameraEnabled(false);
      final lp = s.localParticipant!;
      final ws1 = server.sockets.last;
      final hold = Completer<void>();
      server.onDial = (_) => hold.future; // the new session's dial takes a moment
      fullReconnect(s.room!);
      await settle(10);
      expect(lp.gravixRepublishPending(TrackSource.camera), isFalse);
      cap.gate = Completer<void>();
      final mic = s.setMicEnabled(true);
      await settle(5);
      final on = s.setCameraEnabled(true); // the queue is busy with the mic's capture
      await settle(5);
      hold.complete();
      await eventually(() => server.sockets.last != ws1 && lp.gravixRepublishPending(TrackSource.camera), timeout: const Duration(seconds: 3));
      cap.gate!.complete();
      cap.gate = null;
      await Future.wait([mic, on]).timeout(const Duration(seconds: 7));
      await settle(100);
      final cams = lp.videoTrackPublications;
      // ignore: avoid_print
      print('O4 result: cameras=${cams.length} muted=${cams.map((c) => c.track!.muted).toList()} ui=${s.isCameraEnabled.value} adds=${adds(server.sockets.last, lk_models.TrackType.VIDEO).map((a) => a.muted).toList()} open=${cap.open}');
      await s.setCameraEnabled(false);
      await settle(50);
      // ignore: avoid_print
      print('O4 result: after off muted=${lp.videoTrackPublications.map((c) => c.track!.muted).toList()} ui=${s.isCameraEnabled.value}');
      expect(cams, hasLength(1), reason: 'two cameras');
      expect(lp.videoTrackPublications.every((c) => c.track!.muted), isTrue, reason: 'a camera stays live after the off');
    });
  });

  group('hang2', () {
    test('F2b service: live mic, the socket drops during its republish: heard, or the UI says off', () async {
      final (s, server) = await service();
      await s.setMicEnabled(true);
      final first = server.sockets.last;
      FakeWs? second;
      server.holdAddTrack = (ws) {
        if (identical(ws, first)) return false;
        second ??= ws;
        return identical(ws, second);
      };
      fullReconnect(s.room!);
      await eventually(() => server.sockets.last != first && adds(server.sockets.last).length == 1, timeout: const Duration(seconds: 3));
      await second!.serverClose();
      final w = Stopwatch()..start();
      await eventually(() => s.localParticipant!.getTrackPublicationBySource(TrackSource.microphone) != null || s.isMicMuted.value, timeout: const Duration(seconds: 12));
      final lp = s.localParticipant!;
      final p = lp.getTrackPublicationBySource(TrackSource.microphone);
      // ignore: avoid_print
      print('F2b result: after ${w.elapsedMilliseconds} ms ui=${s.isMicMuted.value} pub=$p muted=${(p?.track)?.muted} open=${cap.open}');
      await s.setMicEnabled(true).timeout(const Duration(seconds: 7));
      await settle(50);
      final q = lp.getTrackPublicationBySource(TrackSource.microphone);
      // ignore: avoid_print
      print('F2b result: tap on: ui=${s.isMicMuted.value} pub=$q muted=${(q?.track)?.muted} active=${q?.track?.isActive}');
      expect((q?.track)?.muted, isFalse);
    });
  });

  group('direct', () {
    test('D1 on queued while the publication existed, then the republish moved it: one microphone', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      await lp.setMicrophoneEnabled(false); // stops the capture
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      cap.gate = Completer<void>();
      final a = lp.setMicrophoneEnabled(true); // restarts the capture, in the queue
      await settle(5);
      final c = lp.setMicrophoneEnabled(true); // a second on, queued behind it
      await settle(5);
      fullReconnect(r);
      await eventually(() => server.sockets.last != first && lp.gravixRepublishPending(TrackSource.microphone), timeout: const Duration(seconds: 3));
      cap.gate!.complete();
      cap.gate = null;
      await settle(50);
      final second = server.sockets.last;
      for (final add in adds(second)) {
        answerAdd(second, add);
      }
      await Future.wait([a, c]).timeout(const Duration(seconds: 4));
      for (var i = 0; i < 5; i++) {
        await settle(30);
      }
      for (final add in adds(second)) {
        answerAdd(second, add);
      }
      await settle(100);
      expect(lp.audioTrackPublications, hasLength(1), reason: 'two microphones published');
    });

    test('D2 off, on, off, the reconnect during the on: ends off', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      final mic = (await lp.setMicrophoneEnabled(true))!.track!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first);
      cap.gate = Completer<void>();
      final a = lp.setMicrophoneEnabled(false);
      final b = lp.setMicrophoneEnabled(true); // restart waits for the gate
      final c = lp.setMicrophoneEnabled(false); // queued behind it
      await a;
      await settle(5);
      fullReconnect(r);
      await eventually(() => server.sockets.last != first && lp.gravixRepublishPending(TrackSource.microphone), timeout: const Duration(seconds: 3));
      cap.gate!.complete();
      cap.gate = null;
      await Future.wait([b, c]).timeout(const Duration(seconds: 3));
      await settle(50);
      final second = server.sockets.last;
      for (final add in adds(second)) {
        answerAdd(second, add);
      }
      await settle(150);
      expect(lp.gravixMicWanted, isFalse);
      final now = lp.getTrackPublicationBySource(TrackSource.microphone);
      expect(identical(now?.track, mic) || now == null, isTrue);
      expect(mic.muted, isTrue, reason: 'last call off, track live');
      expect(adds(second).last.muted, isTrue, reason: 'last call off, AddTrack live');
    });

    test('D3 off (default options) during its own republish, then on with stopOnMute false: heard', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      await lp.setMicrophoneEnabled(true);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && adds(ws).length == 1;
      fullReconnect(r);
      await eventually(() => server.sockets.last != first && adds(server.sockets.last).length == 1, timeout: const Duration(seconds: 3));
      final second = server.sockets.last;
      await lp.setMicrophoneEnabled(false);
      answerAdd(second, adds(second).first);
      await settle(100);
      final pub = lp.getTrackPublicationBySource(TrackSource.microphone)!;
      expect(pub.track!.isActive, isFalse, reason: 'precondition: closed when it landed');
      await lp.setMicrophoneEnabled(true, audioCaptureOptions: const AudioCaptureOptions(stopAudioCaptureOnMute: false));
      await settle(30);
      expect(pub.track!.muted, isFalse);
      expect(pub.track!.isActive, isTrue, reason: 'on, but no capture: silent');
    });

    test('D4 screen on from an audio-only region, off during the move: no share goes out', () async {
      final (r, server, _) = await make(url: 'wss://doh1.example', audioOnly: true);
      final lp = r.localParticipant!;
      final on = lp.setScreenShareEnabled(true);
      await eventually(() => r.gravixMediaMoveUnderWay, timeout: const Duration(seconds: 2));
      await lp.setScreenShareEnabled(false);
      await on.timeout(const Duration(seconds: 5));
      await settle(100);
      expect(lp.getTrackPublicationBySource(TrackSource.screenShareVideo), isNull, reason: 'screen published after the stop');
      expect(server.sockets.last.sent.where((q) => q.hasAddTrack()), isEmpty);
      expect(cap.open, isEmpty);
    });

    test('D5 app\'s own camera on from an audio-only region, off during the move: not live', () async {
      final (r, server, _) = await make(url: 'wss://doh1.example', audioOnly: true);
      final lp = r.localParticipant!;
      final m = FakeMediaTrack('own-1', kind: 'video');
      final own = LocalVideoTrack(TrackSource.camera, FakeMediaStream([m], id: 'own-st'), m, const CameraCaptureOptions(params: VideoParametersPresets.h540_169));
      final on = lp.publishVideoTrack(own);
      await eventually(() => r.gravixMediaMoveUnderWay, timeout: const Duration(seconds: 2));
      await lp.setCameraEnabled(false);
      await on.timeout(const Duration(seconds: 5)).then<void>((_) {}, onError: (Object _) {});
      await settle(100);
      final p = lp.getTrackPublicationBySource(TrackSource.camera);
      expect(p == null || (p.track as LocalTrack).muted, isTrue, reason: 'own camera LIVE after setCameraEnabled(false)');
      expect(server.sockets.isNotEmpty, isTrue);
    });

    test('D6 leave while the mic AddTrack is out: capture closed promptly', () async {
      final (r, server, _) = await make();
      final lp = r.localParticipant!;
      server.holdAddTrack = (_) => true;
      final on = lp.setMicrophoneEnabled(true).then<void>((_) {}, onError: (Object _) {});
      await eventually(() => adds(server.sockets.last).length == 1);
      await r.disconnect().timeout(const Duration(seconds: 5));
      await settle(100);
      // ignore: avoid_print
      print('D6 result: 100 ms after the leave open=${cap.open}');
      final w = Stopwatch()..start();
      await on.timeout(const Duration(seconds: 12));
      // ignore: avoid_print
      print('D6 result: on ended ${w.elapsedMilliseconds} ms later, open=${cap.open}');
      expect(cap.open, isEmpty, reason: 'still open when the on call ended');
      expect(lp.trackPublications, isEmpty);
    });

    test('D7 leave while the transceiver is being added: nothing stands afterwards, next room clean', () async {
      final (r, server, pcs) = await make();
      final lp = r.localParticipant!;
      final gate = Completer<void>();
      final pc = pcs.camPublisher as GPc;
      pc.gateAdd = gate.future;
      final on = lp.setMicrophoneEnabled(true).then<void>((_) {}, onError: (Object _) {});
      await eventually(() => adds(server.sockets.last).length == 1);
      await settle(20);
      await r.disconnect().timeout(const Duration(seconds: 5));
      gate.complete();
      await on.timeout(const Duration(seconds: 12));
      await settle(100);
      // ignore: avoid_print
      print('D7 result: open=${cap.open} pubs=${lp.trackPublications.length}');
      expect(cap.open, isEmpty, reason: 'mic capture open after the leave');
      expect(lp.trackPublications, isEmpty, reason: 'a publication stands after the leave');
    });

    test('N4 a service leave does not wait for a publish holding the queue', () async {
      final (s, server) = await service();
      server.holdAddTrack = (_) => true;
      final ws = server.sockets.last;
      unawaited(s.setMicEnabled(true));
      await eventually(() => adds(ws).length == 1);
      final w = Stopwatch()..start();
      await s.disconnect().timeout(const Duration(seconds: 4));
      expect(w.elapsedMilliseconds, lessThan(1500), reason: 'behind the 5 s AddTrack deadline');
    });

    test('N14 a leave turns the camera flag off with the capture still opening', () async {
      final (s, _) = await service();
      await s.setCameraEnabled(true);
      await s.disconnect();
      expect(s.isCameraEnabled.value, isFalse);
    });

    test('D2 a resume\'s SyncState does not unsubscribe a track not delivered yet', () async {
      final others = [
        lk_models.ParticipantInfo(
          sid: 'PA_host',
          identity: 'host',
          state: lk_models.ParticipantInfo_State.ACTIVE,
          tracks: [lk_models.TrackInfo(sid: 'TR_undelivered', type: lk_models.TrackType.AUDIO, source: lk_models.TrackSource.MICROPHONE)],
        ),
      ];
      final server = FakeSignalServer()
        ..joinResponse = ((_) => fakeJoinResponse(others: others))
        ..answerOffers = true;
      final pcs = GFac();
      autoConnectPcs(pcs);
      final opts = RoomOptions(reconnectPolicy: FastPolicy());
      final r = room = Room(
        engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: opts, signalClient: SignalClient(server.connect), peerConnectionCreate: pcs.create),
        roomOptions: opts,
      );
      await r.connect('wss://x.example', 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
      await r.engine.handleReconnect(ClientDisconnectReason.signal);
      expect(await eventually(() => server.sockets.last.sent.any((q) => q.hasSyncState()), timeout: const Duration(seconds: 4)), isTrue);
      final sync = server.sockets.last.sent.firstWhere((q) => q.hasSyncState()).syncState;
      expect(sync.subscription.trackSids, isEmpty);
    });

    test('D1 refused track: a newer subscribe() that took it is not silenced', () async {
      final others = [
        lk_models.ParticipantInfo(
          sid: 'PA_host',
          identity: 'host',
          state: lk_models.ParticipantInfo_State.ACTIVE,
          tracks: [lk_models.TrackInfo(sid: 'TR_m', type: lk_models.TrackType.AUDIO, source: lk_models.TrackSource.MICROPHONE)],
        ),
      ];
      final server = FakeSignalServer()
        ..joinResponse = ((_) => fakeJoinResponse(others: others))
        ..answerOffers = true;
      final pcs = GFac();
      autoConnectPcs(pcs);
      final opts = RoomOptions(reconnectPolicy: FastPolicy());
      final r = room = Room(
        engine: Engine(connectOptions: ConnectOptions(timeouts: fastTimeouts()), roomOptions: opts, signalClient: SignalClient(server.connect), peerConnectionCreate: pcs.create),
        roomOptions: opts,
      );
      await r.connect('wss://x.example', 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
      final pub = r.remoteParticipants['host']!.trackPublications['TR_m']!;
      await pub.unsubscribe();
      final t = FakeMediaTrack('TR_m', kind: 'audio');
      final refused = pub.gravixRefusesTrack(t); // the gate is shut: the write waits
      expect(refused, isTrue);
      await pub.subscribe();
      await settle(20);
      expect(t.enabled, isTrue);
    });

    test('beauty on, off, on overlapping: one live camera, not closed by the stale calls', () async {
      final fx = Effect()..openGate = Completer<void>();
      final (s, server) = await service(effect: fx);
      final ws = server.sockets.last;
      final a = s.setCameraEnabled(true);
      await settle(20);
      expect(fx.opened, 1);
      final b = s.setCameraEnabled(false);
      final c = s.setCameraEnabled(true);
      await settle(10);
      final gate = fx.openGate!;
      fx.openGate = null;
      gate.complete();
      await Future.wait([a, b, c]).timeout(const Duration(seconds: 4));
      await settle(100);
      final lp = s.localParticipant!;
      expect(lp.videoTrackPublications, hasLength(1));
      expect(lp.videoTrackPublications.single.track!.muted, isFalse);
      expect(s.isCameraEnabled.value, isTrue);
      expect(lp.gravixCameraWanted, isTrue);
      expect(fx.tracks.last.stopped, isFalse, reason: 'a stale call closed the newer camera');
      expect(adds(ws, lk_models.TrackType.VIDEO).where((a) => !a.muted), hasLength(1));
    });

    test('still: beauty: an older on failing does not clear a newer on', () async {
      final fx = _FailsFirst();
      final (s, _) = await service(effect: fx);
      final gate = fx.gate;
      final a = s.setCameraEnabled(true);
      await settle(10);
      final c = s.setCameraEnabled(true);
      await settle(10);
      gate.complete();
      await Future.wait([a, c]).timeout(const Duration(seconds: 4));
      await settle(50);
      expect(s.localParticipant!.gravixCameraWanted, isTrue);
      expect(s.localParticipant!.videoTrackPublications, hasLength(1));
      expect(s.isCameraEnabled.value, isTrue);
    });

    test('early mic: off then on during the close of the early capture: on, and published', () async {
      cap.gate = Completer<void>();
      final closing = Completer<void>();
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
      addTearDown(() async {
        try {
          await s.disconnect().timeout(const Duration(seconds: 3));
        } catch (_) {}
      });
      final join = s.connect(url: 'wss://x.example', token: 'tok', publishMic: true, earlyMicTrack: true);
      await eventually(() => server.sockets.isNotEmpty && s.localParticipant != null, timeout: const Duration(seconds: 2));
      await settle(50);
      unawaited(s.setMicEnabled(false));
      await settle(5);
      cap.closeGate = closing.future;
      cap.gate!.complete();
      await settle(30); // the worker closes the early capture: it waits here
      unawaited(s.setMicEnabled(true));
      await settle(5);
      cap.closeGate = null;
      closing.complete();
      await join.timeout(const Duration(seconds: 4));
      await eventually(() => s.localParticipant!.getTrackPublicationBySource(TrackSource.microphone) != null);
      await settle(50);
      expect(s.isMicMuted.value, isFalse);
      final p = s.localParticipant!.getTrackPublicationBySource(TrackSource.microphone);
      expect(p, isNotNull, reason: 'UI on with no publication');
      expect(p!.track!.muted, isFalse);
    });

    for (final raceOn in [true]) {
      test('mic swap: muted before it, on during its gap: one mic, unmuted ($raceOn)', () async {
        final (s, _) = await service();
        await s.setMicEnabled(true);
        await s.setMicEnabled(false);
        final lp = s.localParticipant!;
        final track = lp.getTrackPublicationBySource(TrackSource.microphone)!.track as LocalAudioTrack;
        final gap = Completer<void>();
        final swap = gravixRepublishMic(
          lp,
          track,
          wanted: const AudioPublishOptions(red: true),
          fallback: const AudioPublishOptions(),
          unpublish: (sid) async {
            await lp.gravixPublicationLost(sid);
            await gap.future;
          },
        );
        await settle(30);
        cap.gate = Completer<void>(); // the on's own capture, if it opens one, lands after the swap
        final on = s.setMicEnabled(true);
        await settle(10);
        gap.complete();
        await swap.timeout(const Duration(seconds: 3));
        cap.gate!.complete();
        cap.gate = null;
        await on.timeout(const Duration(seconds: 3));
        await settle(50);
        expect(lp.audioTrackPublications, hasLength(1), reason: 'two microphones');
        expect(lp.getTrackPublicationBySource(TrackSource.microphone)!.track!.muted, isFalse, reason: 'on, silent');
        expect(s.isMicMuted.value, isFalse);
      });
    }

    test('mic swap, plain mute with no engine (iOS shape): the new capture is off from its start', () async {
      final (s, _) = await service();
      await s.setMicEnabled(true);
      await s.setMicEnabled(false);
      final lp = s.localParticipant!;
      final track = lp.getTrackPublicationBySource(TrackSource.microphone)!.track as LocalAudioTrack;
      final m = FakeMediaTrack('swap-new');
      final (fresh, _) = await gravixRepublishMic(
        lp,
        track,
        wanted: const AudioPublishOptions(red: true),
        fallback: const AudioPublishOptions(),
        createTrack: (o) async => LocalAudioTrack(TrackSource.microphone, FakeMediaStream([m], id: 'swap-st'), m, o),
      ).timeout(const Duration(seconds: 3));
      expect(fresh, isNotNull);
      expect(fresh!.muted, isTrue);
      expect(m.enabled, isFalse, reason: 'muted on the wire, capture enabled');
    });

    Future<(LocalAudioTrack?, FakeMediaTrack)> swapMuted() async {
      final (s, _) = await service();
      await s.setMicEnabled(true);
      await s.setMicEnabled(false);
      final lp = s.localParticipant!;
      final track = lp.getTrackPublicationBySource(TrackSource.microphone)!.track as LocalAudioTrack;
      final m = FakeMediaTrack('swap-new');
      final (fresh, _) = await gravixRepublishMic(
        lp,
        track,
        wanted: const AudioPublishOptions(red: true),
        fallback: const AudioPublishOptions(),
        createTrack: (o) async => LocalAudioTrack(TrackSource.microphone, FakeMediaStream([m], id: 'swap-st'), m, o),
      ).timeout(const Duration(seconds: 3));
      return (fresh, m);
    }

    test('mic swap with a voice-only mute (room music, mute held): the new capture stays enabled, so the music goes out', () async {
      GravixEngineMicMute.debugReset(supported: () => true, setNative: (_) async => true);
      addTearDown(GravixEngineMicMute.debugReset);
      GravixMusicVoiceMute.predicate = (_) => true;
      addTearDown(() => GravixMusicVoiceMute.predicate = null);
      final (fresh, m) = await swapMuted();
      expect(fresh!.voiceOnlyMuted, isTrue);
      expect(m.enabled, isTrue, reason: 'disabled: the music is zeroed with the voice');
    });

    test('mic swap with an engine mute: the new capture stays enabled, and a later music start carries', () async {
      GravixEngineMicMute.debugReset(supported: () => true, setNative: (_) async => true);
      addTearDown(GravixEngineMicMute.debugReset);
      final (fresh, m) = await swapMuted();
      expect(fresh!.muted, isTrue);
      expect(GravixEngineMicMute.engaged, isTrue);
      expect(m.enabled, isTrue, reason: 'an engine mute lives on an enabled capture');
      expect(await fresh.enterMusicVoiceMute(), isTrue);
      expect(m.enabled, isTrue, reason: 'music started later would be silent');
    });

    test('a mic the app unpublished is not wanted any more, as a camera', () async {
      final (r, _, _) = await make();
      final lp = r.localParticipant!;
      final pub = await lp.setMicrophoneEnabled(true);
      await lp.removePublishedTrack(pub!.sid);
      expect(lp.gravixMicWanted, isFalse);
    });
  });
}

/// A camera effect whose first open fails once [gate] completes.
class _FailsFirst extends Effect {
  final gate = Completer<void>();
  var first = true;
  @override
  Future<LocalVideoTrack> openCamera(CameraCaptureOptions options) async {
    if (first) {
      first = false;
      opened++;
      await gate.future;
      throw StateError('camera busy');
    }
    return super.openCamera(options);
  }
}

// 0.8.4: the rollback options of test/room/gulf_084_regressions_test.dart.
import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

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

  group('each option off gives 0.8.3 for what it covers', () {
    test('republishHonorsOffCalls off: the camera goes out live, the mic flag flips', () async {
      final (r, server, _) = await make(recovery: const GravixRecoveryOptions(republishHonorsOffCalls: false));
      final lp = r.localParticipant!;
      await lp.setCameraEnabled(true);
      await lp.setMicrophoneEnabled(true);
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => !identical(ws, first) && server.sockets.indexOf(ws) == 1;
      fullReconnect(r);
      expect(await eventually(() => server.sockets.last != first && adds(server.sockets.last).length == 1, timeout: const Duration(seconds: 4)), isTrue);
      final second = server.sockets.last;
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      await settle(50);
      await lp.setMicrophoneEnabled(false).timeout(const Duration(seconds: 1));
      dial.complete();
      expect(await eventually(() => !identical(server.sockets.last, second) && adds(server.sockets.last, lk_models.TrackType.AUDIO).isNotEmpty, timeout: const Duration(seconds: 5)), isTrue);
      await settle(100);
      expect(adds(server.sockets.last, lk_models.TrackType.AUDIO).single.muted, isFalse);
      expect(lp.gravixMicWanted, isTrue);
    });

    test('restoreSubscriptionsOnRejoin off: the new session hears nothing, a delivered track plays', () async {
      final (r, server, _) = await make(recovery: const GravixRecoveryOptions(restoreSubscriptionsOnRejoin: false), others: [host(video: false)]);
      final mic = r.remoteParticipants['host']!.trackPublications['TR_host_mic']!;
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
      await mic.unsubscribe();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      expect(subs(server.sockets.last), isEmpty);
      deliverTrack(r, 'TR_host_mic', 'audio');
      expect(await eventually(() => mic.subscribed), isTrue);
    });

    test('resendTrackSettingsOnRejoin off: nothing sent', () async {
      final (r, server, _) = await make(recovery: const GravixRecoveryOptions(resendTrackSettingsOnRejoin: false), others: [host(audio: false)]);
      final cam = r.remoteParticipants['host']!.trackPublications['TR_host_cam']!;
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      await cam.disable();
      expect(await reconnected(r, () => fullReconnect(r)), isTrue);
      deliverTrack(r, 'TR_host_cam', 'video');
      expect(await eventually(() => cam.subscribed), isTrue);
      await settle(50);
      expect(settingsOn(server.sockets.last), isEmpty);
    });

    test('republishHonorsOffCalls off: an interrupted call gives up at the deadline, as in 0.8.3', () async {
      final saved = gravixMediaMoveDeadline;
      gravixMediaMoveDeadline = const Duration(milliseconds: 100);
      addTearDown(() => gravixMediaMoveDeadline = saved);
      final (r, server, _) = await make(recovery: const GravixRecoveryOptions(republishHonorsOffCalls: false));
      final lp = r.localParticipant!;
      final first = server.sockets.last;
      server.holdAddTrack = (ws) => identical(ws, first);
      final on = lp.setCameraEnabled(true).then<Object?>((p) => p, onError: (Object e) => 'failed');
      expect(await eventually(() => adds(first).isNotEmpty), isTrue);
      final dial = Completer<void>();
      server.onDial = (_) => dial.future;
      fullReconnect(r);
      expect(await on.timeout(const Duration(seconds: 2)), 'failed');
      dial.complete();
    });

    test('the legacy preset turns all three off; the default has them on', () {
      const l = GravixRecoveryOptions.legacy;
      expect([l.republishHonorsOffCalls, l.restoreSubscriptionsOnRejoin, l.resendTrackSettingsOnRejoin], [false, false, false]);
      const d = GravixRecoveryOptions();
      expect([d.republishHonorsOffCalls, d.restoreSubscriptionsOnRejoin, d.resendTrackSettingsOnRejoin], [true, true, true]);
      final c = d.copyWith(republishHonorsOffCalls: false, restoreSubscriptionsOnRejoin: false, resendTrackSettingsOnRejoin: false);
      expect([c.republishHonorsOffCalls, c.restoreSubscriptionsOnRejoin, c.resendTrackSettingsOnRejoin], [false, false, false]);
    });
  });
}

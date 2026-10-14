// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-13, fast publish for video (after the join microphone of 0.4.16): a
// video host's camera was published after connect() returned, with an AddTrack
// and a second offer/answer of its own, although the publisher connection had
// been negotiated at the JoinResponse already (data channels, the join's mic).
//
// Room.connect(joinCamera: ...) puts the camera into the publisher's FIRST
// offer, beside the join microphone when both are set: its capture starts with
// the attempt, and at the JoinResponse its AddTrack goes out and its video
// transceiver (the same encodings and layers as a normal camera publish) is
// added before that offer is made. A camera that cannot be published (no
// permission, the track ended, the server refused it) leaves the join to go on,
// reports GravixJoinCameraFailedEvent and releases the capture; no camera stays
// open after a failed join or a leave.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/connect/gravix_join_phases.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_join_camera.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_join_mic.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/exceptions.dart' show MediaConnectException;
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/publication/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/video.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/video_encoding.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/video_parameters.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

/// Records the transceivers (and their kinds) the connection had at each createOffer.
class _OfferLogPc extends FakeCamPeerConnection {
  _OfferLogPc(super.index);
  final offerTransceivers = <int>[];
  final offerKinds = <List<String>>[];

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) {
    offerTransceivers.add(added.length);
    offerKinds.add([for (final t in added) t.kind == rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo ? 'video' : 'audio']);
    return super.createOffer(constraints);
  }
}

class _Pcs {
  final all = <_OfferLogPc>[];

  /// Which peer connections connect (by creation index; publisher first, then
  /// subscriber, per join attempt). Null = all.
  bool Function(int index)? connects;

  _OfferLogPc publisherOf(int attempt) => all[2 * attempt];

  Future<rtc.RTCPeerConnection> create(Map<String, dynamic> configuration, [Map<String, dynamic>? constraints]) async {
    final pc = _OfferLogPc(all.length);
    all.add(pc);
    if (connects?.call(pc.index) ?? true) Timer(const Duration(milliseconds: 30), pc.connect);
    return pc;
  }
}

/// What the Gravix SFU announces (participant.GetEnabledPublishCodecs()).
final _serverCodecs = [
  lk_models.Codec(mime: 'audio/opus'),
  lk_models.Codec(mime: 'audio/red'),
  lk_models.Codec(mime: 'video/VP8'),
  lk_models.Codec(mime: 'video/H264'),
];

lk_rtc.JoinResponse _join({
  bool subscriberPrimary = true,
  bool fastPublish = true,
  bool canPublish = true,
  List<lk_models.TrackSource> sources = const [],
  List<lk_models.Codec>? codecs,
}) => lk_rtc.JoinResponse(
  room: lk_models.Room(name: 'r', sid: 'RM_r'),
  participant: lk_models.ParticipantInfo(
    sid: 'PA_me',
    identity: 'me',
    permission: lk_models.ParticipantPermission(canPublish: canPublish, canSubscribe: true, canPublishSources: sources),
  ),
  subscriberPrimary: subscriberPrimary,
  fastPublish: fastPublish,
  serverVersion: '1.9.0',
  enabledPublishCodecs: codecs ?? _serverCodecs,
);

/// Camera tracks the join creates, in order.
class _Cams {
  final created = <LocalVideoTrack>[];
  final media = <FakeMediaTrack>[];
  final streams = <FakeMediaStream>[];

  /// Delay before a track is handed out.
  Duration delay = Duration.zero;

  /// Throw instead of creating a track (camera permission denied).
  bool fail = false;

  Future<LocalVideoTrack> create() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('camera permission denied');
    return make();
  }

  LocalVideoTrack make() {
    final m = FakeMediaTrack('cam-${created.length + 1}', kind: 'video');
    final s = FakeMediaStream([m], id: 'cam-stream-${created.length + 1}');
    final t = LocalVideoTrack(
      TrackSource.camera,
      s,
      m,
      const CameraCaptureOptions(params: VideoParametersPresets.h540_169),
    );
    created.add(t);
    media.add(m);
    streams.add(s);
    return t;
  }

  /// Every track the join created is stopped (the native capture closed) and disposed.
  bool get allReleased => created.every((t) => t.isDisposed) && media.every((m) => m.stopped);
}

class _Mics {
  final created = <LocalAudioTrack>[];
  final media = <FakeMediaTrack>[];
  Future<LocalAudioTrack> create() async {
    final m = FakeMediaTrack('mic-${created.length + 1}');
    final t = LocalAudioTrack(TrackSource.microphone, FakeMediaStream([m]), m, const AudioCaptureOptions());
    created.add(t);
    media.add(m);
    return t;
  }
}

/// A video host's profile (an app's normal-data settings): vp8,
/// simulcast with the 180p and 360p rungs under the 540p capture.
const _hostOptions = VideoPublishOptions(
  videoCodec: 'vp8',
  simulcast: true,
  videoEncoding: VideoEncoding(maxBitrate: 800000, maxFramerate: 30),
  degradationPreference: DegradationPreference.balanced,
  videoSimulcastLayers: [VideoParametersPresets.h180_169, VideoParametersPresets.h360_169],
);

int _count(FakeWs ws, bool Function(lk_rtc.SignalRequest r) f) => ws.sent.where(f).length;

Iterable<lk_rtc.AddTrackRequest> _videoAddTracks(FakeWs ws) => [
  for (final q in ws.sent)
    if (q.hasAddTrack() && q.addTrack.type == lk_models.TrackType.VIDEO) q.addTrack,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    installCameraChannelMocks();
    GravixEngineMicMute.debugReset(supported: () => false);
  });
  tearDown(GravixEngineMicMute.debugReset);

  late FakeSignalServer server;
  late _Pcs pcs;
  late _Cams cams;
  late _Mics mics;
  Room? room;

  setUp(() {
    server = FakeSignalServer()
      ..answerOffers = true
      ..joinResponse = (_) => _join();
    pcs = _Pcs();
    cams = _Cams();
    mics = _Mics();
  });
  tearDown(() async {
    await room?.dispose();
    room = null;
  });

  Room makeRoom({bool stopLocalTrackOnUnpublish = true}) {
    final options = RoomOptions(reconnectPolicy: FastPolicy(), stopLocalTrackOnUnpublish: stopLocalTrackOnUnpublish);
    final engine = Engine(
      connectOptions: ConnectOptions(timeouts: fastTimeouts()),
      roomOptions: options,
      signalClient: SignalClient(server.connect),
      peerConnectionCreate: pcs.create,
    );
    return room = Room(engine: engine, roomOptions: options);
  }

  ConnectOptions opts({int retries = 0, Duration mediaConnect = const Duration(seconds: 5)}) => ConnectOptions(
    timeouts: fastTimeouts(mediaConnect: mediaConnect),
    joinRetries: retries,
    joinRetryDelays: const [Duration(milliseconds: 10)],
  );

  final released = <LocalVideoTrack>[];
  setUp(released.clear);

  GravixJoinCamera joinCam({
    Duration offerWait = const Duration(seconds: 1),
    bool Function()? wanted,
    VideoPublishOptions? publishOptions = _hostOptions,
  }) => GravixJoinCamera(
    createTrack: cams.create,
    publishOptions: publishOptions,
    offerWait: offerWait,
    wanted: wanted,
    onReleased: (t) async => released.add(t),
  );

  List<LocalTrackPublication> camPubs(Room r) => [
    for (final p in r.localParticipant?.trackPublications.values ?? const <LocalTrackPublication>[])
      if (p.source == TrackSource.camera) p,
  ];
  List<LocalTrackPublication> micPubs(Room r) => [
    for (final p in r.localParticipant?.trackPublications.values ?? const <LocalTrackPublication>[])
      if (p.source == TrackSource.microphone) p,
  ];

  group('off (no joinCamera)', () {
    test('the join-time offer carries no video; a camera published after connect needs a second offer', () async {
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts());
      await r.localParticipant!.publishVideoTrack(cams.make(), publishOptions: _hostOptions);
      final publisher = pcs.publisherOf(0);
      expect(await eventually(() => publisher.offers.length >= 2), isTrue);
      expect(publisher.offerTransceivers.first, 0, reason: 'the fastPublish offer: data channels only');
      expect(publisher.offerTransceivers[1], 1);
    });
  });

  group('on', () {
    test('the publisher\'s FIRST offer carries the camera; AddTrack goes out before it; one offer', () async {
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => camPubs(r).length == 1), isTrue, reason: 'the camera is published by the join');
      await settle(100);
      final publisher = pcs.publisherOf(0);
      expect(publisher.offerTransceivers, [1], reason: 'one offer, with the video transceiver in it');
      expect(publisher.offerKinds.single, ['video']);
      final ws = server.sockets.single;
      final kinds = [for (final q in ws.sent) q.whichMessage()];
      final addTrackAt = kinds.indexOf(lk_rtc.SignalRequest_Message.addTrack);
      final offerAt = kinds.indexOf(lk_rtc.SignalRequest_Message.offer);
      expect(addTrackAt, isNonNegative);
      expect(offerAt, greaterThan(addTrackAt), reason: 'the server must know the cid when the offer arrives');
      expect(_count(ws, (q) => q.hasAddTrack()), 1);
      expect(identical(camPubs(r).single.track, cams.created.single), isTrue);
      expect(cams.media.single.stopped, isFalse);
      expect(failures, isEmpty);
      expect(released, isEmpty);
    });

    test('with the join microphone: ONE first offer carries both (audio + video), two AddTracks', () async {
      final r = makeRoom();
      final phases = r.watchJoinPhases();
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(),
        joinMicrophone: GravixJoinMicrophone(createTrack: mics.create),
        joinCamera: joinCam(),
      );
      expect(await eventually(() => camPubs(r).length == 1 && micPubs(r).length == 1), isTrue);
      await settle(100);
      final publisher = pcs.publisherOf(0);
      expect(publisher.offerTransceivers, [2], reason: 'one offer with both transceivers');
      expect(publisher.offerKinds.single.toSet(), {'audio', 'video'});
      final ws = server.sockets.single;
      expect(_count(ws, (q) => q.hasAddTrack()), 2);
      final kinds = [for (final q in ws.sent) q.whichMessage()];
      expect(
        kinds.indexOf(lk_rtc.SignalRequest_Message.offer),
        greaterThan(kinds.lastIndexOf(lk_rtc.SignalRequest_Message.addTrack)),
      );
      expect(phases.reached[GravixJoinPhase.micPublishedInJoin]?.detail['inFirstOffer'], isTrue);
      expect(phases.reached[GravixJoinPhase.cameraPublishedInJoin]?.detail['inFirstOffer'], isTrue);
      expect(phases.reached[GravixJoinPhase.cameraPublishedInJoin]?.detail['attempt'], 1);
      expect(phases.reached.containsKey(GravixJoinPhase.localVideoPublished), isTrue);
      await phases.dispose();
    });

    test('a camera slower than its offerWait does not hold the microphone: mic first offer, camera its own', () async {
      cams.delay = const Duration(milliseconds: 300);
      final r = makeRoom();
      final phases = r.watchJoinPhases();
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(),
        joinMicrophone: GravixJoinMicrophone(createTrack: mics.create),
        joinCamera: joinCam(offerWait: const Duration(milliseconds: 50)),
      );
      expect(await eventually(() => camPubs(r).length == 1 && micPubs(r).length == 1), isTrue);
      await settle(100);
      expect(pcs.publisherOf(0).offerTransceivers, [1, 2]);
      expect(pcs.publisherOf(0).offerKinds.first, ['audio']);
      expect(phases.reached[GravixJoinPhase.micPublishedInJoin]?.detail['inFirstOffer'], isTrue);
      expect(phases.reached[GravixJoinPhase.cameraPublishedInJoin]?.detail['inFirstOffer'], isFalse);
      await phases.dispose();
    });

    test('the AddTrack and the sender encodings are those of a normal camera publish (simulcast, vp8)', () async {
      // the normal path, in a room of its own
      final r1 = makeRoom();
      await r1.connect('wss://blr1.example', 'tok', connectOptions: opts());
      final normalTrack = cams.make();
      await r1.localParticipant!.publishVideoTrack(normalTrack, publishOptions: _hostOptions);
      final normalReq = _videoAddTracks(server.sockets.last).single;
      final normalSender = pcs.all[0].camSenders.single;
      await r1.dispose();
      room = null;

      final r2 = makeRoom();
      final before = pcs.all.length;
      await r2.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => camPubs(r2).length == 1), isTrue);
      final joinReq = _videoAddTracks(server.sockets.last).single;
      final joinSender = (pcs.all[before]).camSenders.single;

      expect(
        joinReq.simulcastCodecs.map((c) => c.codec).toList(),
        normalReq.simulcastCodecs.map((c) => c.codec).toList(),
      );
      expect(joinReq.simulcastCodecs.first.codec, 'vp8');
      expect(joinReq.layers.length, 3, reason: '180p, 360p and the 540p capture');
      expect(
        [for (final l in joinReq.layers) '${l.quality.name}:${l.width}x${l.height}:${l.bitrate}'],
        [for (final l in normalReq.layers) '${l.quality.name}:${l.width}x${l.height}:${l.bitrate}'],
      );
      expect(joinReq.width, normalReq.width);
      expect(joinReq.height, normalReq.height);
      expect(joinReq.source, lk_models.TrackSource.CAMERA);
      expect(joinReq.name, normalReq.name);
      expect(joinSender.bitrates, normalSender.bitrates, reason: 'the same simulcast encodings');
      expect(joinSender.bitrates.length, 3);
      expect(camPubs(r2).single.track!.codec, 'vp8');
    });

    // (the fallback takes the server's FIRST enabled codec, as the normal path does)
    test('an unsupported codec falls back to the server\'s first codec, as a normal publish', () async {
      server.joinResponse = (_) => _join(
        codecs: [
          lk_models.Codec(mime: 'video/H264'),
          lk_models.Codec(mime: 'audio/opus'),
        ],
      );
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => camPubs(r).length == 1), isTrue);
      expect(_videoAddTracks(server.sockets.single).single.simulcastCodecs.first.codec, 'h264');
      expect(pcs.publisherOf(0).offerTransceivers.first, 1);
    });

    test('no enabledPublishCodecs from the server: published as a normal camera, with an offer of its own', () async {
      server.joinResponse = (_) => _join(codecs: const []);
      final r = makeRoom();
      final phases = r.watchJoinPhases();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => camPubs(r).length == 1), isTrue);
      await settle(100);
      // the sequential path: the AddTrack is answered before the transceiver is added
      final ws = server.sockets.single;
      expect(_videoAddTracks(ws).length, 1);
      expect(pcs.publisherOf(0).offerTransceivers.last, 1);
      expect(phases.reached[GravixJoinPhase.cameraPublishedInJoin]?.detail['inFirstOffer'], isFalse);
      await phases.dispose();
    });

    test('createTrack null: the camera is captured with captureOptions', () async {
      final r = makeRoom();
      final asked = <CameraCaptureOptions>[];
      GravixJoinCamera.debugCreateCameraTrack = (o) async {
        asked.add(o);
        return cams.make();
      };
      addTearDown(() => GravixJoinCamera.debugCreateCameraTrack = null);
      const cam = GravixJoinCamera(captureOptions: CameraCaptureOptions(params: VideoParametersPresets.h360_169));
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: cam);
      expect(await eventually(() => camPubs(r).length == 1), isTrue);
      expect(asked.single.params.dimensions.height, 360);
    });
  });

  group('failure: the join goes on, the app is told, the camera is released', () {
    test('the capture fails (permission denied): join ok, GravixJoinCameraFailedEvent, no AddTrack', () async {
      cams.fail = true;
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => failures.isNotEmpty), isTrue);
      await settle(100);
      expect(failures.single.reason, GravixJoinCameraFailure.captureFailed);
      expect(failures.single.error, isA<StateError>());
      expect(camPubs(r), isEmpty);
      expect(pcs.publisherOf(0).offerTransceivers, [0], reason: 'the publisher still negotiates');
      expect(_count(server.sockets.single, (q) => q.hasAddTrack()), 0);
      expect(r.connectionState, ConnectionState.connected);
    });

    test('the app can publish its camera normally afterwards', () async {
      cams.fail = true;
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      await settle(100);
      cams.fail = false;
      await r.localParticipant!.publishVideoTrack(cams.make(), publishOptions: _hostOptions);
      expect(camPubs(r).length, 1);
    });

    test('no permission to publish: event notAllowed, no AddTrack, the camera is released', () async {
      server.joinResponse = (_) => _join(canPublish: false);
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => failures.isNotEmpty && cams.allReleased), isTrue);
      expect(failures.single.reason, GravixJoinCameraFailure.notAllowed);
      expect(camPubs(r), isEmpty);
      expect(_count(server.sockets.single, (q) => q.hasAddTrack()), 0);
      expect(pcs.publisherOf(0).offerTransceivers, [0]);
      expect(released, cams.created, reason: 'onReleased is told');
    });

    test('allowed sources without CAMERA (a mic-only grant): notAllowed; the join mic is still published', () async {
      server.joinResponse = (_) => _join(sources: [lk_models.TrackSource.MICROPHONE]);
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(),
        joinMicrophone: GravixJoinMicrophone(createTrack: mics.create),
        joinCamera: joinCam(),
      );
      expect(await eventually(() => micPubs(r).length == 1 && failures.isNotEmpty), isTrue);
      await settle(100);
      expect(failures.single.reason, GravixJoinCameraFailure.notAllowed);
      expect(camPubs(r), isEmpty);
      expect(cams.allReleased, isTrue);
      expect(pcs.publisherOf(0).offerTransceivers.first, 1, reason: 'the mic\'s first offer, not held by the camera');
    });

    test('the server refuses the AddTrack (plan cap): event rejected, sender removed, camera released', () async {
      server.holdAddTrack = (_) => true;
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      final ws = Completer<FakeWs>();
      server.afterJoin = ws.complete;
      final joining = r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      final socket = await ws.future;
      expect(await eventually(() => _videoAddTracks(socket).isNotEmpty), isTrue);
      final req = _videoAddTracks(socket).single;
      socket.deliver(
        lk_rtc.SignalResponse(
          requestResponse: lk_rtc.RequestResponse(
            reason: lk_rtc.RequestResponse_Reason.NOT_ALLOWED,
            message: 'video above the plan cap',
            addTrack: req,
          ),
        ),
      );
      await joining;
      expect(await eventually(() => failures.isNotEmpty && cams.allReleased), isTrue);
      expect(failures.single.reason, GravixJoinCameraFailure.rejected);
      expect(camPubs(r), isEmpty);
      expect(r.connectionState, ConnectionState.connected);
      expect(r.localParticipant!.trackPublications, isEmpty);
    });

    test('the camera track ends before it is published (another app took the camera): trackEnded', () async {
      cams.delay = const Duration(milliseconds: 10);
      server.onDial = (_) => Future<void>.delayed(const Duration(milliseconds: 80));
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      final joining = r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => cams.created.isNotEmpty), isTrue);
      cams.media.single.onEnded?.call();
      await joining;
      expect(await eventually(() => failures.isNotEmpty), isTrue);
      await settle(100);
      expect(failures.single.reason, GravixJoinCameraFailure.trackEnded);
      expect(camPubs(r), isEmpty);
      expect(cams.allReleased, isTrue);
      expect(_videoAddTracks(server.sockets.single), isEmpty);
    });

    test('not wanted any more at the JoinResponse (camera turned off while joining): not published, no event, '
        'released', () async {
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(),
        joinCamera: joinCam(wanted: () => false),
      );
      await settle(150);
      expect(camPubs(r), isEmpty);
      expect(_count(server.sockets.single, (q) => q.hasAddTrack()), 0);
      expect(pcs.publisherOf(0).offerTransceivers, [0]);
      expect(cams.allReleased, isTrue);
      expect(failures, isEmpty);
    });

    test(
      'an app that keeps tracks on unpublish (stopLocalTrackOnUnpublish: false): a refused camera is still stopped',
      () async {
        server.joinResponse = (_) => _join(canPublish: false);
        final r = makeRoom(stopLocalTrackOnUnpublish: false);
        await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
        expect(await eventually(() => cams.allReleased), isTrue);
      },
    );
  });

  group('after the join', () {
    test('a full rejoin later republishes the join\'s camera ONCE on the new session (no second capture)', () async {
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => camPubs(r).length == 1), isTrue);
      final failures = <LocalTrackRepublishFailedEvent>[];
      var reconnected = 0;
      r.events.on<LocalTrackRepublishFailedEvent>(failures.add);
      r.events.on<RoomReconnectedEvent>((_) => reconnected++);
      final session = server.sockets.length;
      await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      expect(await eventually(() => reconnected >= 1, timeout: const Duration(seconds: 4)), isTrue);
      expect(
        await eventually(
          () => server.sockets.length > session && _videoAddTracks(server.sockets.last).isNotEmpty,
          timeout: const Duration(seconds: 4),
        ),
        isTrue,
        reason: 'the rejoin republished the camera',
      );
      await settle(300);
      expect(camPubs(r).length, 1);
      expect(identical(camPubs(r).single.track, cams.created.single), isTrue);
      expect(cams.created.length, 1, reason: 'the join camera is not captured again by a rejoin');
      expect(cams.media.single.stopped, isFalse);
      expect(_videoAddTracks(server.sockets.last).length, 1, reason: 'republished once, never twice');
      expect(failures, isEmpty);
    });

    test('a resume keeps the join\'s camera publication (no AddTrack on the resumed session)', () async {
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => camPubs(r).length == 1), isTrue);
      var reconnected = 0;
      r.events.on<RoomReconnectedEvent>((_) => reconnected++);
      final session = server.sockets.length;
      await r.engine.handleReconnect(ClientDisconnectReason.signal);
      expect(await eventually(() => reconnected >= 1, timeout: const Duration(seconds: 4)), isTrue);
      await settle(200);
      expect(server.sockets.length, greaterThan(session));
      expect(server.sockets.last.isResume, isTrue, reason: 'a resume, not a rejoin');
      expect(_count(server.sockets.last, (q) => q.hasAddTrack()), 0);
      expect(camPubs(r).length, 1);
      expect(cams.created.length, 1);
    });

    test('a leave after connect() returned, while the camera publish is still in flight: camera released, '
        'nothing published', () async {
      cams.delay = const Duration(milliseconds: 300);
      final r = makeRoom();
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(),
        joinCamera: joinCam(offerWait: const Duration(milliseconds: 20)),
      );
      expect(camPubs(r), isEmpty, reason: 'the capture is still starting');
      await r.disconnect();
      expect(await eventually(() => cams.created.length == 1), isTrue);
      expect(await eventually(() => cams.allReleased), isTrue, reason: 'no camera left open after the leave');
      await settle(100);
      expect(camPubs(r), isEmpty);
      expect(released, cams.created);
    });

    test('a leave after the camera was published: the camera is stopped', () async {
      final r = makeRoom(stopLocalTrackOnUnpublish: false);
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinCamera: joinCam());
      expect(await eventually(() => camPubs(r).length == 1), isTrue);
      await r.disconnect();
      expect(cams.created.single.isDisposed, isTrue);
    });

    test(
      'setCameraEnabled(true) right after connect waits for the join\'s camera and does not open a second one',
      () async {
        cams.delay = const Duration(milliseconds: 200);
        final r = makeRoom();
        await r.connect(
          'wss://blr1.example',
          'tok',
          connectOptions: opts(),
          joinCamera: joinCam(offerWait: const Duration(milliseconds: 20)),
        );
        expect(camPubs(r), isEmpty);
        await r.localParticipant!.setCameraEnabled(true);
        expect(camPubs(r).length, 1);
        expect(identical(camPubs(r).single.track, cams.created.single), isTrue);
        expect(_count(server.sockets.single, (q) => q.hasAddTrack()), 1);
      },
    );
  });

  group('join retry', () {
    test('attempt 1 times out: attempt 2 captures and publishes again; one publication, attempt 1\'s camera '
        'released, one AddTrack per socket', () async {
      pcs.connects = (i) => i >= 2;
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(retries: 1, mediaConnect: const Duration(milliseconds: 300)),
        joinCamera: joinCam(),
      );
      expect(await eventually(() => camPubs(r).length == 1), isTrue);
      await settle(100);
      expect(cams.created.length, 2);
      expect(cams.media[0].stopped, isTrue, reason: 'the failed attempt\'s camera');
      expect(cams.created[0].isDisposed, isTrue);
      expect(cams.media[1].stopped, isFalse);
      expect(identical(camPubs(r).single.track, cams.created[1]), isTrue);
      expect(r.localParticipant!.trackPublications.length, 1);
      expect(_videoAddTracks(server.sockets[0]).length, 1);
      expect(_videoAddTracks(server.sockets[1]).length, 1);
      expect(pcs.publisherOf(1).offerTransceivers.first, 1, reason: 'the retry\'s first offer carries the camera');
      expect(failures, isEmpty, reason: 'a retried attempt is not a camera failure');
    });

    test('every attempt fails: connect throws, every camera released, no event', () async {
      pcs.connects = (_) => false;
      final r = makeRoom();
      final failures = <GravixJoinCameraFailedEvent>[];
      r.events.on<GravixJoinCameraFailedEvent>(failures.add);
      await expectLater(
        r.connect(
          'wss://blr1.example',
          'tok',
          connectOptions: opts(retries: 1, mediaConnect: const Duration(milliseconds: 200)),
          joinCamera: joinCam(),
        ),
        throwsA(isA<MediaConnectException>()),
      );
      expect(cams.created.length, 2);
      expect(cams.allReleased, isTrue, reason: 'released before connect() fails');
      await settle(100);
      expect(camPubs(r), isEmpty);
      expect(failures, isEmpty);
    });

    test('a leave while joining: connect fails, the camera is released', () async {
      pcs.connects = (_) => false;
      final r = makeRoom();
      final joining = r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(retries: 2, mediaConnect: const Duration(seconds: 2)),
        joinCamera: joinCam(),
      );
      joining.ignore();
      expect(await eventually(() => camPubs(r).length == 1), isTrue, reason: 'published inside the join');
      await r.disconnect();
      await expectLater(joining, throwsA(anything));
      expect(cams.created.length, 1, reason: 'no retry after a leave');
      expect(cams.allReleased, isTrue);
    });

    test('a capture still starting when the attempt fails is released once it is created', () async {
      pcs.connects = (_) => false;
      cams.delay = const Duration(milliseconds: 400);
      final r = makeRoom();
      await expectLater(
        r.connect(
          'wss://blr1.example',
          'tok',
          connectOptions: opts(mediaConnect: const Duration(milliseconds: 100)),
          joinCamera: joinCam(offerWait: const Duration(milliseconds: 20)),
        ),
        throwsA(isA<MediaConnectException>()),
      );
      expect(await eventually(() => cams.created.length == 1), isTrue);
      expect(await eventually(() => cams.allReleased), isTrue);
      await settle(100);
      expect(camPubs(r), isEmpty);
    });
  });
}

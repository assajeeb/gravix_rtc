// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-12, fast publish (a real Android phone, settled app, 6.4 ms to its SFU): a
// host's mic went live 1814 ms after the tap although the room was connected at
// 888 ms. The publisher connection was negotiated at the JoinResponse with its
// data channels only; the microphone was published after connect() returned:
// AudioRecord start, AddTrack, a SECOND offer/answer, 0.93 s in all.
//
// Room.connect(joinMicrophone: ...) puts the microphone into the publisher's
// FIRST offer: its capture starts with the attempt, and at the JoinResponse the
// AddTrack goes out and the transceiver is added before that offer is made.
// Join retries keep working (0.4.15 turned them off for a publish inside the
// join); a failed attempt or a failed join leaves no capture running.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/connect/gravix_join_phases.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
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
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

/// Records how many transceivers the connection had at each createOffer.
class _OfferLogPc extends FakePeerConnection {
  _OfferLogPc(super.index);
  final offerTransceivers = <int>[];

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) {
    offerTransceivers.add(added.length);
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

lk_rtc.JoinResponse _join({bool subscriberPrimary = true, bool fastPublish = true, bool canPublish = true}) =>
    lk_rtc.JoinResponse(
      room: lk_models.Room(name: 'r', sid: 'RM_r'),
      participant: lk_models.ParticipantInfo(
        sid: 'PA_me',
        identity: 'me',
        permission: lk_models.ParticipantPermission(canPublish: canPublish, canSubscribe: true),
      ),
      subscriberPrimary: subscriberPrimary,
      fastPublish: fastPublish,
      serverVersion: '1.9.0',
    );

/// Mic tracks the join creates, in order.
class _Mics {
  final created = <LocalAudioTrack>[];
  final media = <FakeMediaTrack>[];
  final streams = <FakeMediaStream>[];

  /// Delay before a track is handed out.
  Duration delay = Duration.zero;

  /// Throw instead of creating a track.
  bool fail = false;

  Future<LocalAudioTrack> create() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('no microphone');
    final m = FakeMediaTrack('mic-${created.length + 1}');
    final s = FakeMediaStream([m]);
    final t = LocalAudioTrack(TrackSource.microphone, s, m, const AudioCaptureOptions());
    created.add(t);
    media.add(m);
    streams.add(s);
    return t;
  }
}

int _count(FakeWs ws, bool Function(lk_rtc.SignalRequest r) f) => ws.sent.where(f).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    GravixEngineMicMute.debugReset(supported: () => false);
  });
  tearDown(GravixEngineMicMute.debugReset);

  late FakeSignalServer server;
  late _Pcs pcs;
  late _Mics mics;
  Room? room;

  setUp(() {
    server = FakeSignalServer()
      ..answerOffers = true
      ..joinResponse = (_) => _join();
    pcs = _Pcs();
    mics = _Mics();
  });
  tearDown(() async {
    await room?.dispose();
    room = null;
  });

  Room makeRoom() {
    final options = RoomOptions(reconnectPolicy: FastPolicy());
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

  GravixJoinMicrophone joinMic({Duration offerWait = const Duration(seconds: 1), bool Function()? wanted}) =>
      GravixJoinMicrophone(createTrack: mics.create, offerWait: offerWait, wanted: wanted);

  List<LocalTrackPublication> micPubs(Room r) => [
    for (final p in r.localParticipant?.trackPublications.values ?? const <LocalTrackPublication>[])
      if (p.source == TrackSource.microphone) p,
  ];

  group('off (no joinMicrophone)', () {
    test('the join-time offer carries no audio; a mic published after connect needs a second offer', () async {
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts());
      final track = await mics.create();
      await r.localParticipant!.publishAudioTrack(track);
      final publisher = pcs.publisherOf(0);
      expect(await eventually(() => publisher.offers.length >= 2), isTrue);
      expect(publisher.offerTransceivers.first, 0, reason: 'the fastPublish offer: data channels only');
      expect(publisher.offerTransceivers[1], 1);
    });
  });

  group('on', () {
    test('the publisher\'s FIRST offer carries the microphone; AddTrack goes out before it; one offer', () async {
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinMicrophone: joinMic());
      expect(await eventually(() => micPubs(r).length == 1), isTrue, reason: 'the mic is published by the join');
      await settle(100);
      final publisher = pcs.publisherOf(0);
      expect(publisher.offerTransceivers, [1], reason: 'one offer, with the audio transceiver in it');
      final ws = server.sockets.single;
      final kinds = [for (final q in ws.sent) q.whichMessage()];
      final addTrackAt = kinds.indexOf(lk_rtc.SignalRequest_Message.addTrack);
      final offerAt = kinds.indexOf(lk_rtc.SignalRequest_Message.offer);
      expect(addTrackAt, isNonNegative);
      expect(offerAt, greaterThan(addTrackAt), reason: 'the server must know the cid when the offer arrives');
      expect(_count(ws, (q) => q.hasAddTrack()), 1);
      expect(identical(micPubs(r).single.track, mics.created.single), isTrue);
      expect(mics.media.single.stopped, isFalse);
      expect(mics.created.single.isActive, isTrue, reason: 'the capture was started by the join');
    });

    test('publisher primary (no fastPublish): the join-time offer waits for the microphone', () async {
      server.joinResponse = (_) => _join(subscriberPrimary: false, fastPublish: false);
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinMicrophone: joinMic());
      expect(await eventually(() => micPubs(r).length == 1), isTrue);
      await settle(100);
      expect(pcs.publisherOf(0).offerTransceivers, [1]);
    });

    test('subscriber primary without fastPublish: the microphone\'s offer is the publisher\'s first', () async {
      server.joinResponse = (_) => _join(fastPublish: false);
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinMicrophone: joinMic());
      expect(await eventually(() => micPubs(r).length == 1), isTrue);
      await settle(100);
      expect(pcs.publisherOf(0).offerTransceivers, [1]);
    });

    test('the join phases report micPublishedInJoin (in the first offer, attempt 1)', () async {
      final r = makeRoom();
      final phases = r.watchJoinPhases();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinMicrophone: joinMic());
      expect(await eventually(() => phases.reached.containsKey(GravixJoinPhase.micPublishedInJoin)), isTrue);
      final e = phases.reached[GravixJoinPhase.micPublishedInJoin]!;
      expect(e.detail['inFirstOffer'], isTrue);
      expect(e.detail['attempt'], 1);
      expect(phases.reached.containsKey(GravixJoinPhase.localAudioPublished), isTrue);
      await phases.dispose();
    });

    test('a capture slower than offerWait: the offer goes out without it, the mic follows with its own', () async {
      mics.delay = const Duration(milliseconds: 300);
      final r = makeRoom();
      final phases = r.watchJoinPhases();
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(),
        joinMicrophone: joinMic(offerWait: const Duration(milliseconds: 50)),
      );
      expect(await eventually(() => micPubs(r).length == 1), isTrue);
      await settle(100);
      expect(pcs.publisherOf(0).offerTransceivers, [0, 1]);
      expect(phases.reached[GravixJoinPhase.micPublishedInJoin]?.detail['inFirstOffer'], isFalse);
      await phases.dispose();
    });

    test('a capture that fails: the join succeeds without a microphone, the publisher still negotiates', () async {
      mics.fail = true;
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinMicrophone: joinMic());
      await settle(150);
      expect(micPubs(r), isEmpty);
      expect(pcs.publisherOf(0).offerTransceivers, [0]);
      expect(_count(server.sockets.single, (q) => q.hasAddTrack()), 0);
    });

    test(
      'not wanted any more at the JoinResponse (a mute tapped while joining): not published, capture stopped',
      () async {
        final r = makeRoom();
        await r.connect(
          'wss://blr1.example',
          'tok',
          connectOptions: opts(),
          joinMicrophone: joinMic(wanted: () => false),
        );
        await settle(150);
        expect(micPubs(r), isEmpty);
        expect(_count(server.sockets.single, (q) => q.hasAddTrack()), 0);
        expect(pcs.publisherOf(0).offerTransceivers, [0]);
        expect(mics.media.single.stopped, isTrue, reason: 'no capture without a publication');
        expect(mics.created.single.isDisposed, isTrue);
      },
    );

    test('a mute tapped while the publish was in flight: published, then muted', () async {
      var asked = 0;
      final r = makeRoom();
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(),
        joinMicrophone: joinMic(wanted: () => ++asked < 2),
      );
      expect(await eventually(() => micPubs(r).length == 1 && micPubs(r).single.muted), isTrue);
    });

    test('no permission to publish: no AddTrack, the capture is stopped, the publisher still negotiates', () async {
      server.joinResponse = (_) => _join(canPublish: false);
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinMicrophone: joinMic());
      await settle(150);
      expect(micPubs(r), isEmpty);
      expect(_count(server.sockets.single, (q) => q.hasAddTrack()), 0);
      expect(pcs.publisherOf(0).offerTransceivers, [0]);
      expect(mics.media.single.stopped, isTrue);
    });

    test('setMicrophoneEnabled(true) right after connect (the service\'s mic step) waits for the join\'s publish '
        'and does not publish a second microphone', () async {
      mics.delay = const Duration(milliseconds: 200);
      final r = makeRoom();
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(),
        joinMicrophone: joinMic(offerWait: const Duration(milliseconds: 20)),
      );
      expect(micPubs(r), isEmpty, reason: 'the capture is still starting');
      await r.localParticipant!.setMicrophoneEnabled(true);
      expect(micPubs(r).length, 1);
      expect(identical(micPubs(r).single.track, mics.created.single), isTrue);
      expect(_count(server.sockets.single, (q) => q.hasAddTrack()), 1);
    });
  });

  group('after the join', () {
    test(
      'a full rejoin later republishes the join\'s microphone once on the new session (no second capture)',
      () async {
        final r = makeRoom();
        await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinMicrophone: joinMic());
        expect(await eventually(() => micPubs(r).length == 1), isTrue);
        final failures = <LocalTrackRepublishFailedEvent>[];
        var reconnected = 0;
        r.events.on<LocalTrackRepublishFailedEvent>(failures.add);
        r.events.on<RoomReconnectedEvent>((_) => reconnected++);
        final session = server.sockets.length;
        await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
        expect(await eventually(() => reconnected >= 1, timeout: const Duration(seconds: 4)), isTrue);
        expect(
          await eventually(
            () => server.sockets.length > session && server.sockets.last.sent.any((q) => q.hasAddTrack()),
            timeout: const Duration(seconds: 4),
          ),
          isTrue,
          reason: 'the rejoin republished the microphone',
        );
        await settle(200);
        expect(micPubs(r).length, 1);
        expect(identical(micPubs(r).single.track, mics.created.single), isTrue);
        expect(mics.created.length, 1, reason: 'the join microphone is not captured again by a rejoin');
        expect(mics.media.single.stopped, isFalse);
        expect(_count(server.sockets.last, (q) => q.hasAddTrack()), 1);
        expect(failures, isEmpty);
      },
    );

    test('a resume keeps the join\'s microphone publication (no AddTrack on the resumed session)', () async {
      final r = makeRoom();
      await r.connect('wss://blr1.example', 'tok', connectOptions: opts(), joinMicrophone: joinMic());
      expect(await eventually(() => micPubs(r).length == 1), isTrue);
      var reconnected = 0;
      r.events.on<RoomReconnectedEvent>((_) => reconnected++);
      final session = server.sockets.length;
      await r.engine.handleReconnect(ClientDisconnectReason.signal);
      expect(await eventually(() => reconnected >= 1, timeout: const Duration(seconds: 4)), isTrue);
      await settle(200);
      expect(server.sockets.length, greaterThan(session));
      expect(server.sockets.last.isResume, isTrue, reason: 'a resume, not a rejoin');
      expect(_count(server.sockets.last, (q) => q.hasAddTrack()), 0);
      expect(micPubs(r).length, 1);
      expect(mics.created.length, 1);
    });
  });

  group('join retry', () {
    test('attempt 1 times out its peer connection: attempt 2 captures and publishes again; one publication, '
        'attempt 1\'s capture stopped, one AddTrack per socket', () async {
      pcs.connects = (i) => i >= 2; // only the second attempt's connections connect
      final r = makeRoom();
      final retries = <RoomJoinRetryEvent>[];
      r.events.on<RoomJoinRetryEvent>(retries.add);
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(retries: 1, mediaConnect: const Duration(milliseconds: 300)),
        joinMicrophone: joinMic(),
      );
      expect(retries.length, 1, reason: 'the join was retried (0.4.15 turned retries off for a join publish)');
      expect(await eventually(() => micPubs(r).length == 1), isTrue);
      await settle(100);
      expect(mics.created.length, 2);
      expect(mics.media[0].stopped, isTrue, reason: 'the failed attempt\'s capture');
      expect(mics.created[0].isDisposed, isTrue);
      expect(mics.media[1].stopped, isFalse);
      expect(identical(micPubs(r).single.track, mics.created[1]), isTrue);
      expect(r.localParticipant!.trackPublications.length, 1);
      expect(server.sockets.length, 2);
      expect(_count(server.sockets[0], (q) => q.hasAddTrack()), 1);
      expect(_count(server.sockets[1], (q) => q.hasAddTrack()), 1);
      expect(pcs.publisherOf(1).offerTransceivers.first, 1, reason: 'the retry\'s first offer carries the mic');
    });

    test('every attempt fails: connect throws, no capture is left running, no publication', () async {
      pcs.connects = (_) => false;
      final r = makeRoom();
      final disconnects = <RoomDisconnectedEvent>[];
      r.events.on<RoomDisconnectedEvent>(disconnects.add);
      await expectLater(
        r.connect(
          'wss://blr1.example',
          'tok',
          connectOptions: opts(retries: 1, mediaConnect: const Duration(milliseconds: 200)),
          joinMicrophone: joinMic(),
        ),
        throwsA(isA<MediaConnectException>()),
      );
      // the failure is reported only after the captures were stopped
      expect(mics.created.length, 2);
      for (var i = 0; i < 2; i++) {
        expect(mics.media[i].stopped, isTrue, reason: 'attempt ${i + 1}\'s capture');
        expect(mics.created[i].isDisposed, isTrue);
      }
      await settle(100);
      expect(micPubs(r), isEmpty);
      expect(disconnects.length, 1);
    });

    test('a leave while joining: connect fails, the capture is stopped', () async {
      pcs.connects = (_) => false;
      final r = makeRoom();
      final joining = r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: opts(retries: 2, mediaConnect: const Duration(seconds: 2)),
        joinMicrophone: joinMic(),
      );
      joining.ignore();
      expect(await eventually(() => micPubs(r).length == 1), isTrue, reason: 'published inside the join');
      await r.disconnect();
      await expectLater(joining, throwsA(anything));
      expect(mics.created.length, 1, reason: 'no retry after a leave');
      expect(mics.media.single.stopped, isTrue);
      expect(mics.created.single.isDisposed, isTrue);
    });

    test('a capture still starting when the attempt fails is stopped once it is created', () async {
      pcs.connects = (_) => false;
      mics.delay = const Duration(milliseconds: 400);
      final r = makeRoom();
      await expectLater(
        r.connect(
          'wss://blr1.example',
          'tok',
          connectOptions: opts(mediaConnect: const Duration(milliseconds: 100)),
          joinMicrophone: joinMic(offerWait: const Duration(milliseconds: 20)),
        ),
        throwsA(isA<MediaConnectException>()),
      );
      expect(await eventually(() => mics.created.length == 1), isTrue);
      expect(await eventually(() => mics.media.single.stopped && mics.created.single.isDisposed), isTrue);
      await settle(100);
      expect(micPubs(r), isEmpty);
    });
  });
}

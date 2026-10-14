// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-13: a muted join microphone (GravixJoinMicrophone(muted: true)). An
// audio-room host who joins off-seat had the microphone published at the seat
// tap: capture start, AddTrack, and a second offer/answer. With `muted` the
// microphone is negotiated in the publisher's FIRST offer but WITHOUT a capture:
// the AddTrack says muted, the audio transceiver's sender has no track (no
// packet can be sent), and the native track is released before the publish.
// setMicrophoneEnabled(true) later opens the capture on that sender
// (replaceTrack) and signals the unmute: no AddTrack, no offer at the tap.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_join_mic.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
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
  _OfferLogPc publisherOf(int attempt) => all[2 * attempt];

  Future<rtc.RTCPeerConnection> create(Map<String, dynamic> configuration, [Map<String, dynamic>? constraints]) async {
    final pc = _OfferLogPc(all.length);
    all.add(pc);
    Timer(const Duration(milliseconds: 30), pc.connect);
    return pc;
  }
}

lk_rtc.JoinResponse _join({bool canPublish = true}) => lk_rtc.JoinResponse(
  room: lk_models.Room(name: 'r', sid: 'RM_r'),
  participant: lk_models.ParticipantInfo(
    sid: 'PA_me',
    identity: 'me',
    permission: lk_models.ParticipantPermission(canPublish: canPublish, canSubscribe: true),
  ),
  subscriberPrimary: true,
  fastPublish: canPublish,
  serverVersion: '1.9.0',
);

class _Mics {
  final created = <LocalAudioTrack>[];
  final media = <FakeMediaTrack>[];
  final streams = <FakeMediaStream>[];
  Future<LocalAudioTrack> create() async {
    final m = FakeMediaTrack('mic-${created.length + 1}');
    final s = FakeMediaStream([m]);
    final t = LocalAudioTrack(TrackSource.microphone, s, m, const AudioCaptureOptions());
    created.add(t);
    media.add(m);
    streams.add(s);
    return t;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// getUserMedia calls the unmute made (the capture it opens).
  var userMediaCalls = 0;
  setUp(() {
    installRecoveryChannelMocks();
    GravixEngineMicMute.debugReset(supported: () => false);
    userMediaCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        if (call.method == 'getUserMedia') {
          userMediaCalls++;
          return <String, dynamic>{
            'streamId': 'mic-stream-live-$userMediaCalls',
            'audioTracks': [
              <String, dynamic>{'id': 'mic-live-$userMediaCalls', 'label': 'mic', 'kind': 'audio', 'enabled': true},
            ],
            'videoTracks': <dynamic>[],
          };
        }
        return null;
      },
    );
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

  ConnectOptions opts() => ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0);

  List<LocalTrackPublication> micPubs(Room r) => [
    for (final p in r.localParticipant?.trackPublications.values ?? const <LocalTrackPublication>[])
      if (p.source == TrackSource.microphone) p,
  ];

  Future<Room> joinMuted() async {
    final r = makeRoom();
    await r.connect(
      'wss://blr1.example',
      'tok',
      connectOptions: opts(),
      joinMicrophone: GravixJoinMicrophone(createTrack: mics.create, muted: true),
    );
    expect(await eventually(() => micPubs(r).length == 1), isTrue);
    await settle(100);
    return r;
  }

  test('muted: in the first offer, the AddTrack muted, no track on the sender, the capture never started', () async {
    final r = await joinMuted();
    final publisher = pcs.publisherOf(0);
    expect(publisher.offerTransceivers, [1], reason: 'one offer, with the audio transceiver');
    final t = publisher.added.single;
    expect(t.kind, rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio);
    expect(t.track, isNull, reason: 'nothing to send: no audio can reach the SFU');
    expect(t.sender.track, isNull);
    final add = server.sockets.single.sent.where((q) => q.hasAddTrack()).single.addTrack;
    expect(add.muted, isTrue, reason: 'the server holds the track muted');
    final pub = micPubs(r).single;
    expect(pub.muted, isTrue);
    expect(pub.track!.isActive, isFalse, reason: 'the capture was never started');
    expect(mics.media.single.stopped, isTrue, reason: 'the native track was released before the publish');
    expect(mics.media.single.enabled, isFalse);
    expect(userMediaCalls, 0);
  });

  test('setMicrophoneEnabled(true) later: the capture opens on the same sender; no AddTrack, no offer', () async {
    final r = await joinMuted();
    final publisher = pcs.publisherOf(0);
    final offers = publisher.offerTransceivers.length;
    final ws = server.sockets.single;
    final addTracks = ws.sent.where((q) => q.hasAddTrack()).length;
    final sender = publisher.added.single.sender as FakeSender;

    await r.localParticipant!.setMicrophoneEnabled(true);
    await settle(100);

    expect(userMediaCalls, 1, reason: 'the capture opens at the enable');
    expect(sender.replaced.length, 1);
    expect(sender.track, isNotNull, reason: 'the live capture on the first offer\'s sender');
    expect(publisher.offerTransceivers.length, offers, reason: 'no second offer at the enable');
    expect(ws.sent.where((q) => q.hasAddTrack()).length, addTracks, reason: 'no second AddTrack');
    final unmute = ws.sent.where((q) => q.hasMute()).toList();
    expect(unmute.isNotEmpty && unmute.last.mute.muted == false, isTrue, reason: 'the unmute is signalled');
    final pub = micPubs(r).single;
    expect(pub.muted, isFalse);
    expect(pub.track!.isActive, isTrue);
  });

  test('a listener token without publish permission: nothing is published, the join goes on', () async {
    server.joinResponse = (_) => _join(canPublish: false);
    final r = makeRoom();
    await r.connect(
      'wss://blr1.example',
      'tok',
      connectOptions: opts(),
      joinMicrophone: GravixJoinMicrophone(createTrack: mics.create, muted: true),
    );
    await settle(150);
    expect(micPubs(r), isEmpty);
    expect(server.sockets.single.sent.where((q) => q.hasAddTrack()), isEmpty);
    expect(mics.media.single.stopped, isTrue);
    expect(r.connectionState, ConnectionState.connected);
  });

  test('a full rejoin while still muted republishes it muted without a capture (once)', () async {
    final r = await joinMuted();
    var reconnected = 0;
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
    );
    await settle(200);
    final adds = server.sockets.last.sent.where((q) => q.hasAddTrack()).toList();
    expect(adds.length, 1);
    expect(adds.single.addTrack.muted, isTrue);
    final newPublisher = pcs.all.where((p) => p.added.isNotEmpty).last;
    expect(identical(newPublisher, pcs.publisherOf(0)), isFalse, reason: 'the rejoin\'s connection');
    expect(newPublisher.added.single.track, isNull);
    expect(userMediaCalls, 0, reason: 'still no capture');
  });

  test('off (muted: false): unchanged, the capture is live in the first offer', () async {
    final r = makeRoom();
    await r.connect(
      'wss://blr1.example',
      'tok',
      connectOptions: opts(),
      joinMicrophone: GravixJoinMicrophone(createTrack: mics.create),
    );
    expect(await eventually(() => micPubs(r).length == 1), isTrue);
    expect(pcs.publisherOf(0).added.single.track, isNotNull);
    expect(micPubs(r).single.muted, isFalse);
    expect(server.sockets.single.sent.where((q) => q.hasAddTrack()).single.addTrack.muted, isFalse);
  });
}

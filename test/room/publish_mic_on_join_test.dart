// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixRoomService.connect(publishMicOnJoin: true) (2026-10-12, fast publish):
// the service starts the microphone capture in parallel with the signalling
// and hands it to Room.connect as its GravixJoinMicrophone (the core then puts
// it into the publisher's first offer; see test/connect/join_microphone_test).
// The service side: the capture is handed over exactly once (a retry or another
// url captures afresh), a mute tapped during the join is honoured, a capture the
// room never took is stopped, and the join timeline's micPublished is the
// join's publish.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<LocalAudioTrack> created;
  late List<FakeMediaTrack> media;

  setUp(() {
    created = [];
    media = [];
    GravixAudioRouting.v2 = false;
    installRecoveryChannelMocks();
    GravixEngineMicMute.debugReset(supported: () => false);
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('com.gravitycompile.gravix_rtc/music'), (call) async => null);
  });
  tearDown(GravixEngineMicMute.debugReset);

  Future<LocalAudioTrack> createMic(AudioCaptureOptions options) async {
    final t = FakeMediaTrack('mic-${created.length + 1}');
    final track = LocalAudioTrack(TrackSource.microphone, FakeMediaStream([t]), t, options);
    created.add(track);
    media.add(t);
    return track;
  }

  GravixRoomService service(Future<void> Function(GravixRoomService s, Room room) join) {
    late GravixRoomService s;
    s = GravixRoomService(connectRoom: (room, url, token) => join(s, room), createMicTrack: createMic);
    return s;
  }

  test('off (default): no join microphone, no capture during the join', () async {
    GravixJoinMicrophone? seen;
    final s = service((s, room) async => seen = s.debugAttemptJoinMicrophone);
    expect(await s.connect(url: 'wss://a.example', token: 't', publishMic: true), isTrue);
    expect(seen, isNull);
    await s.disconnect();
  });

  test('publishMicOnJoin without publishMic (a viewer): nothing', () async {
    GravixJoinMicrophone? seen;
    final s = service((s, room) async => seen = s.debugAttemptJoinMicrophone);
    expect(await s.connect(url: 'wss://a.example', token: 't', publishMicOnJoin: true), isTrue);
    expect(seen, isNull);
    expect(created, isEmpty);
    await s.disconnect();
  });

  test('on: the capture started with the join is handed to the room once; a second attempt captures afresh', () async {
    LocalAudioTrack? first;
    LocalAudioTrack? second;
    bool? wanted;
    final s = service((s, room) async {
      final jm = s.debugAttemptJoinMicrophone!;
      first = await jm.createTrack();
      second = await jm.createTrack();
      wanted = jm.wanted?.call();
    });
    expect(await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishMicOnJoin: true), isTrue);
    expect(created.length, 2);
    expect(identical(first, created[0]), isTrue, reason: 'the capture started in parallel with the signalling');
    expect(identical(second, created[1]), isTrue);
    expect(wanted, isTrue);
    expect(s.debugAttemptJoinMicrophone, isNull, reason: 'only while joining');
    expect(media[0].stopped, isFalse, reason: 'the room owns it now');
    expect(created[0].isActive, isTrue, reason: 'started (AudioRecord) before the room took it');
    await s.disconnect();
  });

  test('a mute tapped during the join: the join microphone is not wanted any more', () async {
    bool? wanted;
    final s = service((s, room) async {
      await s.setMicEnabled(false);
      wanted = s.debugAttemptJoinMicrophone!.wanted?.call();
    });
    await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishMicOnJoin: true);
    expect(wanted, isFalse);
    await s.disconnect();
  });

  test('a join that fails before the room took the capture: the capture is stopped', () async {
    final s = service((s, room) async {
      // the capture started while the join was on its way
      for (var i = 0; i < 100 && created.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      throw MediaConnectException('no media');
    });
    expect(await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishMicOnJoin: true), isFalse);
    expect(created.length, 1);
    expect(await eventually(() => media.single.stopped && created.single.isDisposed), isTrue);
    expect(s.debugAttemptJoinMicrophone, isNull);
  });

  test('earlyMicTrack together with publishMicOnJoin: one capture, the join\'s', () async {
    final s = service((s, room) async {
      await s.debugAttemptJoinMicrophone!.createTrack();
    });
    await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishMicOnJoin: true, earlyMicTrack: true);
    await settle(50);
    expect(created.length, 1);
    await s.disconnect();
  });

  test('the join timeline\'s micPublished is the join\'s publish', () async {
    final s = service((s, room) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      room.engine.events.emit(const EngineJoinMicPublishedEvent(inFirstOffer: true, attempt: 1));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await s.connect(
      url: 'wss://a.example',
      token: 't',
      publishMic: true,
      publishMicOnJoin: true,
      joinTimeline: GravixJoinTimelineInput(tapAt: DateTime.now()),
    );
    await s.disconnect();
    final t = s.joinTimeline.value!;
    expect(t.t[GravixJoinStep.micPublished], isNotNull);
    expect(t.t[GravixJoinStep.micPublished]!.isBefore(t.t[GravixJoinStep.connectReturned]!), isTrue);
    expect(t.subscriberPath.any((e) => e['e'] == 'svc:micPublishedInJoin'), isTrue);
  });
}

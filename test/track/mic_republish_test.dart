// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field 2026-10-05: republishing the SAME mic track (room-music DTX swap, RED
// auto) left the host without a microphone: removePublishedTrack disposes the
// track it unpublishes. gravixRepublishMic publishes a NEW track on the same
// capture, carries the mute over, and falls back to the original options.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/participant/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/publication/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/mic_republish.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

class _FakeWs extends GravixRtcWebSocket {
  @override
  void send(List<int> data) => lk_rtc.SignalRequest.fromBuffer(data);
}

class _FakeTrack implements rtc.MediaStreamTrack {
  _FakeTrack(this.id);
  @override
  bool enabled = true;
  bool stopped = false;
  @override
  final String? id;
  @override
  String? get kind => 'audio';
  @override
  Future<void> stop() async => stopped = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isSetter ? null : super.noSuchMethod(invocation);
}

class _FakeStream implements rtc.MediaStream {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> log;

  setUp(() {
    log = [];
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      m.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
    GravixEngineMicMute.debugReset(supported: () => true, setNative: (mute) async => true);
  });
  tearDown(GravixEngineMicMute.debugReset);

  var n = 0;
  Future<LocalAudioTrack> newTrack(AudioCaptureOptions o) async {
    final t = LocalAudioTrack(TrackSource.microphone, _FakeStream(), _FakeTrack('mic-${++n}'), o);
    await t.start();
    log.add('create');
    return t;
  }

  Future<(LocalParticipant, LocalAudioTrack)> publishedMic() async {
    final sc = SignalClient((uri, {options, headers, networkOptions, preconnected}) async => _FakeWs());
    await sc.connect(
      'wss://sfu.example',
      'tok',
      connectOptions: const ConnectOptions(),
      roomOptions: const RoomOptions(),
    );
    final room = Room(
      engine: Engine(connectOptions: const ConnectOptions(), roomOptions: const RoomOptions(), signalClient: sc),
    );
    final lp = await LocalParticipant.createFromInfo(
      room: room,
      info: lk_models.ParticipantInfo(sid: 'PA_me', identity: 'me'),
    );
    final track = await newTrack(const AudioCaptureOptions(stopAudioCaptureOnMute: false));
    log.clear();
    lp.addTrackPublication(
      LocalTrackPublication<LocalAudioTrack>(
        participant: lp,
        info: lk_models.TrackInfo(
          sid: 'TR_mic',
          type: lk_models.TrackType.AUDIO,
          source: lk_models.TrackSource.MICROPHONE,
        ),
        track: track,
      ),
    );
    return (lp, track);
  }

  const red = AudioPublishOptions(red: true, dtx: false);
  const plain = AudioPublishOptions(red: false, dtx: true);

  Future<void> Function(String) unpublishFrom(LocalParticipant lp) => (sid) async {
    log.add('unpublish $sid');
    lp.trackPublications.remove(sid);
  };

  test('publishes a NEW track with the wanted options (the old one is disposed by its unpublish)', () async {
    final (lp, old) = await publishedMic();
    LocalAudioTrack? published;
    final (fresh, ok) = await gravixRepublishMic(
      lp,
      old,
      wanted: red,
      fallback: plain,
      createTrack: newTrack,
      unpublish: unpublishFrom(lp),
      publish: (t, o) async {
        log.add('publish red=${o.red}');
        published = t;
      },
    );
    expect(ok, isTrue);
    expect(fresh, isNotNull);
    expect(identical(fresh, old), isFalse);
    expect(identical(published, fresh), isTrue);
    expect(log, ['create', 'unpublish TR_mic', 'publish red=true']);
  });

  test('a refused publish falls back to the original options: the host keeps a mic', () async {
    final (lp, old) = await publishedMic();
    var calls = 0;
    final (fresh, ok) = await gravixRepublishMic(
      lp,
      old,
      wanted: red,
      fallback: plain,
      createTrack: newTrack,
      unpublish: unpublishFrom(lp),
      retryDelay: Duration.zero,
      publish: (t, o) async {
        log.add('publish red=${o.red}');
        if (calls++ == 0) throw Exception('addTrack rejected');
      },
    );
    expect(fresh, isNotNull);
    expect(ok, isFalse);
    expect(log, ['create', 'unpublish TR_mic', 'publish red=true', 'publish red=false']);
  });

  test('the mute is carried over BEFORE the new track is published', () async {
    final (lp, old) = await publishedMic();
    await old.mute(stopOnMute: false);
    bool? mutedAtPublish;
    await gravixRepublishMic(
      lp,
      old,
      wanted: red,
      fallback: plain,
      createTrack: newTrack,
      unpublish: unpublishFrom(lp),
      publish: (t, o) async => mutedAtPublish = t.muted,
    );
    expect(mutedAtPublish, isTrue);
  });

  test('all publishes refused: the unpublished new track is stopped (no capture left running)', () async {
    final (lp, old) = await publishedMic();
    LocalAudioTrack? created;
    final (fresh, ok) = await gravixRepublishMic(
      lp,
      old,
      wanted: red,
      fallback: plain,
      createTrack: (o) async => created = await newTrack(o),
      unpublish: unpublishFrom(lp),
      retryDelay: Duration.zero,
      publish: (t, o) async => throw Exception('no'),
    );
    expect((fresh, ok), (null, false));
    expect((created!.mediaStreamTrack as _FakeTrack).stopped, isTrue);
  });

  test('not the published mic: nothing happens', () async {
    final (lp, _) = await publishedMic();
    final other = await newTrack(const AudioCaptureOptions());
    log.clear();
    final (fresh, _) = await gravixRepublishMic(lp, other, wanted: red, fallback: plain, createTrack: newTrack);
    expect(fresh, isNull);
    expect(log, isEmpty);
  });

  // 0.4.12, field 2026-10-06: leaving a room while room music played. The music
  // stop republished the mic during the disconnect, every publish failed, and
  // the capture start of the new track (an Android recorder pre-warm WebRTC
  // never adopts) stayed open after the leave: the microphone stayed live.
  group('teardown (0.4.12)', () {
    late List<String> native;

    setUp(() {
      native = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gravix_client'),
        (call) async {
          native.add(call.method);
          return null;
        },
      );
      gravixExplicitRecordingDebugPlatform = PlatformType.android;
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gravix_client'),
        null,
      );
      gravixExplicitRecordingDebugPlatform = null;
    });

    // what LocalAudioTrack.create gives: a track that is not started yet
    final created = <LocalAudioTrack>[];
    Future<LocalAudioTrack> unstarted(AudioCaptureOptions o) async {
      final t = LocalAudioTrack(TrackSource.microphone, _FakeStream(), _FakeTrack('new-${++n}'), o);
      created.add(t);
      log.add('create');
      return t;
    }

    bool stopped(LocalAudioTrack t) => (t.mediaStreamTrack as _FakeTrack).stopped;

    setUp(created.clear);

    // the published mic; its own capture start is not part of the test
    Future<(LocalParticipant, LocalAudioTrack)> mic() async {
      final r = await publishedMic();
      native.clear();
      return r;
    }

    test('every attempt fails: the new track is stopped and its pre-warmed recorder released, started once', () async {
      final (lp, old) = await mic();
      final (fresh, ok) = await gravixRepublishMic(
        lp,
        old,
        wanted: red,
        fallback: plain,
        createTrack: unstarted,
        unpublish: unpublishFrom(lp),
        retryDelay: Duration.zero,
        publish: (t, o) async => throw Exception('Failed to publish track'),
      );
      expect((fresh, ok), (null, false));
      expect(created, hasLength(1));
      expect(stopped(created.single), isTrue);
      // one capture start (not one per attempt), then its release
      expect(native.where((m) => m == 'startLocalRecording'), hasLength(1));
      expect(native.last, 'stopLocalRecording');
    });

    test('the leave starts between attempts: no more attempts, the new track is stopped', () async {
      final (lp, old) = await mic();
      var leaving = false;
      var attempts = 0;
      final (fresh, _) = await gravixRepublishMic(
        lp,
        old,
        wanted: red,
        fallback: plain,
        createTrack: unstarted,
        unpublish: unpublishFrom(lp),
        retryDelay: Duration.zero,
        stillWanted: () => !leaving,
        publish: (t, o) async {
          attempts++;
          leaving = true; // the disconnect closed the transport under it
          throw Exception('Failed to publish track');
        },
      );
      expect(fresh, isNull);
      expect(attempts, 1);
      expect(stopped(created.single), isTrue);
      expect(native.last, 'stopLocalRecording');
    });

    test('already leaving: nothing is created, the published mic is left to the leave', () async {
      final (lp, old) = await mic();
      final (fresh, _) = await gravixRepublishMic(
        lp,
        old,
        wanted: red,
        fallback: plain,
        createTrack: unstarted,
        unpublish: unpublishFrom(lp),
        stillWanted: () => false,
        publish: (t, o) async => log.add('publish'),
      );
      expect(fresh, isNull);
      expect(created, isEmpty);
      expect(log, isEmpty);
      expect(native, isEmpty);
      expect(identical(lp.getTrackPublicationBySource(TrackSource.microphone)?.track, old), isTrue);
    });

    test('the leave starts while the track is created: it is stopped, the old mic stays published', () async {
      final (lp, old) = await mic();
      var leaving = false;
      final (fresh, _) = await gravixRepublishMic(
        lp,
        old,
        wanted: red,
        fallback: plain,
        createTrack: (o) async {
          final t = await unstarted(o);
          leaving = true;
          return t;
        },
        unpublish: unpublishFrom(lp),
        stillWanted: () => !leaving,
        publish: (t, o) async => log.add('publish'),
      );
      expect(fresh, isNull);
      expect(stopped(created.single), isTrue);
      expect(log, ['create']);
      expect(identical(lp.getTrackPublicationBySource(TrackSource.microphone)?.track, old), isTrue);
    });

    test('published after the leave started: taken down and stopped', () async {
      final (lp, old) = await mic();
      var leaving = false;
      final (fresh, _) = await gravixRepublishMic(
        lp,
        old,
        wanted: red,
        fallback: plain,
        createTrack: unstarted,
        unpublish: unpublishFrom(lp),
        stillWanted: () => !leaving,
        publish: (t, o) async {
          lp.addTrackPublication(
            LocalTrackPublication<LocalAudioTrack>(
              participant: lp,
              info: lk_models.TrackInfo(
                sid: 'TR_new',
                type: lk_models.TrackType.AUDIO,
                source: lk_models.TrackSource.MICROPHONE,
              ),
              track: t,
            ),
          );
          leaving = true;
        },
      );
      expect(fresh, isNull);
      expect(log, ['create', 'unpublish TR_mic', 'unpublish TR_new']);
      expect(stopped(created.single), isTrue);
      expect(native.last, 'stopLocalRecording');
    });

    test('a republish that works keeps its capture (nothing released)', () async {
      final (lp, old) = await mic();
      final (fresh, ok) = await gravixRepublishMic(
        lp,
        old,
        wanted: red,
        fallback: plain,
        createTrack: unstarted,
        unpublish: unpublishFrom(lp),
        publish: (t, o) async => log.add('publish red=${o.red}'),
      );
      expect(ok, isTrue);
      expect(identical(fresh, created.single), isTrue);
      expect(stopped(fresh!), isFalse);
      expect(native, ['startLocalRecording']);
    });

    test('iOS: the track is stopped, the engine-wide stopLocalRecording is never called', () async {
      gravixExplicitRecordingDebugPlatform = PlatformType.iOS;
      final (lp, old) = await mic();
      await gravixRepublishMic(
        lp,
        old,
        wanted: red,
        fallback: plain,
        createTrack: unstarted,
        unpublish: unpublishFrom(lp),
        retryDelay: Duration.zero,
        publish: (t, o) async => throw Exception('no'),
      );
      expect(stopped(created.single), isTrue);
      expect(native, ['startLocalRecording']);
    });
  });
}

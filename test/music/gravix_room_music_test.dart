// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Room music (0.4.10). Field 2026-10-05: room music fell back to the server bot
// in two apps after the migration, because gravix_rtc <= 0.4.9 registered the
// apps' own channel name (`gravity.music_mixer`) and swallowed their kit's
// calls. These tests pin GravixRoomMusic: the channel contract with the native
// mixer, the state machine, the errors, the voice-only mute while music plays
// (the publication must stay live: the SFU stops forwarding a muted track), the
// music bitrate and the room lifecycle.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/gravix_rtc.dart'
    show
        GravixMusicErrorCode,
        GravixMusicException,
        GravixMusicOptions,
        GravixMusicSource,
        GravixMusicState,
        GravixMusicStatus,
        GravixRoomMusic,
        kGravixMusicChannel;
import 'package:gravix_rtc/src/music/gravix_music_channel.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/participant/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/publication/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/music_voice_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

class _FakeWs extends GravixRtcWebSocket {
  final sent = <lk_rtc.SignalRequest>[];

  @override
  void send(List<int> data) => sent.add(lk_rtc.SignalRequest.fromBuffer(data));
}

class _FakeTrack implements rtc.MediaStreamTrack {
  @override
  bool enabled = true;
  @override
  String? get id => 'mic-1';
  @override
  String? get kind => 'audio';
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isSetter ? null : super.noSuchMethod(invocation);
}

class _FakeStream implements rtc.MediaStream {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final log = <String>[];

class _FakeSender implements rtc.RTCRtpSender {
  _FakeSender({int? maxBitrate = 64000})
    : _parameters = rtc.RTCRtpParameters(encodings: [rtc.RTCRtpEncoding(maxBitrate: maxBitrate)]);
  rtc.RTCRtpParameters _parameters;
  int? nativeMaxBitrate = 64000;

  @override
  rtc.RTCRtpParameters get parameters => _parameters;

  @override
  Future<bool> setParameters(rtc.RTCRtpParameters parameters) async {
    _parameters = parameters;
    nativeMaxBitrate = parameters.encodings!.first.maxBitrate;
    log.add('setParameters($nativeMaxBitrate)');
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTransceiver implements rtc.RTCRtpTransceiver {
  _FakeTransceiver(this.sender);
  @override
  final rtc.RTCRtpSender sender;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The native mixer, as the Android plugin answers.
class _Native {
  final calls = <MethodCall>[];
  bool installOk = true;
  bool captureLive = true;
  String? startError; // a PlatformException code for `start`
  bool active = false;
  bool paused = false;
  int positionMs = 0;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'install':
        return installOk;
      case 'getState':
        return {
          'active': active,
          'paused': paused,
          'interrupted': null,
          'positionMs': active ? positionMs : -1,
          'durationMs': active ? 180000 : -1,
          'captureReady': captureLive,
          'captureLive': captureLive,
          'captureSampleRate': 48000,
          'captureChannels': 1,
          'installed': installOk,
        };
      case 'start':
        if (startError != null) throw PlatformException(code: startError!, message: 'nope');
        active = true;
        paused = false;
        return {'durationMs': 180000};
      case 'pause':
        paused = true;
        return null;
      case 'resume':
        paused = false;
        return null;
      case 'stop':
        active = false;
        paused = false;
        return null;
      default:
        return null;
    }
  }

  List<String> get methods => [for (final c in calls) c.method];

  /// Everything but the position polls.
  List<String> get control => [
    for (final c in calls)
      if (c.method != 'getState') c.method,
  ];
  MethodCall last(String method) => calls.lastWhere((c) => c.method == method);
}

const _channel = MethodChannel(kGravixMusicChannel);

Future<void> _fromNative(String method, [Object? args]) async {
  final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    kGravixMusicChannel,
    data,
    (_) {},
  );
}

Future<void> _settle([int ms = 0]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Native native;
  late _FakeWs ws;
  late List<bool> engineMutes;

  setUp(() {
    log.clear();
    native = _Native();
    engineMutes = <bool>[];
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      m.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
    m.setMockMethodCallHandler(_channel, native.handle);
    GravixEngineMicMute.debugReset(
      supported: () => true,
      setNative: (mute) async {
        engineMutes.add(mute);
        log.add('native.mute($mute)');
        return true;
      },
    );
    GravixRoomMusic.debugPlatform = PlatformType.android;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    GravixEngineMicMute.debugReset();
    GravixMusicVoiceMute.debugReset();
    GravixMusicEventHub.debugReset();
    GravixRoomMusic.debugPlatform = null;
  });

  /// A room whose signalling is a fake socket, with a published microphone.
  Future<(Room, LocalParticipant, LocalAudioTrack, _FakeTrack, _FakeSender)> roomWithMic({
    bool stopAudioCaptureOnMute = false,
    bool publishMic = true,
  }) async {
    final sc = SignalClient((uri, {options, headers, networkOptions, preconnected}) async => ws = _FakeWs());
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
    room.debugLocalParticipant = lp;
    final media = _FakeTrack();
    final track = LocalAudioTrack(
      TrackSource.microphone,
      _FakeStream(),
      media,
      AudioCaptureOptions(stopAudioCaptureOnMute: stopAudioCaptureOnMute),
    );
    await track.start();
    final sender = _FakeSender();
    track.transceiver = _FakeTransceiver(sender);
    if (publishMic) {
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
    }
    ws.sent.clear();
    return (room, lp, track, media, sender);
  }

  List<(String, bool)> muteSignals() => [for (final r in ws.sent.where((r) => r.hasMute())) (r.mute.sid, r.mute.muted)];

  GravixRoomMusic music(Room? room, {GravixMusicOptions options = const GravixMusicOptions()}) {
    final m = GravixRoomMusic(
      room,
      options: options,
      pollInterval: const Duration(milliseconds: 10),
      captureTimeout: const Duration(milliseconds: 150),
      fileExists: (_) async => true,
    );
    addTearDown(m.dispose); // a failed test must not leave its poll running
    return m;
  }

  group('channel', () {
    test('the SDK never uses the apps\' kit channel name again (the 0.4.9 hijack)', () {
      expect(kGravixMusicChannel, 'com.gravitycompile.gravix_rtc/music');
      final hits = <String>[];
      for (final dir in ['lib', 'android/src', 'ios/gravix_rtc/Sources']) {
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
          if (!RegExp(r'\.(dart|kt|java|swift|m|h)$').hasMatch(f.path)) continue;
          final text = f.readAsStringSync();
          // code that REGISTERS or calls the old name; docs mentioning it are fine
          if (RegExp(r'''(MethodChannel|FlutterMethodChannel)\((name: )?["']gravity\.music_mixer''').hasMatch(text)) {
            hits.add(f.path);
          }
        }
      }
      expect(hits, isEmpty);
    });
  });

  group('start', () {
    test('installs, waits for the live capture, starts with every setting; state -> playing', () async {
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room, options: const GravixMusicOptions(monitor: false, ducking: true, duckLevel: 0.2));
      final seen = <GravixMusicStatus>[];
      m.states.listen((s) => seen.add(s.status));
      await m.start(const GravixMusicSource.file('/sdcard/Music/a.mp3'), loop: true, volume: 0.6);
      expect(native.methods.first, 'install', reason: 'attach installs early');
      expect(native.methods.skip(1).take(3), ['install', 'getState', 'start']);
      final start = native.last('start').arguments as Map;
      expect(start['source'], '/sdcard/Music/a.mp3');
      expect(start['contentUri'], false);
      expect(start['loop'], true);
      expect(start['monitor'], false);
      expect(start['musicVolume'], 0.6);
      expect(start['micVolume'], 1.0);
      expect(start['ducking'], true);
      expect(start['duckLevel'], 0.2);
      expect(start['holdOnMute'], false);
      expect(start['pauseOnInterruption'], true);
      expect(m.state.value.status, GravixMusicStatus.playing);
      expect(m.state.value.duration, const Duration(minutes: 3));
      expect(m.state.value.loop, isTrue);
      await _settle();
      expect(seen.take(2), [GravixMusicStatus.loading, GravixMusicStatus.playing]);

      native.positionMs = 4200;
      await _settle(40);
      expect(m.state.value.position, const Duration(milliseconds: 4200));
      await m.dispose();
    });

    test('content URI and asset sources', () async {
      final (room, _, _, _, _) = await roomWithMic();
      final m = GravixRoomMusic(
        room,
        fileExists: (_) async => true,
        captureTimeout: const Duration(milliseconds: 100),
        assetResolver: (s) async => '/cache/${s.value}',
      );
      await m.start(const GravixMusicSource.contentUri('content://media/external/audio/media/7'));
      expect((native.last('start').arguments as Map)['contentUri'], true);
      await m.start(const GravixMusicSource.asset('song.m4a'));
      expect((native.last('start').arguments as Map)['source'], '/cache/song.m4a');
      await m.dispose();
    });

    test('not connected / no microphone / unsupported platform: typed errors, nothing native', () async {
      final idle = music(null);
      await expectLater(
        idle.start(const GravixMusicSource.file('/a.mp3')),
        throwsA(isA<GravixMusicException>().having((e) => e.code, 'code', GravixMusicErrorCode.notConnected)),
      );
      final (room, _, _, _, _) = await roomWithMic(publishMic: false);
      final m = music(room);
      final errors = <GravixMusicException>[];
      m.errors.listen(errors.add);
      await expectLater(
        m.start(const GravixMusicSource.file('/a.mp3')),
        throwsA(isA<GravixMusicException>().having((e) => e.code, 'code', GravixMusicErrorCode.noMicrophone)),
      );
      expect(m.state.value.status, GravixMusicStatus.error);
      await _settle();
      expect(errors.single.code, GravixMusicErrorCode.noMicrophone);

      GravixRoomMusic.debugPlatform = PlatformType.web;
      native.calls.clear(); // attach's early install
      await expectLater(
        m.start(const GravixMusicSource.file('/a.mp3')),
        throwsA(isA<GravixMusicException>().having((e) => e.code, 'code', GravixMusicErrorCode.unsupported)),
      );
      expect(native.calls, isEmpty);
      await idle.dispose();
      await m.dispose();
    });

    test('a bad file is reported at once (openFailed), the microphone is given back', () async {
      native.startError = 'OPEN_FAILED';
      final (room, _, _, _, sender) = await roomWithMic();
      final m = music(room);
      await expectLater(
        m.start(const GravixMusicSource.file('/missing.mp3')),
        throwsA(isA<GravixMusicException>().having((e) => e.code, 'code', GravixMusicErrorCode.openFailed)),
      );
      expect(m.state.value.status, GravixMusicStatus.error);
      expect(m.state.value.error?.code, GravixMusicErrorCode.openFailed);
      expect(sender.nativeMaxBitrate, 64000, reason: 'the music bitrate is undone');
      expect(GravixMusicVoiceMute.predicate, isNull);
      await m.dispose();
    });

    test('a missing file fails before the microphone is touched (no install, no bitrate, no republish)', () async {
      final (room, _, _, _, sender) = await roomWithMic();
      final m = GravixRoomMusic(room, fileExists: (_) async => false);
      addTearDown(m.dispose);
      native.calls.clear();
      await expectLater(
        m.start(const GravixMusicSource.file('/nope.mp3')),
        throwsA(isA<GravixMusicException>().having((e) => e.code, 'code', GravixMusicErrorCode.openFailed)),
      );
      expect(native.control, isNot(contains('start')));
      expect(sender.nativeMaxBitrate, 64000);
    });

    test('capture never comes up: captureNotReady (no guessed format)', () async {
      native.captureLive = false;
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      await expectLater(
        m.start(const GravixMusicSource.file('/a.mp3')),
        throwsA(isA<GravixMusicException>().having((e) => e.code, 'code', GravixMusicErrorCode.captureNotReady)),
      );
      expect(native.methods, isNot(contains('start')));
      await m.dispose();
    });

    test('the hook cannot be installed: installFailed', () async {
      native.installOk = false;
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      await expectLater(
        m.start(const GravixMusicSource.file('/a.mp3')),
        throwsA(isA<GravixMusicException>().having((e) => e.code, 'code', GravixMusicErrorCode.installFailed)),
      );
      await m.dispose();
    });
  });

  group('transport', () {
    test('pause / resume / seek / volumes / loop / stop forward to the mixer and update the state', () async {
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      await m.pause();
      expect(m.state.value.status, GravixMusicStatus.paused);
      await m.resume();
      expect(m.state.value.status, GravixMusicStatus.playing);
      await m.seek(const Duration(seconds: 30));
      expect((native.last('seek').arguments as Map)['positionMs'], 30000);
      await m.setMusicVolume(1.7);
      expect((native.last('setMusicVolume').arguments as Map)['volume'], 1.0, reason: 'clamped to 0..1');
      await m.setMicVolume(0.4);
      expect((native.last('setMicVolume').arguments as Map)['volume'], 0.4);
      await m.setDucking(true);
      expect((native.last('setDucking').arguments as Map)['on'], true);
      await m.setLoop(true);
      expect((native.last('setLoop').arguments as Map)['on'], true);
      await m.stop();
      expect(native.control.last, 'stop');
      final s = m.state.value;
      expect(s.status, GravixMusicStatus.idle);
      expect((s.musicVolume, s.micVolume, s.ducking, s.loop), (1.0, 0.4, true, true));
      await m.dispose();
    });

    test('idle: settings are kept for the next track, nothing native', () async {
      final m = music(null);
      await m.setMusicVolume(0.3);
      await m.pause();
      await m.seek(const Duration(seconds: 1));
      expect(native.calls, isEmpty);
      expect(m.state.value.musicVolume, 0.3);
      await m.dispose();
    });

    test('iOS: mic volume / ducking are unsupported and leave the state alone', () async {
      GravixRoomMusic.debugPlatform = PlatformType.iOS;
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      expect(native.methods, isNot(contains('getState')), reason: 'iOS starts once the engine runs');
      await expectLater(
        m.setMicVolume(0.5),
        throwsA(isA<GravixMusicException>().having((e) => e.code, 'code', GravixMusicErrorCode.unsupported)),
      );
      expect(m.state.value.status, GravixMusicStatus.playing);
      await m.dispose();
    });
  });

  group('native events', () {
    test('completed: native released, idle, completed fires once', () async {
      final (room, _, _, _, sender) = await roomWithMic();
      final m = music(room);
      var done = 0;
      m.completed.listen((_) => done++);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      expect(sender.nativeMaxBitrate, 96000);
      await _fromNative('onCompleted');
      await _settle(5);
      expect(done, 1);
      expect(m.state.value.status, GravixMusicStatus.idle);
      expect(native.control.last, 'stop');
      expect(sender.nativeMaxBitrate, 64000);
      await m.dispose();
    });

    test('decoder error: error state + errors stream', () async {
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      final errors = <GravixMusicException>[];
      m.errors.listen(errors.add);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      await _fromNative('onError', {'code': 'DECODE_FAILED', 'message': 'codec died'});
      await _settle(5);
      expect(m.state.value.status, GravixMusicStatus.error);
      expect(errors.single.code, GravixMusicErrorCode.decodeFailed);
      await m.dispose();
    });

    test('phone call: paused + interrupted, then playing again', () async {
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      await _fromNative('onInterruption', {'active': true, 'reason': 'call', 'resumed': false});
      expect(m.state.value.status, GravixMusicStatus.paused);
      expect(m.state.value.interrupted, isTrue);
      await _fromNative('onInterruption', {'active': false, 'reason': 'call', 'resumed': true});
      expect(m.state.value.status, GravixMusicStatus.playing);
      expect(m.state.value.interrupted, isFalse);
      await m.dispose();
    });
  });

  group('microphone', () {
    test('music bitrate on start, restored on stop; a cap someone else set is theirs', () async {
      final (room, _, _, _, sender) = await roomWithMic();
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      expect(sender.nativeMaxBitrate, 96000);
      await m.stop();
      expect(sender.nativeMaxBitrate, 64000);

      await m.start(const GravixMusicSource.file('/a.mp3'));
      // the audio-first policy caps the mic meanwhile
      sender.parameters.encodings!.first.maxBitrate = 24000;
      await sender.setParameters(sender.parameters);
      await m.stop();
      expect(sender.nativeMaxBitrate, 24000);
      await m.dispose();
    });

    test('mute while music plays: voice-only, no mute signal, no uplink cap; stop turns it into a real mute', () async {
      final (room, lp, track, media, sender) = await roomWithMic();
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      log.clear();

      await lp.setMicrophoneEnabled(
        false,
        audioCaptureOptions: const AudioCaptureOptions(stopAudioCaptureOnMute: false),
      );
      await _settle();
      expect(track.muted, isTrue, reason: 'the app sees its mute');
      expect(track.voiceOnlyMuted, isTrue);
      expect(track.wireMuted, isFalse, reason: 'the SFU must keep forwarding the music');
      expect(engineMutes, [true], reason: 'the voice is zeroed in the audio device module');
      expect(media.enabled, isTrue);
      expect(muteSignals(), isEmpty);
      expect(sender.nativeMaxBitrate, 96000, reason: 'no 6 kbps cap under the music');

      await m.stop();
      await _settle();
      expect(log, ['native.mute(true)', 'setParameters(64000)', 'setParameters(6000)']);
      expect(muteSignals(), [('TR_mic', true)]);
      expect(track.muted, isTrue);
      expect(track.voiceOnlyMuted, isFalse);
      expect(track.wireMuted, isTrue);

      // and the unmute after it is a normal one
      await lp.setMicrophoneEnabled(
        true,
        audioCaptureOptions: const AudioCaptureOptions(stopAudioCaptureOnMute: false),
      );
      await _settle();
      expect(muteSignals(), [('TR_mic', true), ('TR_mic', false)]);
      expect(sender.nativeMaxBitrate, 64000);
      await m.dispose();
    });

    test('a mic track replaced during the session (app republish) still gets the voice-only mute', () async {
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      final other = LocalAudioTrack(
        TrackSource.microphone,
        _FakeStream(),
        _FakeTrack(),
        const AudioCaptureOptions(stopAudioCaptureOnMute: true),
      );
      await other.start();
      expect(await other.mute(stopOnMute: true), isTrue);
      expect(other.voiceOnlyMuted, isTrue);
      expect(other.wireMuted, isFalse);
      await other.unmute(stopOnMute: true);
      await m.stop();
      final after = LocalAudioTrack(TrackSource.microphone, _FakeStream(), _FakeTrack(), const AudioCaptureOptions());
      await after.start();
      await after.mute(stopOnMute: false);
      expect(after.voiceOnlyMuted, isFalse, reason: 'no music: a normal mute');
    });

    test('voice-only mute is taken even with stopAudioCaptureOnMute (the old apps\' setting)', () async {
      final (room, lp, track, media, _) = await roomWithMic(stopAudioCaptureOnMute: true);
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      await lp.setMicrophoneEnabled(false, audioCaptureOptions: const AudioCaptureOptions());
      await _settle();
      expect(track.voiceOnlyMuted, isTrue);
      expect(media.enabled, isTrue, reason: 'a stopped capture would stop the music');
      expect(muteSignals(), isEmpty);
      await lp.setMicrophoneEnabled(true, audioCaptureOptions: const AudioCaptureOptions());
      await _settle();
      expect(track.muted, isFalse);
      expect(engineMutes, [true, false]);
      expect(muteSignals(), isEmpty, reason: 'the wire never saw the mute');
      await m.dispose();
    });

    test('start while muted: the voice stays muted, the music goes out (unmute signal, cap lifted)', () async {
      final (room, lp, track, _, sender) = await roomWithMic();
      await lp.setMicrophoneEnabled(
        false,
        audioCaptureOptions: const AudioCaptureOptions(stopAudioCaptureOnMute: false),
      );
      await _settle();
      expect(sender.nativeMaxBitrate, 6000);
      ws.sent.clear();

      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      await _settle();
      expect(track.muted, isTrue);
      expect(track.voiceOnlyMuted, isTrue);
      expect(muteSignals(), [('TR_mic', false)]);
      expect(sender.nativeMaxBitrate, 96000);
      expect(GravixEngineMicMute.engaged, isTrue);
      await m.dispose();
      await _settle();
      expect(muteSignals(), [('TR_mic', false), ('TR_mic', true)]);
    });

    test('continueWhileMicMuted: false keeps the old mute (signalled; the mixer holds the music)', () async {
      final (room, lp, track, _, _) = await roomWithMic();
      final m = music(room, options: const GravixMusicOptions(continueWhileMicMuted: false));
      await m.start(const GravixMusicSource.file('/a.mp3'));
      expect((native.last('start').arguments as Map)['holdOnMute'], true);
      await lp.setMicrophoneEnabled(
        false,
        audioCaptureOptions: const AudioCaptureOptions(stopAudioCaptureOnMute: false),
      );
      await _settle();
      expect(track.voiceOnlyMuted, isFalse);
      expect(muteSignals(), [('TR_mic', true)]);
      await m.dispose();
    });
  });

  group('lifecycle', () {
    test('room disconnect stops and releases the music', () async {
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      room.events.emit(RoomDisconnectedEvent());
      await _settle(5);
      expect(m.state.value.status, GravixMusicStatus.idle);
      expect(native.control.last, 'stop');
      expect(GravixMusicVoiceMute.predicate, isNull);
      await m.dispose();
    });

    test('dispose stops the music; the object is unusable after', () async {
      final (room, _, _, _, _) = await roomWithMic();
      final m = music(room);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      await m.dispose();
      expect(native.control.last, 'stop');
      expect(() => m.start(const GravixMusicSource.file('/a.mp3')), throwsStateError);
    });

    test('state value object', () {
      const s = GravixMusicState(status: GravixMusicStatus.paused);
      expect(s.isActive, isTrue);
      expect(s.copyWith(status: GravixMusicStatus.idle).isActive, isFalse);
      expect(const GravixMusicSource.file('/a') == const GravixMusicSource.file('/a'), isTrue);
      expect(const GravixMusicSource.file('/a') == const GravixMusicSource.contentUri('/a'), isFalse);
    });
  });

  // 0.4.12, field 2026-10-06: leaving a room while music played. The music stop
  // gave DTX back by republishing the mic during the disconnect; the publishes
  // failed and a capture started by the republish stayed open after the leave.
  group('leave while music plays (0.4.12)', () {
    late List<String> rec;
    late List<String> clientNative;
    late List<_RecTrack> media;

    setUp(() {
      rec = [];
      clientNative = [];
      media = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gravix_client'),
        (call) async {
          clientNative.add(call.method);
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

    /// Music on a DTX mic: the session republishes it with DTX off. After
    /// that, [failRestore] refuses every publish (the one giving DTX back and
    /// its fallbacks) and [onRestorePublish] runs on each.
    Future<(Room, LocalParticipant, GravixRoomMusic)> musicOnDtxMic({
      bool failRestore = false,
      void Function()? onRestorePublish,
    }) async {
      var started = false;
      final (room, lp, track, _, _) = await roomWithMic();
      track.lastPublishOptions = const AudioPublishOptions(dtx: true);
      var sid = 0;
      final m = GravixRoomMusic(
        room,
        pollInterval: const Duration(milliseconds: 10),
        captureTimeout: const Duration(milliseconds: 150),
        fileExists: (_) async => true,
        republishRetryDelay: Duration.zero,
        createMicTrack: (o) async {
          final t = _RecTrack('new-${media.length + 1}');
          media.add(t);
          rec.add('create');
          return LocalAudioTrack(TrackSource.microphone, _FakeStream(), t, o);
        },
        unpublishMicTrack: (s) async {
          rec.add('unpublish $s');
          lp.trackPublications.remove(s);
        },
        publishMicTrack: (t, o) async {
          rec.add('publish dtx=${o.dtx}');
          if (started) {
            onRestorePublish?.call();
            if (failRestore) throw Exception('Failed to publish track');
          }
          t.lastPublishOptions = o;
          lp.addTrackPublication(
            LocalTrackPublication<LocalAudioTrack>(
              participant: lp,
              info: lk_models.TrackInfo(
                sid: 'TR_r${++sid}',
                type: lk_models.TrackType.AUDIO,
                source: lk_models.TrackSource.MICROPHONE,
              ),
              track: t,
            ),
          );
        },
      );
      addTearDown(m.dispose);
      await m.start(const GravixMusicSource.file('/a.mp3'));
      expect(rec, ['create', 'unpublish TR_mic', 'publish dtx=false']);
      started = true;
      rec.clear();
      clientNative.clear();
      return (room, lp, m);
    }

    test('connected: stop gives DTX back (the republish still runs)', () async {
      final (_, lp, m) = await musicOnDtxMic();
      await m.stop();
      expect(rec, ['create', 'unpublish TR_r1', 'publish dtx=true']);
      expect(
        (lp.getTrackPublicationBySource(TrackSource.microphone)?.track as LocalAudioTrack?)?.lastPublishOptions?.dtx,
        isTrue,
      );
    });

    test('stop while the room is leaving: the mixer stops, no republish, no new track', () async {
      final (room, lp, m) = await musicOnDtxMic();
      final sessionMic = lp.getTrackPublicationBySource(TrackSource.microphone)?.track;
      room.gravixMarkLeaving();
      await m.stop();
      expect(native.control.last, 'stop');
      expect(m.state.value.status, GravixMusicStatus.idle);
      expect(rec, isEmpty);
      expect(media.skip(1), isEmpty);
      expect(clientNative.where((c) => c == 'startLocalRecording'), isEmpty);
      // the leave unpublishes and stops it, not the music
      expect(identical(lp.getTrackPublicationBySource(TrackSource.microphone)?.track, sessionMic), isTrue);
    });

    test('stopForLeave (GravixRoomService.disconnect): no republish even while still connected', () async {
      final (_, _, m) = await musicOnDtxMic();
      await m.stopForLeave();
      expect(native.control.last, 'stop');
      expect(rec, isEmpty);
    });

    test('room disconnected event: no republish', () async {
      final (room, _, m) = await musicOnDtxMic();
      room.gravixMarkLeaving();
      room.events.emit(RoomDisconnectedEvent());
      await _settle(5);
      expect(m.state.value.status, GravixMusicStatus.idle);
      expect(rec, isEmpty);
    });

    test('dispose of a leaving room: no republish', () async {
      final (room, _, m) = await musicOnDtxMic();
      room.gravixMarkLeaving();
      await m.dispose();
      expect(rec, isEmpty);
    });

    test('the leave starts during the DTX republish: retries stop, every created track is stopped', () async {
      late Room r;
      final (room, _, m) = await musicOnDtxMic(failRestore: true, onRestorePublish: () => r.gravixMarkLeaving());
      r = room;
      await m.stop();
      expect(rec, ['create', 'unpublish TR_r1', 'publish dtx=true']);
      expect(media, hasLength(2));
      expect(media[1].stopped, isTrue); // the unpublished new track
      expect(clientNative, ['startLocalRecording', 'stopLocalRecording']);
    });

    test('a republish refused three times (connected): the new track is stopped and released', () async {
      final (_, _, m) = await musicOnDtxMic(failRestore: true);
      await m.stop();
      // wanted (dtx on), then twice the fallback (the session's options)
      expect(rec, ['create', 'unpublish TR_r1', 'publish dtx=true', 'publish dtx=false', 'publish dtx=false']);
      expect(media[1].stopped, isTrue);
      expect(clientNative.where((c) => c == 'startLocalRecording'), hasLength(1));
      expect(clientNative.last, 'stopLocalRecording');
    });
  });
}

class _RecTrack implements rtc.MediaStreamTrack {
  _RecTrack(this.id);
  @override
  final String? id;
  @override
  bool enabled = true;
  bool stopped = false;
  @override
  String? get kind => 'audio';
  @override
  Future<void> stop() async => stopped = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isSetter ? null : super.noSuchMethod(invocation);
}

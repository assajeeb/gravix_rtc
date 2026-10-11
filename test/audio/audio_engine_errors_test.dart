// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.15 (2026-10-10), item 7c of the 2026-10-10 field report: microphone
// failures with a known cause get their own exception types instead of an
// AudioProcessingException (ported from the upstream client SDK 2.12.0, tag
// v2.12.0, commit 2baacc4306e04d0ad3c826b4826348560f2b40bd), and a failed
// Android recorder pre-warm never aborts the microphone.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/audio_engine_error.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/audio_manager.dart';
import 'package:gravix_rtc/src/rtc_core/src/exceptions.dart' show AudioSessionException, TrackCreateException;
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const gravix = MethodChannel('gravix_client');
  const webrtc = MethodChannel('FlutterWebRTC.Method');

  late List<String> native;
  late List<String> webrtcCalls;
  // method -> error code the native side answers with
  late Map<String, String> fail;

  setUp(() {
    native = [];
    webrtcCalls = [];
    fail = {};
    messenger.setMockMethodCallHandler(gravix, (call) async {
      native.add(call.method);
      final code = fail[call.method];
      if (code != null) throw PlatformException(code: code, message: 'native says $code');
      return null;
    });
    messenger.setMockMethodCallHandler(webrtc, (call) async {
      webrtcCalls.add(call.method);
      if (call.method == 'getUserMedia') throw PlatformException(code: 'stop-here');
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(gravix, null);
    messenger.setMockMethodCallHandler(webrtc, null);
    debugLkPlatformOverride = null;
    gravixExplicitRecordingDebugPlatform = null;
    AudioManager.instance.resetForTest();
  });

  group('audioEngineExceptionFrom', () {
    test('maps the three known codes, nothing else', () {
      expect(
        audioEngineExceptionFrom(PlatformException(code: 'deviceAccessDenied', message: 'denied')),
        isA<TrackCreateException>().having((e) => e.message, 'message', 'denied'),
      );
      expect(
        audioEngineExceptionFrom(PlatformException(code: 'audioSessionInvalidCategory')),
        isA<AudioSessionException>(),
      );
      expect(
        audioEngineExceptionFrom(PlatformException(code: 'audioSessionConfigureFailed', message: '  ')),
        isA<AudioSessionException>().having((e) => e.message, 'message', 'Failed to configure the audio session'),
      );
      expect(audioEngineExceptionFrom(PlatformException(code: 'applyFailed')), isNull);
    });
  });

  group('explicit recording start', () {
    test('Android: a failed pre-warm with any other code does not abort the microphone', () async {
      gravixExplicitRecordingDebugPlatform = PlatformType.android;
      for (final code in ['applyFailed', 'rejectedInvalidCombination', 'unknown', 'somethingNew']) {
        final started = await gravixStartExplicitRecording(() async => throw PlatformException(code: code));
        expect(started, isFalse, reason: code);
      }
    });

    test('Android: a missing permission still fails the track', () async {
      gravixExplicitRecordingDebugPlatform = PlatformType.android;
      await expectLater(
        gravixStartExplicitRecording(() async => throw PlatformException(code: 'deviceAccessDenied')),
        throwsA(isA<TrackCreateException>()),
      );
    });

    test('iOS: a real processing failure still throws AudioProcessingException', () async {
      gravixExplicitRecordingDebugPlatform = PlatformType.iOS;
      await expectLater(
        gravixStartExplicitRecording(() async => throw PlatformException(code: 'applyFailed')),
        throwsA(isA<AudioProcessingException>()),
      );
    });

    test('iOS: the resolved session policy reaches native before the recording starts (-9001)', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      gravixExplicitRecordingDebugPlatform = PlatformType.iOS;
      await AudioManager.instance.ensureAppleAudioSessionPolicy();
      expect(native, ['setAppleAudioSessionAutomaticManagementEnabled', 'configureNativeAudio']);
    });

    test('Android: no Apple policy push', () async {
      debugLkPlatformOverride = PlatformType.android;
      await AudioManager.instance.ensureAppleAudioSessionPolicy();
      expect(native, isEmpty);
    });
  });

  group('microphone permission fail-fast (iOS)', () {
    test('denied: TrackCreateException before getUserMedia is asked', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      fail['ensureMicrophoneAccess'] = 'deviceAccessDenied';
      await expectLater(LocalTrack.createStream(const AudioCaptureOptions()), throwsA(isA<TrackCreateException>()));
      expect(native, ['ensureMicrophoneAccess']);
      expect(webrtcCalls, isEmpty);
    });

    test('granted: getUserMedia runs', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      await expectLater(
        LocalTrack.createStream(const AudioCaptureOptions()),
        throwsA(isNot(isA<TrackCreateException>())),
      );
      expect(native, ['ensureMicrophoneAccess']);
      expect(webrtcCalls, contains('getUserMedia'));
    });

    test('Android: not asked', () async {
      debugLkPlatformOverride = PlatformType.android;
      await expectLater(
        LocalTrack.createStream(const AudioCaptureOptions()),
        throwsA(isNot(isA<TrackCreateException>())),
      );
      expect(native, isEmpty);
    });
  });

  group('engine-wide calls map known causes (iOS)', () {
    test('setEngineAvailability: deviceAccessDenied -> TrackCreateException', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      fail['setEngineAvailability'] = 'deviceAccessDenied';
      await expectLater(
        AudioManager.instance.setEngineAvailability(AudioEngineAvailability.defaultAvailability),
        throwsA(isA<TrackCreateException>()),
      );
    });

    test('setMicrophoneMuteMode: audioSessionInvalidCategory -> AudioSessionException', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      fail['setMicrophoneMuteMode'] = 'audioSessionInvalidCategory';
      await expectLater(
        AudioManager.instance.setMicrophoneMuteMode(MicrophoneMuteMode.inputMixer),
        throwsA(isA<AudioSessionException>()),
      );
    });

    test('an unknown code stays a PlatformException', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      fail['setMicrophoneMuteMode'] = 'setMicrophoneMuteMode';
      await expectLater(
        AudioManager.instance.setMicrophoneMuteMode(MicrophoneMuteMode.inputMixer),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}

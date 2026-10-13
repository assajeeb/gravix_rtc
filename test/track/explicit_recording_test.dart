// 2026-09-27, Android emulator: every mic publish failed with
// "Audio processing options are unavailable on this platform" -- startCapture
// asked a native method no Gravix plugin implements (startLocalRecording on the
// gravix_client channel) and treated "not there" as a failure. The explicit start
// is an optimisation (flutter_webrtc starts the audio device when the track is
// published); an unavailable platform must not cost the user their microphone.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

class _FakeTrack implements rtc.MediaStreamTrack {
  @override
  bool enabled = true;
  @override
  String? get id => 'mic';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 0.4.12, field 2026-10-06: the explicit start pre-warms the Android recorder,
  // which WebRTC only adopts when the track is published and the engine starts
  // recording. A track stopped without that kept the microphone open.
  group('stop releases the explicit start (0.4.12)', () {
    late List<String> native;
    String? startError;

    setUp(() {
      native = [];
      startError = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gravix_client'),
        (call) async {
          native.add(call.method);
          if (call.method == 'startLocalRecording' && startError != null) {
            throw PlatformException(code: startError!, message: 'x');
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gravix_client'),
        null,
      );
      gravixExplicitRecordingDebugPlatform = null;
    });

    LocalAudioTrack track() =>
        LocalAudioTrack(TrackSource.microphone, _FakeStream(), _FakeTrack(), const AudioCaptureOptions());

    test('Android: a started-then-stopped track releases the recorder, once', () async {
      gravixExplicitRecordingDebugPlatform = PlatformType.android;
      final t = track();
      await t.start();
      await t.stop();
      await t.stop();
      expect(native, ['startLocalRecording', 'stopLocalRecording']);
    });

    test('Android: no explicit start (platform unavailable) -> nothing to release', () async {
      gravixExplicitRecordingDebugPlatform = PlatformType.android;
      startError = 'rejectedPlatformUnavailable';
      final t = track();
      await t.start();
      await t.stop();
      expect(native, ['startLocalRecording']);
    });

    test('iOS: never the engine-wide stop', () async {
      gravixExplicitRecordingDebugPlatform = PlatformType.iOS;
      final t = track();
      await t.start();
      await t.stop();
      expect(native, ['startLocalRecording']);
    });

    test('flutter test platform: neither', () async {
      final t = track();
      await t.start();
      await t.stop();
      expect(native, isEmpty);
    });
  });

  test('an unavailable platform skips the explicit start instead of failing the mic', () async {
    final started = await gravixStartExplicitRecording(
      () async => throw PlatformException(
        code: 'rejectedPlatformUnavailable',
        message: 'Audio processing options are unavailable on this platform.',
      ),
    );
    expect(started, isFalse);
  });

  test('a real processing failure still fails, as before', () async {
    await expectLater(
      gravixStartExplicitRecording(
        () async => throw PlatformException(code: 'rejectedInvalidCombination', message: 'bad'),
      ),
      throwsA(
        isA<AudioProcessingException>().having(
          (e) => e.reason,
          'reason',
          AudioProcessingFailureReason.invalidCombination,
        ),
      ),
    );
  });

  // 0.4.15 (2026-10-10, field report item 7c; upstream client SDK 2.12.0):
  // a failed recorder pre-warm on Android is best effort and must never abort
  // the microphone, whatever code a native side answers with.
  test('Android: a failed pre-warm (applyFailed) does not abort the microphone', () async {
    gravixExplicitRecordingDebugPlatform = PlatformType.android;
    try {
      final started = await gravixStartExplicitRecording(
        () async => throw PlatformException(code: 'applyFailed', message: 'prewarm failed'),
      );
      expect(started, isFalse);
    } finally {
      gravixExplicitRecordingDebugPlatform = null;
    }
  });

  test('a start that works reports started', () async {
    expect(await gravixStartExplicitRecording(() async {}), isTrue);
  });

  // 2026-10-13, field (an Android app, 1 of ~15 host joins): SIGABRT in
  // AudioRecordJava, libc++ "span<T>::operator[]: index out of range" under
  // WebRtcAudioRecord.nativeDataIsRecorded. The record thread the pre-warm had
  // started delivered a buffer between the engine's InitRecording caching the
  // direct buffer (`direct buffer capacity: 1920`, 17.958) and setting
  // frames_per_buffer (`frames_per_buffer: 480`, 17.960). An app can ask that
  // the recorder is only prepared at the capture start (options, mixer hook,
  // AudioRecord) and that its thread is started by the engine itself, after its
  // InitRecording finished.
  group('Android: who starts the record thread (GravixAndroidRecorder)', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gravix_client'),
        (call) async {
          calls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gravix_client'),
        null,
      );
      gravixExplicitRecordingDebugPlatform = null;
      GravixAndroidRecorder.startThreadAtCapture = true;
    });

    LocalAudioTrack track() =>
        LocalAudioTrack(TrackSource.microphone, _FakeStream(), _FakeTrack(), const AudioCaptureOptions());

    Map<Object?, Object?> startArgs() {
      final start = calls.where((c) => c.method == 'startLocalRecording').single;
      return start.arguments as Map<Object?, Object?>;
    }

    test('default: as before, the capture start starts the record thread', () async {
      expect(GravixAndroidRecorder.startThreadAtCapture, isTrue);
      gravixExplicitRecordingDebugPlatform = PlatformType.android;
      await track().start();
      expect(startArgs()['gravixStartRecordThread'], isTrue);
    });

    test('opted out: the native side only prepares the recorder; the processing options still go', () async {
      GravixAndroidRecorder.startThreadAtCapture = false;
      gravixExplicitRecordingDebugPlatform = PlatformType.android;
      await track().start();
      final args = startArgs();
      expect(args['gravixStartRecordThread'], isFalse);
      expect(args.keys, containsAll(<String>['echoCancellation', 'noiseSuppression', 'autoGainControl']));
    });

    test('iOS: not sent (an Android recorder detail)', () async {
      GravixAndroidRecorder.startThreadAtCapture = false;
      gravixExplicitRecordingDebugPlatform = PlatformType.iOS;
      await track().start();
      expect(startArgs().containsKey('gravixStartRecordThread'), isFalse);
    });
  });
}

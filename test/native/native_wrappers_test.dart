// The Dart wrappers above the `gravix_client` channel must report what the
// native side actually did. 0.3.x shipped with nothing answering the channel on
// phones, and some wrappers still said "done": iOS setDirectAudioOutput
// returned true for a speaker/earpiece switch no native code performed.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  void answer(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(Native.channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() {
    messenger.setMockMethodCallHandler(Native.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('GravixNativeAudioPlatform.setDirectAudioOutput on iOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    Future<bool> select(GravixAudioOutput output) => GravixNativeAudioPlatform().setDirectAudioOutput(output);

    test('asks the native side and returns true only when the route changed', () async {
      answer((_) async => {'applied': true, 'deferred': false, 'route': 'Receiver'});
      expect(await select(GravixAudioOutput.earpiece), isTrue);
      final native = calls.where((c) => c.method == 'setAppleAudioOutput').single;
      expect(native.arguments, {'speaker': false});
    });

    test('a route that did not change (wired headset) is false', () async {
      answer((_) async => {'applied': false, 'deferred': false, 'route': 'Headphones', 'reason': 'routeIs:Headphones'});
      expect(await select(GravixAudioOutput.earpiece), isFalse);
    });

    test('before a call session exists the selection is cached: true', () async {
      answer((_) async => {'applied': false, 'deferred': true, 'reason': 'sessionNotInCall'});
      expect(await select(GravixAudioOutput.speaker), isTrue);
    });

    test('a native error is false, never success', () async {
      answer((_) async => throw PlatformException(code: 'setAppleAudioOutput'));
      expect(await select(GravixAudioOutput.speaker), isFalse);
    });

    test('no native plugin is false (the 0.3.x behaviour claimed true)', () async {
      messenger.setMockMethodCallHandler(Native.channel, null);
      expect(await select(GravixAudioOutput.speaker), isFalse);
    });
  });

  group('explicit recording start (native startLocalRecording)', () {
    test('iOS audio-session trouble falls back to the publish-time start', () async {
      for (final code in ['audioSessionConfigureFailed', 'audioSessionInvalidCategory']) {
        expect(
          await gravixStartExplicitRecording(() async => throw PlatformException(code: code)),
          isFalse,
          reason: code,
        );
      }
    });

    test('a missing microphone permission fails the track as TrackCreateException', () async {
      await expectLater(
        gravixStartExplicitRecording(
          () async =>
              throw PlatformException(code: 'deviceAccessDenied', message: 'Microphone permission is not granted'),
        ),
        throwsA(isA<TrackCreateException>()),
      );
    });

    test('an Android "no audio device module yet" answer still skips, as in 0.3.1', () async {
      expect(
        await gravixStartExplicitRecording(
          () async => throw PlatformException(
            code: 'rejectedPlatformUnavailable',
            message: 'audio device module is unavailable',
          ),
        ),
        isFalse,
      );
    });

    test('through the real channel wrapper: native success starts it', () async {
      answer((_) async => null);
      expect(await gravixStartExplicitRecording(() => Native.startLocalRecording(const {})), isTrue);
      expect(calls.single.method, 'startLocalRecording');
    });
  });

  group('AudioManager Apple-side wrappers', () {
    // Pretend iOS so these go through the channel on any test host (CI is Linux).
    setUp(() => debugLkPlatformOverride = PlatformType.iOS);
    tearDown(() {
      debugLkPlatformOverride = null;
      AudioManager.instance.resetForTest();
    });

    test('getMicrophoneMuteMode maps native names, unknown otherwise', () async {
      answer((_) async => 'inputMixer');
      expect(await AudioManager.instance.getMicrophoneMuteMode(), MicrophoneMuteMode.inputMixer);
      answer((_) async => 'somethingElse');
      expect(await AudioManager.instance.getMicrophoneMuteMode(), MicrophoneMuteMode.unknown);
    });

    test('setMicrophoneMuteMode(unknown) is a no-op; others reach native and fail loudly', () async {
      answer((_) async => null);
      await AudioManager.instance.setMicrophoneMuteMode(MicrophoneMuteMode.unknown);
      expect(calls, isEmpty);
      await AudioManager.instance.setMicrophoneMuteMode(MicrophoneMuteMode.restart);
      expect(calls.single.arguments, {'mode': 'restart'});

      answer((_) async => throw PlatformException(code: 'setMicrophoneMuteMode'));
      await expectLater(
        AudioManager.instance.setMicrophoneMuteMode(MicrophoneMuteMode.voiceProcessing),
        throwsA(isA<PlatformException>()),
      );
    });

    test('setEngineAvailability(none) gates both directions and fails loudly', () async {
      answer((_) async => null);
      await AudioManager.instance.setEngineAvailability(AudioEngineAvailability.none);
      expect(calls.single.arguments, {'isInputAvailable': false, 'isOutputAvailable': false});

      answer((_) async => throw PlatformException(code: 'setEngineAvailability'));
      await expectLater(
        AudioManager.instance.setEngineAvailability(AudioEngineAvailability.defaultAvailability),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('AndroidScreenCapture', () {
    tearDown(AndroidScreenCapture.resetForTest);

    test('consent first, then the foreground service; release stops it once', () async {
      final order = <String>[];
      AndroidScreenCapture.requestPermission = () async {
        order.add('consent');
        return true;
      };
      AndroidScreenCapture.notificationTitle = 'Sharing';
      answer((call) async {
        order.add(call.method);
        return true;
      });

      await AndroidScreenCapture.prepare();
      expect(order, ['consent', 'startScreenCaptureService']);
      expect(calls.first.arguments, {'notificationTitle': 'Sharing'});
      expect(AndroidScreenCapture.isServiceRunning, isTrue);

      await AndroidScreenCapture.release();
      await AndroidScreenCapture.release();
      expect(order, ['consent', 'startScreenCaptureService', 'stopScreenCaptureService']);
      expect(AndroidScreenCapture.isServiceRunning, isFalse);
    });

    test('declined consent never starts the service', () async {
      AndroidScreenCapture.requestPermission = () async => false;
      answer((_) async => true);
      await expectLater(AndroidScreenCapture.prepare(), throwsA(isA<TrackCreateException>()));
      expect(calls, isEmpty);
    });

    test('a service Android refuses surfaces as TrackCreateException', () async {
      AndroidScreenCapture.requestPermission = () async => true;
      answer((_) async => throw PlatformException(code: 'screenCaptureServiceFailed', message: 'SecurityException'));
      await expectLater(AndroidScreenCapture.prepare(), throwsA(isA<TrackCreateException>()));
      expect(AndroidScreenCapture.isServiceRunning, isFalse);
    });

    test('disabled: the app owns consent and the service', () async {
      AndroidScreenCapture.enabled = false;
      var asked = false;
      AndroidScreenCapture.requestPermission = () async => asked = true;
      answer((_) async => true);
      await AndroidScreenCapture.prepare();
      await AndroidScreenCapture.release();
      expect(asked, isFalse);
      expect(calls, isEmpty);
    });
  });
}

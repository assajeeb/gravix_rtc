// Contract tests for the `gravix_client` method channel (lib/src/rtc_core/src/
// support/native.dart). Until the native plugin landed nothing answered this
// channel on Android or iOS, and several wrappers turned that silence into
// "success". These pin, per method: the exact method name + arguments the
// native side (GravixClientPlugin.kt / GravixClientPlugin.swift) is written
// against, what a success looks like, and how each failure is mapped.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/audio_manager.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/broadcast_manager.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native_audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/audio_session.dart';

typedef Handler = Future<Object?> Function(MethodCall call);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  void answer(Handler handler) {
    messenger.setMockMethodCallHandler(Native.channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  void unregistered() => messenger.setMockMethodCallHandler(Native.channel, null);

  Future<Object?> throwing(String code) async => throw PlatformException(code: code, message: code);

  Future<void> deliver(String method, [Object? arguments]) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments));
    await messenger.handlePlatformMessage(Native.channel.name, data, (_) {});
  }

  setUp(calls.clear);
  tearDown(unregistered);

  test('channel name is gravix_client', () {
    expect(Native.channel.name, 'gravix_client');
  });

  group('configureNativeAudio', () {
    test('sends the Apple config plus the automatic/category/force flags', () async {
      answer((_) async => true);
      final ok = await Native.configureAudio(
        NativeAudioConfiguration(
          appleAudioCategory: AppleAudioCategory.playAndRecord,
          appleAudioCategoryOptions: {AppleAudioCategoryOption.allowBluetooth},
          appleAudioMode: AppleAudioMode.voiceChat,
        ),
        automatic: true,
        selectCategoryByEngineState: true,
        forceSpeakerOutput: true,
      );
      expect(ok, isTrue);
      expect(calls.single.method, 'configureNativeAudio');
      expect(calls.single.arguments, {
        'appleAudioCategory': 'playAndRecord',
        'appleAudioCategoryOptions': ['allowBluetooth'],
        'appleAudioMode': 'voiceChat',
        'automatic': true,
        'selectCategoryByEngineState': true,
        'forceSpeakerOutput': true,
      });
    });

    test('a native error is reported as false, not success', () async {
      answer((_) => throwing('configure'));
      expect(await Native.configureAudio(NativeAudioConfiguration()), isFalse);
    });

    test('no plugin is reported as false', () async {
      unregistered();
      expect(await Native.configureAudio(NativeAudioConfiguration()), isFalse);
    });
  });

  group('setAudioProcessingOptions', () {
    test('passes trackId + options and returns the native result map', () async {
      answer((_) async => {'result': true, 'code': 'applied', 'message': ''});
      final response = await Native.setAudioProcessingOptions('TR_1', {'echoCancellation': true});
      expect(response, {'result': true, 'code': 'applied', 'message': ''});
      expect(calls.single.arguments, {'trackId': 'TR_1', 'echoCancellation': true});
    });

    test('missing plugin maps to rejectedPlatformUnavailable', () async {
      unregistered();
      final response = await Native.setAudioProcessingOptions('TR_1', {});
      expect(response['code'], 'rejectedPlatformUnavailable');
      expect(response['result'], isFalse);
    });

    test('Unimplemented maps to rejectedPlatformUnavailable', () async {
      answer((_) => throwing('Unimplemented'));
      expect((await Native.setAudioProcessingOptions('TR_1', {}))['code'], 'rejectedPlatformUnavailable');
    });

    test('any other native error propagates', () async {
      answer((_) => throwing('INVALID_ARGUMENT'));
      await expectLater(
        Native.setAudioProcessingOptions('TR_1', {}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'INVALID_ARGUMENT')),
      );
    });
  });

  group('startLocalRecording', () {
    test('sends the processing options and completes on success', () async {
      answer((_) async => null);
      await Native.startLocalRecording({'noiseSuppression': false});
      expect(calls.single.method, 'startLocalRecording');
      expect(calls.single.arguments, {'noiseSuppression': false});
    });

    test('missing plugin and Unimplemented both throw rejectedPlatformUnavailable', () async {
      unregistered();
      await expectLater(
        Native.startLocalRecording({}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'rejectedPlatformUnavailable')),
      );
      answer((_) => throwing('Unimplemented'));
      await expectLater(
        Native.startLocalRecording({}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'rejectedPlatformUnavailable')),
      );
    });

    test('a native start failure propagates with its own code', () async {
      answer((_) => throwing('deviceAccessDenied'));
      await expectLater(
        Native.startLocalRecording({}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'deviceAccessDenied')),
      );
    });
  });

  test('stopLocalRecording never throws', () async {
    answer((_) => throwing('stopLocalRecording'));
    await Native.stopLocalRecording();
    unregistered();
    await Native.stopLocalRecording();
    answer((_) async => null);
    await Native.stopLocalRecording();
    expect(calls.last.method, 'stopLocalRecording');
  });

  group('setMicrophoneMute', () {
    test('sends {mute}; true only when the native side confirms', () async {
      answer((_) async => true);
      expect(await Native.setMicrophoneMute(true), isTrue);
      expect(calls.single.method, 'setMicrophoneMute');
      expect(calls.single.arguments, {'mute': true});
    });

    test('no audio device module yet (false) / error / no plugin: false, never throws', () async {
      answer((_) async => false);
      expect(await Native.setMicrophoneMute(true), isFalse);
      answer((_) => throwing('setMicrophoneMute'));
      expect(await Native.setMicrophoneMute(true), isFalse);
      unregistered();
      expect(await Native.setMicrophoneMute(false), isFalse);
    });
  });

  group('getAudioProcessingState', () {
    test('returns the native map', () async {
      answer((_) async => {'hasAudioProcessingModule': true});
      expect(await Native.getAudioProcessingState(), {'hasAudioProcessingModule': true});
    });

    test('null / error -> null', () async {
      answer((_) async => null);
      expect(await Native.getAudioProcessingState(), isNull);
      answer((_) => throwing('x'));
      expect(await Native.getAudioProcessingState(), isNull);
    });
  });

  group('Android session', () {
    test('configureAndroidAudioSession forwards the configuration map', () async {
      answer((_) async => null);
      await Native.configureAndroidAudioSession({'androidAudioMode': 'inCommunication', 'manageAudioFocus': true});
      expect(calls.single.method, 'configureAndroidAudioSession');
      expect(calls.single.arguments, {'androidAudioMode': 'inCommunication', 'manageAudioFocus': true});
    });

    test('stopAndroidAudioSession', () async {
      answer((_) async => null);
      await Native.stopAndroidAudioSession();
      expect(calls.single.method, 'stopAndroidAudioSession');
    });

    test('setAndroidSpeakerphoneOn sends enable + force', () async {
      answer((_) async => null);
      await Native.setAndroidSpeakerphoneOn(false, force: true);
      expect(calls.single.method, 'setAndroidSpeakerphoneOn');
      expect(calls.single.arguments, {'enable': false, 'force': true});
    });

    test('errors are logged, not thrown (best-effort session calls)', () async {
      answer((_) => throwing('x'));
      await Native.configureAndroidAudioSession({});
      await Native.stopAndroidAudioSession();
      await Native.setAndroidSpeakerphoneOn(true);
    });
  });

  group('Apple session', () {
    test('deactivateAppleAudioSession', () async {
      answer((_) async => true);
      await Native.deactivateAppleAudioSession();
      expect(calls.single.method, 'deactivateAppleAudioSession');
    });

    test('setAppleAudioSessionAutomaticManagementEnabled sends both flags', () async {
      answer((_) async => true);
      await Native.setAppleAudioSessionAutomaticManagementEnabled(true, sessionActivationEnabled: false);
      expect(calls.single.arguments, {'enabled': true, 'sessionActivationEnabled': false});
    });

    test('errors are logged, not thrown', () async {
      answer((_) => throwing('x'));
      await Native.deactivateAppleAudioSession();
      await Native.setAppleAudioSessionAutomaticManagementEnabled(false);
    });
  });

  group('CallKit coordination', () {
    test('setMicrophoneMuteMode sends the mode and surfaces native errors', () async {
      answer((_) async => null);
      await Native.setMicrophoneMuteMode('inputMixer');
      expect(calls.single.arguments, {'mode': 'inputMixer'});

      answer((_) => throwing('setMicrophoneMuteMode'));
      await expectLater(Native.setMicrophoneMuteMode('restart'), throwsA(isA<PlatformException>()));
    });

    test('getMicrophoneMuteMode returns the native value, null on error', () async {
      answer((_) async => 'voiceProcessing');
      expect(await Native.getMicrophoneMuteMode(), 'voiceProcessing');
      answer((_) => throwing('getMicrophoneMuteMode'));
      expect(await Native.getMicrophoneMuteMode(), isNull);
    });

    test('setEngineAvailability sends both flags and surfaces native errors', () async {
      answer((_) async => null);
      await Native.setEngineAvailability(isInputAvailable: false, isOutputAvailable: true);
      expect(calls.single.arguments, {'isInputAvailable': false, 'isOutputAvailable': true});

      answer((_) => throwing('setEngineAvailability'));
      await expectLater(
        Native.setEngineAvailability(isInputAvailable: true, isOutputAvailable: true),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('visualizer / renderer', () {
    test('startVisualizer sends every option and reports the native bool', () async {
      answer((_) async => true);
      final ok = await Native.startVisualizer(
        'TR_1',
        isCentered: false,
        barCount: 5,
        visualizerId: 'v1',
        smoothTransition: false,
      );
      expect(ok, isTrue);
      expect(calls.single.arguments, {
        'trackId': 'TR_1',
        'isCentered': false,
        'barCount': 5,
        'visualizerId': 'v1',
        'smoothTransition': false,
      });
    });

    test('startVisualizer: native null or error is false, not success', () async {
      answer((_) async => null);
      expect(await Native.startVisualizer('TR_1', visualizerId: 'v1'), isFalse);
      answer((_) => throwing('INVALID_ARGUMENT'));
      expect(await Native.startVisualizer('TR_1', visualizerId: 'v1'), isFalse);
    });

    test('stopVisualizer', () async {
      answer((_) async => true);
      await Native.stopVisualizer('TR_1', visualizerId: 'v1');
      expect(calls.single.arguments, {'trackId': 'TR_1', 'visualizerId': 'v1'});
    });

    test('startAudioRenderer / stopAudioRenderer', () async {
      answer((_) async => true);
      final ok = await Native.startAudioRenderer(
        trackId: 'TR_1',
        rendererId: 'r1',
        format: {'commonFormat': 'int16', 'sampleRate': 48000, 'channels': 1},
      );
      expect(ok, isTrue);
      await Native.stopAudioRenderer(rendererId: 'r1');
      expect(calls.map((c) => c.method), ['startAudioRenderer', 'stopAudioRenderer']);
      expect(calls.last.arguments, {'rendererId': 'r1'});

      answer((_) => throwing('RENDERER_ERROR'));
      expect(await Native.startAudioRenderer(trackId: 'TR_1', rendererId: 'r2', format: const {}), isFalse);
    });
  });

  test('osVersionString', () async {
    answer((_) async => '17.4.1');
    expect(await Native.osVersionString(), '17.4.1');
    answer((_) => throwing('x'));
    expect(await Native.osVersionString(), isNull);
  });

  group('setAppleAudioOutput', () {
    test('parses the native answer', () async {
      answer((_) async => {'applied': true, 'deferred': false, 'route': 'Speaker'});
      final result = await Native.setAppleAudioOutput(speaker: true);
      expect(calls.single.arguments, {'speaker': true});
      expect(result.applied, isTrue);
      expect(result.deferred, isFalse);
      expect(result.route, 'Speaker');
    });

    test('native errors propagate', () async {
      answer((_) => throwing('setAppleAudioOutput'));
      await expectLater(Native.setAppleAudioOutput(speaker: false), throwsA(isA<PlatformException>()));
    });

    test('a non-map answer is an error, not a success', () async {
      answer((_) async => true);
      await expectLater(Native.setAppleAudioOutput(speaker: false), throwsA(isA<PlatformException>()));
    });
  });

  group('Android screen capture service', () {
    test('start forwards the notification text and surfaces a refusal', () async {
      answer((_) async => true);
      await Native.startScreenCaptureService(notificationTitle: 'Sharing', notificationText: 'Live');
      expect(calls.single.method, 'startScreenCaptureService');
      expect(calls.single.arguments, {'notificationTitle': 'Sharing', 'notificationText': 'Live'});

      answer((_) => throwing('screenCaptureServiceFailed'));
      await expectLater(Native.startScreenCaptureService(), throwsA(isA<PlatformException>()));
    });

    test('stop never throws', () async {
      answer((_) => throwing('x'));
      await Native.stopScreenCaptureService();
      unregistered();
      await Native.stopScreenCaptureService();
    });
  });

  group('broadcast (iOS screen share)', () {
    test('requestActivation / requestStop call the native methods', () async {
      answer((_) async => true);
      await BroadcastManager().requestActivation();
      await BroadcastManager().requestStop();
      expect(calls.map((c) => c.method), ['broadcastRequestActivation', 'broadcastRequestStop']);
    });

    test('a missing extension configuration reaches the caller', () async {
      answer((_) => throwing('broadcastExtensionNotConfigured'));
      await expectLater(
        BroadcastManager().requestActivation(),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'broadcastExtensionNotConfigured')),
      );
    });

    test('other failures and a missing plugin are logged only', () async {
      answer((_) => throwing('x'));
      await BroadcastManager().requestActivation();
      unregistered();
      await BroadcastManager().requestActivation();
      await BroadcastManager().requestStop();
    });
  });

  group('native -> Dart callbacks', () {
    test('broadcastStateChanged updates BroadcastManager', () async {
      var notified = 0;
      void listener() => notified++;
      BroadcastManager().addListener(listener);
      addTearDown(() {
        BroadcastManager().removeListener(listener);
        BroadcastManager().broadcastStateChanged(false);
      });

      await deliver('broadcastStateChanged', true);
      expect(BroadcastManager().isBroadcasting, isTrue);
      await deliver('broadcastStateChanged', 'not a bool');
      expect(BroadcastManager().isBroadcasting, isTrue, reason: 'malformed payloads are ignored');
      await deliver('broadcastStateChanged', false);
      expect(BroadcastManager().isBroadcasting, isFalse);
      expect(notified, 2);
    });

    test('onAudioEngineState updates AudioManager', () async {
      addTearDown(AudioManager.instance.resetForTest);
      final states = <AudioEngineState>[];
      final sub = AudioManager.instance.audioEngineStateStream.listen(states.add);
      addTearDown(sub.cancel);

      await deliver('onAudioEngineState', {'isPlayoutEnabled': true, 'isRecordingEnabled': false});
      await pumpEventQueue();
      expect(
        AudioManager.instance.audioEngineState,
        const AudioEngineState(isPlayoutEnabled: true, isRecordingEnabled: false),
      );
      expect(states, hasLength(1));
    });

    test('onAudioRouteChanged is published on appleAudioRouteChanges', () async {
      final changes = <AppleAudioRouteChange>[];
      final sub = Native.appleAudioRouteChanges.listen(changes.add);
      addTearDown(sub.cancel);

      await deliver('onAudioRouteChanged', {
        'reason': 'newDeviceAvailable',
        'outputs': 'BluetoothHFP',
        'speakerReasserted': false,
      });
      await pumpEventQueue();
      expect(changes.single.reason, 'newDeviceAvailable');
      expect(changes.single.outputs, 'BluetoothHFP');
      expect(changes.single.speakerReasserted, isFalse);
    });

    test('unknown callbacks are ignored', () async {
      await deliver('somethingNew', {'a': 1});
    });
  });
}

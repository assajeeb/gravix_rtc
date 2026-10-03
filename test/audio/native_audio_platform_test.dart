// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixNativeAudioPlatform against BOTH audio_session lines the pubspec allows
// (0.1.21+ and 0.2.x). audio_session 0.2 made
// `AndroidAudioManager.getCommunicationDevice()` return a nullable device (null =
// no communication device is set); 0.4.7 read `device.type.name` straight off it,
// which does not compile against 0.2 -- the reason apps had to pin
// audio_session 0.1.x in dependency_overrides. CI runs it under both
// resolutions: `flutter test` (0.2.x) and `flutter test (lower bounds)` (0.1.25).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/audio/gravix_audio_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ryanheise.android_audio_manager');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, dynamic> device({required int type}) => <String, dynamic>{
    'id': 7,
    'productName': 'Redmi Note 11',
    'address': '',
    'isSource': false,
    'isSink': true,
    'sampleRates': <int>[],
    'channelMasks': <int>[],
    'channelIndexMasks': <int>[],
    'channelCounts': <int>[],
    'encodings': <int>[],
    'type': type,
  };

  late Object? Function(MethodCall call) answer;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    answer = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async => answer(call));
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('no communication device set (null from the platform): null, no throw', () async {
    answer = (call) => call.method == 'getCommunicationDevice' ? null : null;
    expect(await GravixNativeAudioPlatform().getCommunicationDeviceType(), isNull);
  });

  test('a communication device: its type name', () async {
    // AudioDeviceInfo.TYPE_BUILTIN_SPEAKER = 2
    answer = (call) => call.method == 'getCommunicationDevice' ? device(type: 2) : null;
    expect(await GravixNativeAudioPlatform().getCommunicationDeviceType(), 'builtInSpeaker');
  });

  test('pre-API-31 device (the platform call throws): null', () async {
    answer = (call) => throw PlatformException(code: 'unsupported');
    expect(await GravixNativeAudioPlatform().getCommunicationDeviceType(), isNull);
  });

  test('not Android: null without a platform call', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var calls = 0;
    answer = (_) {
      calls++;
      return device(type: 2);
    };
    expect(await GravixNativeAudioPlatform().getCommunicationDeviceType(), isNull);
    expect(calls, 0);
  });
}

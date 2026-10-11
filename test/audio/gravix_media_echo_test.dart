// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-10 ECHO investigation: with the Android media profile the field app
// (Pakhi: WebRTC.initialize with the media configuration, bypassVoiceProcessing,
// software AEC3) sent the room's own playout back almost uncancelled (echo
// +5.4/+3.8 dB over the user's voice on an Infinix). The experiment options
// below change WebRTC's audio device module before the first room (low-latency
// playout, the capture source, AEC3 field trials). Off = no platform call at
// all, i.e. exactly the old behaviour.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_media_echo.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Object? reply;

  setUp(() {
    calls = <MethodCall>[];
    reply = <String, Object?>{'lowLatencyPlayout': 'applied', 'captureSource': 'applied', 'fieldTrials': 'applied'};
    debugLkPlatformOverride = PlatformType.android;
    messenger.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      return reply;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Native.channel, null);
    debugLkPlatformOverride = null;
  });

  test('the default tuning is off and makes no platform call', () async {
    const t = GravixMediaEchoTuning();
    expect(t.isOff, isTrue);
    final report = await GravixMediaEcho.apply(t);
    expect(calls, isEmpty);
    expect(report.applied, isFalse);
    expect(report.reason, 'off');
  });

  test('each option alone turns the tuning on', () {
    expect(const GravixMediaEchoTuning(lowLatencyPlayout: true).isOff, isFalse);
    expect(const GravixMediaEchoTuning(lowLatencyPlayout: false).isOff, isFalse);
    expect(const GravixMediaEchoTuning(captureSource: GravixCaptureAudioSource.mic).isOff, isFalse);
    expect(const GravixMediaEchoTuning(aec3FieldTrials: 'WebRTC-Aec3TransparentModeHmm/Enabled/').isOff, isFalse);
  });

  test('a set tuning sends one applyMediaEchoTuning call with exactly the set keys', () async {
    final report = await GravixMediaEcho.apply(
      const GravixMediaEchoTuning(
        lowLatencyPlayout: true,
        captureSource: GravixCaptureAudioSource.mic,
        aec3FieldTrials: 'WebRTC-Aec3TransparentModeHmm/Enabled/',
      ),
    );
    expect(calls.map((c) => c.method), ['applyMediaEchoTuning']);
    expect(calls.single.arguments, <String, Object?>{
      'lowLatencyPlayout': true,
      'captureSource': 'mic',
      'aec3FieldTrials': 'WebRTC-Aec3TransparentModeHmm/Enabled/',
      'keepWarpTrial': false,
    });
    expect(report.applied, isTrue);
    expect(report.native['lowLatencyPlayout'], 'applied');
  });

  test('unset options are not sent (null = leave the module as built)', () async {
    await GravixMediaEcho.apply(
      const GravixMediaEchoTuning(captureSource: GravixCaptureAudioSource.voiceCommunication),
    );
    expect(calls.single.arguments, <String, Object?>{'captureSource': 'voiceCommunication', 'keepWarpTrial': false});
  });

  test('a malformed field-trial string is refused before any platform call', () async {
    for (final bad in ['WebRTC-Aec3TransparentModeHmm', 'A/B', '/B/', 'A//', 'A/B/A/C/']) {
      expect(
        () => GravixMediaEcho.apply(GravixMediaEchoTuning(aec3FieldTrials: bad)),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(calls, isEmpty);
  });

  test('well-formed field-trial strings pass the check', () {
    expect(gravixFieldTrialsValid(''), isTrue);
    expect(gravixFieldTrialsValid('A/B/'), isTrue);
    expect(gravixFieldTrialsValid('A/B/C/D/'), isTrue);
    expect(gravixFieldTrialsValid('A/B/A/B/'), isTrue); // same group twice is allowed by libwebrtc
    expect(gravixFieldTrialsValid('WebRTC-Aec3SuppressorDominantNearendEnrThresholdOverride/0.1/'), isTrue);
  });

  test('not Android: no platform call, reported as unsupported', () async {
    debugLkPlatformOverride = PlatformType.iOS;
    final report = await GravixMediaEcho.apply(const GravixMediaEchoTuning(lowLatencyPlayout: true));
    expect(calls, isEmpty);
    expect(report.applied, isFalse);
    expect(report.reason, 'unsupported');
  });

  test('a native failure is reported, not thrown', () async {
    messenger.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'noAudioDeviceModule', message: 'WebRTC is not initialized');
    });
    final report = await GravixMediaEcho.apply(const GravixMediaEchoTuning(lowLatencyPlayout: true));
    expect(report.applied, isFalse);
    expect(report.reason, contains('noAudioDeviceModule'));
  });

  test('keepWarpTrial is forwarded so the WARP trial survives a field-trial change', () async {
    await GravixMediaEcho.apply(
      const GravixMediaEchoTuning(aec3FieldTrials: 'WebRTC-Aec3TransparentModeHmm/Enabled/', keepWarpTrial: true),
    );
    expect((calls.single.arguments as Map)['keepWarpTrial'], isTrue);
  });
}

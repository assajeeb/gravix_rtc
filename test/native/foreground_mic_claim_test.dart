// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.15 (2026-10-10, field report item 7a): the call service claims the
// `microphone` foreground-service type at start, while the app is visible,
// instead of only when the microphone is published. Android 14+ refuses to ADD
// the type from the background, so a listener who left the screen and then
// took a seat (or unmuted) had no microphone type: Android silenced the
// capture ~5 s later ("App op 27 missing, silencing record").
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/gravix_foreground_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var micGranted = true;

  List<String> typesFor(Map<Object?, Object?>? args) => [
    if (args?['microphone'] == true && micGranted) 'microphone',
    'mediaPlayback',
  ];

  Iterable<MethodCall> serviceCalls() => calls.where((c) => c.method.endsWith('CallService'));
  void lifecycle(AppLifecycleState s) => binding.handleAppLifecycleStateChanged(s);

  setUp(() {
    calls.clear();
    micGranted = true;
    GravixForegroundService.resetForTest();
    GravixForegroundService.stopGrace = Duration.zero;
    debugLkPlatformOverride = PlatformType.android;
    lifecycle(AppLifecycleState.resumed);
    messenger.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map<Object?, Object?>?;
      switch (call.method) {
        case 'startCallService':
        case 'updateCallService':
          return {'types': 0, 'typeNames': typesFor(args), 'error': null};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Native.channel, null);
    GravixForegroundService.resetForTest();
    debugLkPlatformOverride = null;
  });

  test('default options: the start already asks for the microphone type (listener included)', () async {
    GravixForegroundService.defaults = const GravixForegroundServiceOptions(enabled: true);
    await GravixForegroundService.roomConnecting(Object(), null);
    expect(serviceCalls().single.method, 'startCallService');
    expect((serviceCalls().single.arguments as Map)['microphone'], isTrue);
    expect(GravixForegroundService.activeTypes, ['microphone', 'mediaPlayback']);
  });

  test('default options: a later publish from the background needs no type upgrade', () async {
    GravixForegroundService.defaults = const GravixForegroundServiceOptions(enabled: true);
    final room = Object();
    await GravixForegroundService.roomConnecting(room, null);
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    await GravixForegroundService.roomPublished(room, microphone: true);
    await GravixForegroundService.idle();
    expect(serviceCalls().map((c) => c.method), ['startCallService']);
    expect(GravixForegroundService.activeTypes, contains('microphone'));
  });

  test('RECORD_AUDIO granted only later: the type is re-claimed on the next return to the foreground', () async {
    GravixForegroundService.defaults = const GravixForegroundServiceOptions(enabled: true);
    micGranted = false;
    await GravixForegroundService.roomConnecting(Object(), null);
    expect(GravixForegroundService.activeTypes, ['mediaPlayback']);
    micGranted = true;
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.resumed);
    await GravixForegroundService.idle();
    // (each visible lifecycle step may queue one; the native side no-ops
    // when nothing changed)
    expect(serviceCalls().first.method, 'startCallService');
    expect(serviceCalls().skip(1).map((c) => c.method), everyElement('updateCallService'));
    expect(serviceCalls().length, greaterThanOrEqualTo(2));
    expect(GravixForegroundService.activeTypes, contains('microphone'));
  });

  test('claimMicrophoneAtStart: false keeps the pre-0.4.15 start (mediaPlayback only)', () async {
    GravixForegroundService.defaults = const GravixForegroundServiceOptions(
      enabled: true,
      claimMicrophoneAtStart: false,
    );
    await GravixForegroundService.roomConnecting(Object(), null);
    expect((serviceCalls().single.arguments as Map)['microphone'], isFalse);
    expect(GravixForegroundService.activeTypes, ['mediaPlayback']);
  });

  test('options equality / copyWith carry the new field', () {
    const a = GravixForegroundServiceOptions();
    expect(a.copyWith(claimMicrophoneAtStart: false) == a, isFalse);
    expect(a.copyWith(claimMicrophoneAtStart: true), a);
    expect(a.toString(), contains('claimMicrophoneAtStart: true'));
  });
}

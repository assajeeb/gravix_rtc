// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.15 (device run 2026-10-10, Infinix Android 15): the Transsion "Hiber"
// app freezer froze a silent background listener ~3.6 s after Home despite the
// call service, force-released its wake lock, destroyed its sockets, and the
// app dropped from the room ~45 s later. Hiber refuses to freeze while audio
// is in or out ("importantcase is : audio_in"). Opt-in mitigations: a silent
// playback keep-alive while backgrounded in a room with no real playout, a
// "process was frozen" report, and a detection helper. All default off.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_audio_device.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_background_guard.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/gravix_foreground_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final guard = GravixBackgroundGuard.instance;
  late List<MethodCall> calls;
  late Duration mono;
  late DateTime wall;

  void lifecycle(AppLifecycleState s) => binding.handleAppLifecycleStateChanged(s);
  void toBackground() {
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
  }

  void toForeground() {
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.resumed);
  }

  List<Object?> keepAlive() => calls.where((c) => c.method == 'setBackgroundKeepAlive').map((c) {
    return (c.arguments as Map)['active'];
  }).toList();

  setUp(() {
    calls = [];
    mono = Duration.zero;
    wall = DateTime.utc(2026, 10, 10, 6, 17);
    guard.resetForTest();
    GravixForegroundService.resetForTest();
    GravixAudioDevice.options = const GravixAudioDeviceOptions();
    guard.debugMonotonic = () => mono;
    guard.debugWall = () => wall;
    debugLkPlatformOverride = PlatformType.android;
    lifecycle(AppLifecycleState.resumed);
    messenger.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Native.channel, null);
    guard.resetForTest();
    GravixForegroundService.resetForTest();
    GravixAudioDevice.options = const GravixAudioDeviceOptions();
    debugLkPlatformOverride = null;
  });

  group('pure decisions', () {
    test('Transsion detection (manufacturer or brand)', () {
      expect(gravixIsTranssionDevice('INFINIX MOBILITY LIMITED', 'Infinix'), isTrue);
      expect(gravixIsTranssionDevice('TECNO', 'TECNO'), isTrue);
      expect(gravixIsTranssionDevice('itel', 'itel'), isTrue);
      expect(gravixIsTranssionDevice('Transsion', null), isTrue);
      expect(gravixIsTranssionDevice('Xiaomi', 'Redmi'), isFalse);
      expect(gravixIsTranssionDevice(null, null), isFalse);
    });

    test('keep-alive wanted only: option on, in a room, backgrounded, no real playout', () {
      bool w(GravixBackgroundKeepAlive m, {bool t = false, bool room = true, bool bg = true, bool audio = false}) =>
          gravixKeepAliveWanted(mode: m, isTranssion: t, inRoom: room, backgrounded: bg, remoteAudio: audio);
      expect(w(GravixBackgroundKeepAlive.off), isFalse);
      expect(w(GravixBackgroundKeepAlive.on), isTrue);
      expect(w(GravixBackgroundKeepAlive.on, bg: false), isFalse);
      expect(w(GravixBackgroundKeepAlive.on, room: false), isFalse);
      expect(w(GravixBackgroundKeepAlive.on, audio: true), isFalse);
      expect(w(GravixBackgroundKeepAlive.transsionOnly), isFalse);
      expect(w(GravixBackgroundKeepAlive.transsionOnly, t: true), isTrue);
    });

    test('frozen = the monotonic clock advanced far past the timer interval', () {
      const i = Duration(seconds: 2);
      // on time: not frozen
      expect(gravixFrozenFor(monotonicGap: const Duration(milliseconds: 2100), interval: i), isNull);
      // 51 s without a tick while the device was awake (Hiber: "last freeze 51s ago")
      expect(gravixFrozenFor(monotonicGap: const Duration(seconds: 53), interval: i), const Duration(seconds: 51));
      // just under the threshold
      expect(gravixFrozenFor(monotonicGap: const Duration(milliseconds: 4900), interval: i), isNull);
    });
  });

  group('keep-alive (Android)', () {
    test('default off: no channel call, nothing attached', () async {
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      toBackground();
      GravixForegroundService.roomReleased(room);
      expect(keepAlive(), isEmpty);
      expect(guard.attachedRooms, 0);
    });

    test('on: starts when backgrounded in a room without remote audio, stops on return and on leave', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(backgroundKeepAlive: GravixBackgroundKeepAlive.on);
      guard.debugRemoteAudio = false;
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      expect(keepAlive(), isEmpty, reason: 'on screen: nothing to keep alive');
      toBackground();
      expect(keepAlive(), [true]);
      toForeground();
      expect(keepAlive(), [true, false]);
      toBackground();
      GravixForegroundService.roomReleased(room);
      expect(keepAlive(), [true, false, true, false]);
    });

    test('on: real playout (a subscribed remote audio track) needs no keep-alive', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(backgroundKeepAlive: GravixBackgroundKeepAlive.on);
      guard.debugRemoteAudio = true;
      final room = Object();
      guard.attachRoom(room);
      toBackground();
      expect(keepAlive(), isEmpty);
      // the far side stops publishing while we are in the background
      guard.debugRemoteAudio = false;
      guard.refresh();
      expect(keepAlive(), [true]);
      guard.debugRemoteAudio = true;
      guard.refresh();
      expect(keepAlive(), [true, false]);
    });

    test('transsionOnly: only on a Transsion phone', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(
        backgroundKeepAlive: GravixBackgroundKeepAlive.transsionOnly,
      );
      guard.debugRemoteAudio = false;
      guard.debugIsTranssion = false;
      final a = Object();
      guard.attachRoom(a);
      toBackground();
      expect(keepAlive(), isEmpty);
      toForeground();
      guard.detachRoom(a);
      guard.debugIsTranssion = true;
      guard.attachRoom(Object());
      toBackground();
      expect(keepAlive(), [true]);
    });

    test('iOS: never', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      GravixAudioDevice.options = const GravixAudioDeviceOptions(backgroundKeepAlive: GravixBackgroundKeepAlive.on);
      guard.debugRemoteAudio = false;
      guard.attachRoom(Object());
      toBackground();
      expect(keepAlive(), isEmpty);
    });
  });

  group('process freeze report', () {
    test('off (default): no timer, no event', () async {
      final got = <GravixProcessFreezeEvent>[];
      final sub = GravixAudioDevice.processFreezes.listen(got.add);
      guard.attachRoom(Object());
      toBackground();
      expect(guard.freezeTimerRunning, isFalse);
      mono += const Duration(seconds: 60);
      toForeground();
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);
      await sub.cancel();
    });

    test('on: a monotonic gap while backgrounded is reported on the return', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(detectProcessFreeze: true);
      final got = <GravixProcessFreezeEvent>[];
      final sub = GravixAudioDevice.processFreezes.listen(got.add);
      guard.attachRoom(Object());
      toBackground();
      expect(guard.freezeTimerRunning, isTrue);
      // ticks on time: nothing
      for (var i = 0; i < 3; i++) {
        mono += GravixBackgroundGuard.freezeTickInterval;
        wall = wall.add(GravixBackgroundGuard.freezeTickInterval);
        guard.debugTick();
      }
      // frozen 51 s (the device awake: monotonic and wall clock both advance)
      mono += const Duration(seconds: 51);
      wall = wall.add(const Duration(seconds: 51));
      toForeground();
      await Future<void>.delayed(Duration.zero);
      expect(got, hasLength(1));
      // a lower bound: the gap minus one tick interval the timer may have slept anyway
      expect(got.single.frozenFor, const Duration(seconds: 49));
      expect(got.single.wallGap, const Duration(seconds: 51));
      expect(guard.freezeTimerRunning, isFalse);
      await sub.cancel();
    });

    test('device deep sleep (wall clock jumps, monotonic does not) is not a freeze', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(detectProcessFreeze: true);
      final got = <GravixProcessFreezeEvent>[];
      final sub = GravixAudioDevice.processFreezes.listen(got.add);
      guard.attachRoom(Object());
      toBackground();
      mono += GravixBackgroundGuard.freezeTickInterval;
      wall = wall.add(const Duration(minutes: 10));
      guard.debugTick();
      toForeground();
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);
      await sub.cancel();
    });
  });

  test('isAggressiveFreezer: false off Android', () async {
    debugLkPlatformOverride = PlatformType.iOS;
    expect(await GravixAudioDevice.isAggressiveFreezer(), isFalse);
  });

  test('options defaults: all off', () {
    const o = GravixAudioDeviceOptions();
    expect(o.backgroundKeepAlive, GravixBackgroundKeepAlive.off);
    expect(o.detectProcessFreeze, isFalse);
    expect(o.copyWith(detectProcessFreeze: true) == o, isFalse);
  });
}

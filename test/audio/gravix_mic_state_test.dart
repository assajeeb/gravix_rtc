// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.15 (2026-10-10, field report items 7a/7c/7d): the microphone state is
// reported to the app (active / interrupted / blockedInBackground) instead of a
// log line, the session is re-asserted and the capture restarted after an
// interruption, and one speaker/route API sits on the native routing.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_audio_device.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_mic_state.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/gravix_foreground_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final monitor = GravixMicMonitor.instance;
  late List<MethodCall> calls;
  late Map<String, Object?> initialSignals;
  late Map<String, Object?> routes;

  void lifecycle(AppLifecycleState s) => binding.handleAppLifecycleStateChanged(s);

  Future<void> signals(Map<String, Object?> m) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('onMicSignals', m));
    await messenger.handlePlatformMessage(Native.channel.name, data, (_) {});
    await Future<void>.delayed(Duration.zero);
  }

  List<String> methods() => calls.map((c) => c.method).toList();

  setUp(() {
    calls = [];
    initialSignals = {'sdkInt': 34, 'recording': true, 'silenced': false, 'focus': 'gain', 'phoneCall': false};
    routes = {
      'routes': ['speaker', 'earpiece', 'bluetooth'],
      'current': 'bluetooth',
    };
    monitor.resetForTest();
    GravixForegroundService.resetForTest();
    GravixAudioDevice.options = const GravixAudioDeviceOptions();
    GravixMicMonitor.captureStoppedGrace = const Duration(milliseconds: 30);
    GravixMicMonitor.restartCheckDelay = const Duration(milliseconds: 30);
    GravixMicMonitor.restartMinInterval = Duration.zero;
    debugLkPlatformOverride = PlatformType.android;
    lifecycle(AppLifecycleState.resumed);
    messenger.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'startMicMonitor':
          return initialSignals;
        case 'getAudioRoutes':
          return routes;
        case 'setAudioRoute':
          return {'applied': true, 'current': (call.arguments as Map)['route']};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Native.channel, null);
    monitor.resetForTest();
    GravixForegroundService.resetForTest();
    GravixAudioDevice.options = const GravixAudioDeviceOptions();
    debugLkPlatformOverride = null;
  });

  group('gravixClassifyMic', () {
    (GravixMicState, GravixMicStateReason) c(GravixMicSignals s) => gravixClassifyMic(s);

    test('no published, unmuted mic -> idle whatever else happens', () {
      expect(c(const GravixMicSignals(phoneCall: true, silenced: true)), (
        GravixMicState.idle,
        GravixMicStateReason.none,
      ));
    });

    test('table', () {
      const w = GravixMicSignals(micWanted: true, recording: true);
      expect(c(w), (GravixMicState.active, GravixMicStateReason.none));
      expect(c(w.copyWith(phoneCall: true, silenced: true)), (
        GravixMicState.interrupted,
        GravixMicStateReason.phoneCall,
      ));
      expect(c(w.copyWith(sessionInterrupted: true)), (
        GravixMicState.interrupted,
        GravixMicStateReason.sessionInterrupted,
      ));
      expect(c(w.copyWith(backgrounded: true, micTypeMissing: true)), (
        GravixMicState.blockedInBackground,
        GravixMicStateReason.backgroundWithoutMicrophoneType,
      ));
      // the type alone does not block a visible app
      expect(c(w.copyWith(micTypeMissing: true)), (GravixMicState.active, GravixMicStateReason.none));
      expect(c(w.copyWith(silenced: true)), (GravixMicState.interrupted, GravixMicStateReason.silencedBySystem));
      expect(c(w.copyWith(silenced: true, backgrounded: true)), (
        GravixMicState.blockedInBackground,
        GravixMicStateReason.silencedInBackground,
      ));
      // a background silence not yet lifted on the return to the foreground
      expect(c(w.copyWith(silenced: true, silencedSinceBackground: true)), (
        GravixMicState.blockedInBackground,
        GravixMicStateReason.silencedInBackground,
      ));
      expect(c(w.copyWith(focusLossTransient: true)), (
        GravixMicState.interrupted,
        GravixMicStateReason.audioFocusLoss,
      ));
      expect(c(w.copyWith(recording: () => false)), (GravixMicState.interrupted, GravixMicStateReason.captureStopped));
      // unknown recording (iOS, or not confirmed yet) is not "stopped"
      expect(c(w.copyWith(recording: () => null)), (GravixMicState.active, GravixMicStateReason.none));
    });
  });

  group('GravixMicMonitor', () {
    test('runs only while a room is attached', () async {
      final room = Object();
      GravixForegroundService.defaults = const GravixForegroundServiceOptions(); // service disabled
      await GravixForegroundService.roomConnecting(room, null);
      expect(monitor.attachedRooms, 1);
      expect(methods(), ['startMicMonitor']);
      GravixForegroundService.roomReleased(room);
      expect(monitor.attachedRooms, 0);
      expect(methods(), ['startMicMonitor', 'stopMicMonitor']);
      expect(GravixAudioDevice.micState.state, GravixMicState.idle);
    });

    test('Android 14, no microphone service type: backgrounded -> blockedInBackground', () async {
      final seen = <GravixMicStateEvent>[];
      final sub = GravixAudioDevice.micStateChanges.listen(seen.add);
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.paused);
      expect(GravixAudioDevice.micState.state, GravixMicState.blockedInBackground);
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.backgroundWithoutMicrophoneType);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      await Future<void>.delayed(Duration.zero);
      // back on screen after a background block: nothing reprogrammed the
      // session, so it is NOT re-activated (an audible flip mid-playout)
      expect(methods(), isNot(contains('reassertAudioSession')));
      expect(seen.map((e) => e.state), [
        GravixMicState.active,
        GravixMicState.blockedInBackground,
        GravixMicState.active,
      ]);
      await sub.cancel();
    });

    // Device run A4 (Infinix, 2026-10-10): without the service type, Android
    // silences the capture in the background. On the return to the foreground
    // the lifecycle flips "backgrounded" off a few ms before the native
    // un-silence signal, and the stale silence read as a foreground
    // silencedBySystem: a spurious "interrupted" and a re-assert (an audible
    // mode 0 -> 3 flip).
    test('a background silence still pending on resume is not a foreground interruption', () async {
      final seen = <GravixMicStateEvent>[];
      final sub = GravixAudioDevice.micStateChanges.listen(seen.add);
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.paused);
      expect(GravixAudioDevice.micState.state, GravixMicState.blockedInBackground);
      // ~5 s later: App op 27 silences the capture
      await signals({'sdkInt': 35, 'recording': true, 'silenced': true, 'focus': 'gain', 'mode': 3});
      // back on screen; the native un-silence arrives after the lifecycle
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      expect(GravixAudioDevice.micState.state, isNot(GravixMicState.interrupted));
      await signals({'sdkInt': 35, 'recording': true, 'silenced': false, 'focus': 'gain', 'mode': 3});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      expect(seen.map((e) => e.state), isNot(contains(GravixMicState.interrupted)));
      expect(methods(), isNot(contains('reassertAudioSession')));
      await sub.cancel();
    });

    test('a silence that starts on screen is still a foreground interruption (and re-asserts)', () async {
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await signals({'sdkInt': 35, 'recording': true, 'silenced': true});
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.silencedBySystem);
      // into the background and back while it lasts: still the same foreground cause
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.paused);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.silencedBySystem);
      await signals({'sdkInt': 35, 'recording': true, 'silenced': false});
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      expect(methods(), contains('reassertAudioSession'));
    });

    test('with the microphone service type, the background is fine', () async {
      GravixForegroundService.defaults = const GravixForegroundServiceOptions(enabled: true);
      messenger.setMockMethodCallHandler(Native.channel, (call) async {
        calls.add(call);
        if (call.method == 'startCallService') {
          return {
            'types': 0,
            'typeNames': ['microphone', 'mediaPlayback'],
          };
        }
        if (call.method == 'startMicMonitor') return initialSignals;
        return null;
      });
      monitor.debugMicWanted = true;
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      await GravixForegroundService.idle();
      await Future<void>.delayed(Duration.zero);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.paused);
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
    });

    test('phone call: interrupted, then the session is re-asserted and a dead recorder restarted', () async {
      var restarts = 0;
      monitor.debugRestartCapture = () async => restarts++;
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await signals({'sdkInt': 34, 'recording': true, 'silenced': true, 'phoneCall': true, 'focus': 'lossTransient'});
      expect(GravixAudioDevice.micState.state, GravixMicState.interrupted);
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.phoneCall);
      expect(methods(), isNot(contains('reassertAudioSession')));
      // the call ends; the recorder did not survive it
      await signals({'sdkInt': 34, 'recording': false, 'silenced': false, 'phoneCall': false, 'focus': 'gain'});
      expect(methods(), contains('reassertAudioSession'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.captureStopped);
      expect(restarts, 1);
    });

    test('interruption ended and the recorder resumed on its own: no capture restart', () async {
      var restarts = 0;
      monitor.debugRestartCapture = () async => restarts++;
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await signals({'sdkInt': 34, 'recording': true, 'silenced': true});
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.silencedBySystem);
      await signals({'sdkInt': 34, 'recording': true, 'silenced': false});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      expect(methods(), contains('reassertAudioSession'));
      expect(restarts, 0);
    });

    test('a ducking focus request leaves the microphone active', () async {
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await signals({'sdkInt': 34, 'recording': true, 'focus': 'lossTransientCanDuck'});
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      await signals({'sdkInt': 34, 'recording': true, 'focus': 'lossTransient'});
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.audioFocusLoss);
    });

    test('recoverMicAfterInterruption: false = report only (pre-0.4.15 behaviour)', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(recoverMicAfterInterruption: false);
      var restarts = 0;
      monitor.debugRestartCapture = () async => restarts++;
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      expect(calls.firstWhere((c) => c.method == 'startMicMonitor').arguments, {'recoverAfterInterruption': false});
      await signals({'sdkInt': 34, 'recording': true, 'phoneCall': true});
      await signals({'sdkInt': 34, 'recording': false, 'phoneCall': false});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.captureStopped);
      expect(methods(), isNot(contains('reassertAudioSession')));
      expect(restarts, 0);
    });

    test('a short "not recording" right after publish is not reported', () async {
      GravixMicMonitor.captureStoppedGrace = const Duration(seconds: 5);
      initialSignals = {'sdkInt': 34, 'recording': false};
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
    });

    test('iOS: session interruption', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await signals({'sessionInterrupted': true});
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.sessionInterrupted);
      await signals({'sessionInterrupted': false});
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      expect(methods(), contains('reassertAudioSession'));
    });

    test('micStateMonitoring: false = nothing runs per room (pre-0.4.15)', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(micStateMonitoring: false);
      monitor.debugMicWanted = true;
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      GravixForegroundService.roomReleased(room);
      expect(monitor.attachedRooms, 0);
      expect(calls, isEmpty);
      expect(GravixAudioDevice.micState.state, GravixMicState.idle);
    });

    test('web/desktop: nothing attaches', () async {
      debugLkPlatformOverride = PlatformType.macOS;
      monitor.attachRoom(Object());
      expect(monitor.attachedRooms, 0);
      expect(calls, isEmpty);
    });
  });

  group('Bluetooth chatroom (Android, opt-in)', () {
    test('off (default): never told to native', () async {
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      expect(methods(), isNot(contains('setBluetoothChatroom')));
    });

    test('on: follows the microphone, and off again on leave', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(bluetoothChatroom: true);
      final args = <Object?>[];
      messenger.setMockMethodCallHandler(Native.channel, (call) async {
        calls.add(call);
        if (call.method == 'setBluetoothChatroom') args.add(call.arguments);
        if (call.method == 'startMicMonitor') return initialSignals;
        return null;
      });
      monitor.debugMicWanted = false;
      final room = Object();
      monitor.attachRoom(room);
      monitor.debugMicWanted = true;
      monitor.refresh();
      monitor.debugMicWanted = false;
      monitor.refresh();
      monitor.debugMicWanted = true;
      monitor.refresh();
      monitor.detachRoom(room);
      await Future<void>.delayed(Duration.zero);
      // (the first {enabled: true, micActive: false} went out when the option
      // was set, before this handler)
      expect(args, [
        {'enabled': true, 'micActive': true},
        {'enabled': true, 'micActive': false},
        {'enabled': true, 'micActive': true},
        {'enabled': true, 'micActive': false},
      ]);
    });
  });

  group('GravixAudioDevice routes', () {
    test('getAudioRoutes parses the native answer', () async {
      final info = await GravixAudioDevice.getAudioRoutes();
      expect(info.current, GravixAudioRoute.bluetooth);
      expect(info.available, [GravixAudioRoute.speaker, GravixAudioRoute.earpiece, GravixAudioRoute.bluetooth]);
      expect(await GravixAudioDevice.isSpeakerphoneEnabled(), isFalse);
    });

    test('setEnableSpeakerphone / setAudioRoute / clearAudioRoute send the route', () async {
      expect(await GravixAudioDevice.setEnableSpeakerphone(true), isTrue);
      expect(await GravixAudioDevice.setEnableSpeakerphone(false), isTrue);
      expect(await GravixAudioDevice.setAudioRoute(GravixAudioRoute.earpiece), isTrue);
      expect(await GravixAudioDevice.clearAudioRoute(), isTrue);
      expect(calls.map((c) => (c.arguments as Map)['route']), ['speaker', 'speakerOff', 'earpiece', null]);
    });

    test('iOS: the cached session policy follows the selection', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      await GravixAudioDevice.setAudioRoute(GravixAudioRoute.earpiece);
      expect(methods(), ['configureNativeAudio', 'setAudioRoute']);
      expect((calls.first.arguments as Map)['appleAudioMode'], 'voiceChat');
      await GravixAudioDevice.setEnableSpeakerphone(true);
      expect((calls[2].arguments as Map)['forceSpeakerOutput'], isTrue);
    });

    test('a declined selection is false', () async {
      messenger.setMockMethodCallHandler(Native.channel, (call) async => {'applied': false, 'reason': 'mediaMode'});
      expect(await GravixAudioDevice.setAudioRoute(GravixAudioRoute.earpiece), isFalse);
    });

    test('onAudioRouteChanged delivers native changes', () async {
      final got = <GravixAudioRouteInfo>[];
      final sub = GravixAudioDevice.onAudioRouteChanged.listen(got.add);
      final data = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onAudioRoutesChanged', {
          'routes': ['speaker', 'wiredHeadset'],
          'current': 'wiredHeadset',
          'reason': 'deviceAdded',
        }),
      );
      await messenger.handlePlatformMessage(Native.channel.name, data, (_) {});
      await Future<void>.delayed(Duration.zero);
      expect(got.single.current, GravixAudioRoute.wiredHeadset);
      expect(got.single.reason, 'deviceAdded');
      await sub.cancel();
    });

    test('not mobile: false / empty, no channel call', () async {
      debugLkPlatformOverride = PlatformType.macOS;
      expect(await GravixAudioDevice.setEnableSpeakerphone(true), isFalse);
      expect((await GravixAudioDevice.getAudioRoutes()).available, isEmpty);
      expect(calls, isEmpty);
    });

    test('options defaults', () {
      const o = GravixAudioDeviceOptions();
      expect(o.recoverMicAfterInterruption, isTrue);
      expect(o.bluetoothChatroom, isFalse);
      expect(o.copyWith(bluetoothChatroom: true) == o, isFalse);
    });
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixForegroundService (2026-10-06): the Android call foreground service
// that keeps the mic, the room playback and room music alive in the
// background. Disabled by default = no channel traffic at all; enabled = start
// at connect (mediaPlayback), microphone on the mic publish, stop when the last
// room lets go.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/join/gravix_rejoin_policy.dart';
import 'package:gravix_rtc/src/noise/noise.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/gravix_foreground_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart' show DisconnectReason;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  // what the native side reports for the next start/update
  var micGranted = true;
  String? updateError;

  List<String> typesFor(Map<Object?, Object?>? args, {bool? mic}) => [
    if ((mic ?? args?['microphone'] == true) && micGranted) 'microphone',
    'mediaPlayback',
  ];

  Iterable<MethodCall> serviceCalls() => calls.where((c) => c.method.endsWith('CallService'));
  List<String> methods() => serviceCalls().map((c) => c.method).toList();

  Future<void> deliver(String method) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method));
    await messenger.handlePlatformMessage(Native.channel.name, data, (_) {});
  }

  void lifecycle(AppLifecycleState s) => binding.handleAppLifecycleStateChanged(s);

  setUp(() {
    calls.clear();
    micGranted = true;
    updateError = null;
    GravixForegroundService.resetForTest();
    GravixForegroundService.stopGrace = Duration.zero;
    debugLkPlatformOverride = PlatformType.android;
    lifecycle(AppLifecycleState.resumed);
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
    messenger.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map<Object?, Object?>?;
      switch (call.method) {
        case 'startCallService':
          return {'types': 0, 'typeNames': typesFor(args), 'error': null};
        case 'updateCallService':
          final mic = updateError == null && args?['microphone'] == true;
          return {'types': 0, 'typeNames': typesFor(args, mic: mic), 'error': updateError};
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

  group('disabled (default)', () {
    test('defaults are off', () {
      expect(GravixForegroundService.defaults.enabled, isFalse);
      expect(const GravixForegroundServiceOptions().showLeaveAction, isFalse);
      expect(const GravixForegroundServiceOptions().includeCamera, isFalse);
      // 0.4.15: on by default; only matters once the service is enabled
      expect(const GravixForegroundServiceOptions().claimMicrophoneAtStart, isTrue);
    });

    test('room hooks make no channel call and install no lifecycle observer', () async {
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      await GravixForegroundService.roomPublished(room, microphone: true, camera: true);
      GravixForegroundService.roomReleased(room);
      GravixForegroundService.addBackgroundSink(room, (_) {});
      GravixForegroundService.removeBackgroundSink(room);
      await GravixForegroundService.idle();
      expect(serviceCalls(), isEmpty);
      expect(GravixForegroundService.isRunning, isFalse);
      expect(GravixForegroundService.lifecycleObserverInstalled, isFalse);
      expect(GravixForegroundService.roomHolds, 0);
    });

    test('Room.connect (failing) with the default options: no service call', () async {
      final room = _failingRoom(const RoomOptions());
      await expectLater(room.connect('wss://sfu.example', 'tok'), throwsA(anything));
      await GravixForegroundService.idle();
      expect(serviceCalls(), isEmpty);
      await room.dispose();
    });

    test('iOS / not Android: unsupported, every call a no-op', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      GravixForegroundService.defaults = const GravixForegroundServiceOptions(enabled: true);
      expect(GravixForegroundService.isSupported, isFalse);
      expect(await GravixForegroundService.start(micPublished: true), isFalse);
      await GravixForegroundService.roomConnecting(Object(), null);
      await GravixForegroundService.stop();
      expect(serviceCalls(), isEmpty);
    });
  });

  group('enabled', () {
    setUp(() {
      GravixForegroundService.defaults = const GravixForegroundServiceOptions(
        enabled: true,
        notificationTitle: 'Live room',
        notificationText: 'Tap to return',
        showLeaveAction: true,
        // these tests pin the pre-0.4.15 flow (microphone added on publish);
        // the default claim-at-start is covered in foreground_mic_claim_test.dart
        claimMicrophoneAtStart: false,
      );
    });

    test('a listener: start with mediaPlayback only', () async {
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      expect(methods(), ['startCallService']);
      expect(serviceCalls().single.arguments, {
        'notificationTitle': 'Live room',
        'notificationText': 'Tap to return',
        'showLeaveAction': true,
        'microphone': false,
        'camera': false,
      });
      expect(GravixForegroundService.isRunning, isTrue);
      expect(GravixForegroundService.activeTypes, ['mediaPlayback']);
    });

    test('start -> mic publish upgrades to microphone -> release stops', () async {
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      await GravixForegroundService.roomPublished(room, microphone: true);
      // a republish (DTX/RED) does not repeat the update
      await GravixForegroundService.roomPublished(room, microphone: true);
      expect(methods(), ['startCallService', 'updateCallService']);
      expect(serviceCalls().last.arguments, {'microphone': true, 'camera': false});
      expect(GravixForegroundService.activeTypes, ['microphone', 'mediaPlayback']);
      GravixForegroundService.roomReleased(room);
      await GravixForegroundService.idle();
      expect(methods(), ['startCallService', 'updateCallService', 'stopCallService']);
      expect(GravixForegroundService.isRunning, isFalse);
    });

    test('camera only with includeCamera', () async {
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      await GravixForegroundService.roomPublished(room, camera: true);
      expect(methods(), ['startCallService']);
      final room2 = Object();
      await GravixForegroundService.roomConnecting(
        room2,
        const GravixForegroundServiceOptions(enabled: true, includeCamera: true, claimMicrophoneAtStart: false),
      );
      await GravixForegroundService.roomPublished(room2, camera: true);
      expect(serviceCalls().last.arguments, {'microphone': false, 'camera': true});
    });

    test('a per-room override can disable it', () async {
      await GravixForegroundService.roomConnecting(Object(), const GravixForegroundServiceOptions());
      expect(serviceCalls(), isEmpty);
    });

    test('two rooms: the service stops only when the last one lets go', () async {
      final a = Object();
      final b = Object();
      await GravixForegroundService.roomConnecting(a, null);
      await GravixForegroundService.roomConnecting(b, null);
      GravixForegroundService.roomReleased(a);
      await GravixForegroundService.idle();
      expect(methods().where((m) => m == 'stopCallService'), isEmpty);
      GravixForegroundService.roomReleased(b);
      await GravixForegroundService.idle();
      expect(methods().last, 'stopCallService');
    });

    test('a room replaced within the grace keeps the service (no stop/start)', () async {
      GravixForegroundService.stopGrace = const Duration(milliseconds: 200);
      final a = Object();
      await GravixForegroundService.roomConnecting(a, null);
      GravixForegroundService.roomReleased(a);
      await GravixForegroundService.roomConnecting(Object(), null);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(methods().where((m) => m == 'stopCallService'), isEmpty);
      expect(GravixForegroundService.isRunning, isTrue);
    });

    // 2026-10-21 (background mic complaints): a viewer's rejoin backoff (1-8 s)
    // outlasted the 3 s stop grace; the rejoin then had to start the
    // microphone-type service from the background (Android 14+ refuses: mic
    // and playback dead until the app was reopened).
    test('a pending rejoin holds the service through its whole backoff; a give-up releases it', () async {
      GravixForegroundService.stopGrace = const Duration(milliseconds: 100);
      final old = Object();
      final next = Object();
      var joins = 0;
      final policy = GravixRejoinPolicy(
        rejoin: () async {
          joins++;
          if (joins == 1) return false; // the first attempt fails: the backoff goes on
          await GravixForegroundService.roomConnecting(next, null);
          return true;
        },
        liveOn: () => true,
        backoff: const [Duration(milliseconds: 250), Duration(milliseconds: 250)],
      );
      await GravixForegroundService.roomConnecting(old, null);
      lifecycle(AppLifecycleState.paused); // the viewer is in the background
      GravixForegroundService.roomReleased(old);
      expect(policy.sessionEnded(DisconnectReason.signalClose), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700)); // two attempts, far past the grace
      await GravixForegroundService.idle();
      expect(joins, 2);
      expect(methods().where((m) => m == 'stopCallService'), isEmpty, reason: 'no stop during the incident');
      expect(methods().where((m) => m == 'startCallService'), hasLength(1), reason: 'no restart from the background');
      expect(GravixForegroundService.isRunning, isTrue);
      expect(GravixForegroundService.roomHolds, 1, reason: 'the new room holds it, the incident let go');
      // the new session ends, every rejoin fails: the give-up releases it
      final gaveUp = GravixRejoinPolicy(
        rejoin: () async => false,
        liveOn: () => true,
        backoff: const [Duration(milliseconds: 150)],
      );
      GravixForegroundService.roomReleased(next);
      expect(gaveUp.sessionEnded(DisconnectReason.signalClose), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(GravixForegroundService.roomHolds, 1, reason: 'held while the rejoin is pending');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await GravixForegroundService.idle();
      expect(GravixForegroundService.roomHolds, 0);
      expect(methods().last, 'stopCallService');
      policy.dispose();
      gaveUp.dispose();
      lifecycle(AppLifecycleState.resumed);
    });

    test('a disposed rejoin (the screen closed) releases its hold', () async {
      GravixForegroundService.stopGrace = const Duration(milliseconds: 100);
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      final policy = GravixRejoinPolicy(
        rejoin: () async => true,
        liveOn: () => true,
        backoff: const [Duration(seconds: 5)],
      );
      GravixForegroundService.roomReleased(room);
      expect(policy.sessionEnded(DisconnectReason.signalClose), isTrue);
      expect(GravixForegroundService.roomHolds, 1);
      policy.dispose();
      expect(GravixForegroundService.roomHolds, 0);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await GravixForegroundService.idle();
      expect(methods().last, 'stopCallService');
    });

    test('mic upgrade from the background is deferred and replayed on resume', () async {
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.paused);
      await GravixForegroundService.roomPublished(room, microphone: true);
      expect(methods(), ['startCallService']);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.inactive);
      await GravixForegroundService.idle();
      expect(methods(), ['startCallService', 'updateCallService']);
      expect(GravixForegroundService.activeTypes, contains('microphone'));
    });

    test('a refused update is retried on the next visible moment', () async {
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      updateError = 'SecurityException: not allowed';
      await GravixForegroundService.roomPublished(room, microphone: true);
      expect(GravixForegroundService.activeTypes, ['mediaPlayback']);
      updateError = null;
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      await GravixForegroundService.idle();
      expect(methods().where((m) => m == 'updateCallService').length, greaterThanOrEqualTo(2));
      expect(GravixForegroundService.activeTypes, contains('microphone'));
    });

    test('mic publish without RECORD_AUDIO: stays mediaPlayback', () async {
      micGranted = false;
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      await GravixForegroundService.roomPublished(room, microphone: true);
      expect(GravixForegroundService.activeTypes, ['mediaPlayback']);
    });

    test('the lifecycle observer exists only while in use, and forwards background changes', () async {
      expect(GravixForegroundService.lifecycleObserverInstalled, isFalse);
      final seen = <bool>[];
      final owner = Object();
      GravixForegroundService.addBackgroundSink(owner, seen.add);
      expect(GravixForegroundService.lifecycleObserverInstalled, isTrue);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.paused);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      expect(seen, [true, false]);
      GravixForegroundService.removeBackgroundSink(owner);
      expect(GravixForegroundService.lifecycleObserverInstalled, isFalse);
      // the observer never touches the service by itself
      expect(serviceCalls(), isEmpty);
    });

    test('Room.connect starts it before the join; a failed connect releases it', () async {
      final room = _failingRoom(const RoomOptions());
      await expectLater(room.connect('wss://sfu.example', 'tok'), throwsA(anything));
      await GravixForegroundService.idle();
      expect(methods(), ['startCallService', 'stopCallService']);
      await room.dispose();
    });

    test('Room.connect starts the service before it waits for the noise suppression setup', () async {
      final nsGate = Completer<void>();
      final seen = <String>[];
      messenger.setMockMethodCallHandler(Native.channel, (call) async {
        seen.add(call.method);
        calls.add(call);
        switch (call.method) {
          case 'startCallService':
            return {'types': 0, 'typeNames': typesFor(call.arguments as Map<Object?, Object?>?), 'error': null};
          case 'nsDeviceFacts':
          case 'nsConfigure':
            await nsGate.future; // a slow native NS setup
            return null;
          default:
            return null;
        }
      });
      // a fresh (non-identical) options object: the controller configures again
      final room = _failingRoom(
        RoomOptions(noiseSuppression: GravixNoiseSuppressionOptions(mode: GravixNoiseSuppressionMode.standard)),
      );
      final connecting = room.connect('wss://sfu.example', 'tok');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, contains('startCallService'), reason: 'started while the NS setup still waits: $seen');
      expect(seen.any((m) => m.startsWith('ns')), isTrue, reason: 'the NS setup is under way and still waiting');
      nsGate.complete();
      await expectLater(connecting, throwsA(anything));
      await room.dispose();
    });

    test('RoomOptions.foregroundService overrides the defaults', () async {
      final room = _failingRoom(const RoomOptions(foregroundService: GravixForegroundServiceOptions()));
      await expectLater(room.connect('wss://sfu.example', 'tok'), throwsA(anything));
      await GravixForegroundService.idle();
      expect(serviceCalls(), isEmpty);
      await room.dispose();
    });

    test('native "stopped" (swiped from Recents) clears isRunning; a start refused is reported', () async {
      await GravixForegroundService.roomConnecting(Object(), null);
      expect(GravixForegroundService.isRunning, isTrue);
      await deliver('callServiceStopped');
      expect(GravixForegroundService.isRunning, isFalse);
    });
  });

  group('manual API', () {
    test('start/update/stop work without enabling the defaults', () async {
      expect(await GravixForegroundService.start(micPublished: false), isTrue);
      expect(await GravixForegroundService.update(micPublished: true), isTrue);
      await GravixForegroundService.stop();
      expect(methods(), ['startCallService', 'updateCallService', 'stopCallService']);
      expect(GravixForegroundService.isRunning, isFalse);
    });

    test('a native refusal is false, not an exception', () async {
      messenger.setMockMethodCallHandler(Native.channel, (call) async {
        calls.add(call);
        throw PlatformException(code: 'callServiceFailed', message: 'ForegroundServiceStartNotAllowedException');
      });
      expect(await GravixForegroundService.start(), isFalse);
      expect(GravixForegroundService.isRunning, isFalse);
    });

    test('no plugin (MissingPluginException) is false', () async {
      messenger.setMockMethodCallHandler(Native.channel, null);
      expect(await GravixForegroundService.start(), isFalse);
    });

    test('stop() ends automatic holds too', () async {
      GravixForegroundService.defaults = const GravixForegroundServiceOptions(enabled: true);
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      await GravixForegroundService.stop();
      expect(GravixForegroundService.roomHolds, 0);
      // the room's later publish/release do nothing
      await GravixForegroundService.roomPublished(room, microphone: true);
      GravixForegroundService.roomReleased(room);
      await GravixForegroundService.idle();
      expect(methods(), ['startCallService', 'stopCallService']);
    });
  });

  test('leaveRequests: the notification action reaches Dart', () async {
    final got = <void>[];
    final sub = GravixForegroundService.leaveRequests.listen(got.add);
    await GravixForegroundService.start();
    await deliver('callServiceLeaveRequested');
    await Future<void>.delayed(Duration.zero);
    expect(got.length, 1);
    await sub.cancel();
  });
}

/// A Room whose signalling connection fails at once.
Room _failingRoom(RoomOptions options) {
  final sc = SignalClient((uri, {options, headers, networkOptions, preconnected}) async {
    throw Exception('no network in tests');
  });
  final engine = Engine(connectOptions: const ConnectOptions(), roomOptions: options, signalClient: sc);
  return Room(roomOptions: options, engine: engine);
}

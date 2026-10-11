// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-10, device run E (Infinix, Android 15, warm joins): fix/mic-audio
// joined ~250 ms slower than main; audioSessionEnd -> wsConnectStart went from
// ~13 ms to 263-402 ms. The mic monitor's native start ran AudioManager calls
// on the main thread while the audio-switch thread was changing the audio mode,
// and every platform reply the join awaited queued behind it. The native side
// is now off the main thread; this pins the Dart side: the join must reach the
// signalling connect even if the mic monitor or the call service never answer.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_mic_state.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/gravix_foreground_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const hanging = {
    'startMicMonitor',
    'stopMicMonitor',
    'startCallService',
    'updateCallService',
    'reassertAudioSession',
  };
  late List<String> order;

  setUp(() {
    order = [];
    debugLkPlatformOverride = PlatformType.android;
    GravixMicMonitor.instance.resetForTest();
    GravixForegroundService.resetForTest();
    GravixForegroundService.defaults = const GravixForegroundServiceOptions(enabled: true); // claim at start
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
    messenger.setMockMethodCallHandler(Native.channel, (call) {
      order.add(call.method);
      // the native side never answers these: a join that awaits one hangs
      if (hanging.contains(call.method)) return Completer<Object?>().future;
      return Future<Object?>.value(null);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Native.channel, null);
    GravixMicMonitor.instance.resetForTest();
    GravixForegroundService.resetForTest();
    debugLkPlatformOverride = null;
  });

  test('Room.connect reaches the signalling connect while the mic monitor / call service hang', () async {
    final sc = SignalClient((uri, {options, headers, networkOptions, preconnected}) async {
      order.add('wsConnect');
      throw Exception('no network in tests');
    });
    const roomOptions = RoomOptions();
    final engine = Engine(connectOptions: const ConnectOptions(), roomOptions: roomOptions, signalClient: sc);
    final room = Room(roomOptions: roomOptions, engine: engine);
    await expectLater(
      room.connect('wss://sfu.example', 'tok').timeout(const Duration(seconds: 5)),
      throwsA(isNot(isA<TimeoutException>())),
    );
    expect(order, contains('startMicMonitor'));
    expect(order, contains('wsConnect'));
    // the monitor was started before the signalling connect, and not waited for
    expect(order.indexOf('startMicMonitor'), lessThan(order.indexOf('wsConnect')));
    await room.dispose();
  });
}

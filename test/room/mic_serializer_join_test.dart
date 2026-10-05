// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field review 2026-09-30 (0.4.3/0.4.4): the join's own first mic enable and the
// audio-interruption recovery called the core directly, beside the toggle
// serializer; with the first enable blocked (a permission dialog that ends in a
// denial) a setMicEnabled(false) never returned. Now all three go through one
// worker, and a mute with nothing live returns at once.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<bool> applied;
  late Map<bool, Completer<void>> gates;
  late int inFlight, maxInFlight;

  setUp(() {
    applied = <bool>[];
    gates = {};
    inFlight = 0;
    maxInFlight = 0;
    GravixAudioRouting.v2 = false;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('com.gravitycompile.gravix_rtc/music'), (call) async => true);
    m.setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);
    for (final name in const ['com.ryanheise.android_audio_manager', 'com.ryanheise.av_audio_session']) {
      m.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => switch (call.method) {
          'getDevices' => <dynamic>[],
          'getMode' => 0,
          'isBluetoothScoOn' => false,
          _ => null,
        },
      );
    }
    m.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
    );
  });

  GravixRoomService service() => GravixRoomService(
    connectRoom: (room, url, token) async {},
    applyMic: (enabled) async {
      applied.add(enabled);
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      try {
        final g = gates[enabled];
        if (g != null) await g.future;
      } finally {
        inFlight--;
      }
    },
  );

  test('mute while the first enable is blocked (permission): returns at once, applied when it unblocks', () async {
    gates[true] = Completer<void>(); // the permission dialog, still up
    final s = service();
    await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishInBackground: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(applied, [true], reason: 'the join\'s enable is in flight');

    final watch = Stopwatch()..start();
    await s.setMicEnabled(false);
    expect(watch.elapsedMilliseconds, lessThan(100));
    expect(s.isMicMuted.value, isTrue);

    gates[true]!.complete(); // the dialog is answered
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(applied, [true, false], reason: 'the mute is applied right after, not beside it');
    expect(maxInFlight, 1);
    expect(s.isMicMuted.value, isTrue);
    await s.disconnect();
  });

  test('unmute while the first enable is blocked waits for it (one transition in flight)', () async {
    gates[true] = Completer<void>();
    final s = service();
    await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishInBackground: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    var done = false;
    final t = s.setMicEnabled(true).then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse);
    gates[true]!.complete();
    await t;
    expect(applied, [true], reason: 'already the wanted state: nothing more applied');
    expect(maxInFlight, 1);
    await s.disconnect();
  });

  test('a tap before the join reached its mic step wins over publishMic', () async {
    final s = service();
    final joining = s.connect(url: 'wss://a.example', token: 't', publishMic: true);
    unawaited(s.setMicEnabled(false));
    await joining;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(applied, [false]);
    expect(s.isMicMuted.value, isTrue);
    await s.disconnect();
  });

  test('interruption recovery goes through the serializer and keeps a toggle made meanwhile', () async {
    final s = service();
    await s.connect(url: 'wss://a.example', token: 't', publishMic: true);
    expect(applied, [true]);
    gates[false] = Completer<void>();
    final muting = s.setMicEnabled(false); // user mutes; transition held
    final recovering = s.debugRecoverAfterInterruption(micWasEnabled: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(maxInFlight, 1);
    gates[false]!.complete();
    await muting;
    await recovering;
    // the recycle ran after the user's mute, and re-applied the WANTED state
    // (muted), not the state before the interruption
    expect(applied.last, isFalse);
    expect(s.isMicMuted.value, isTrue);
    expect(maxInFlight, 1);
    await s.disconnect();
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field 2026-09-30: a tester toggled the mic ~30 times in 30 s. Every tap queued
// one full mute/unmute transition behind the previous one (the core's publish
// runner is serial), so 20 taps meant 20 native audio transitions played out
// back to back, long after the user stopped. setMicEnabled / muteLocalAudio now
// coalesce: the LAST requested state wins, at most one transition is in flight,
// and taps that arrive meanwhile only update the wanted state.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<bool> applied;
  late Completer<void>? gate;
  late GravixRoomService s;

  setUp(() {
    applied = <bool>[];
    gate = null;
    s = GravixRoomService(
      applyMic: (enabled) async {
        applied.add(enabled);
        final g = gate;
        if (g != null) await g.future;
      },
    );
  });

  test('a single toggle applies once and reports the state', () async {
    await s.setMicEnabled(false);
    expect(applied, [false]);
    expect(s.isMicMuted.value, isTrue);
    await s.setMicEnabled(true);
    expect(applied, [false, true]);
    expect(s.isMicMuted.value, isFalse);
  });

  test('20 rapid toggles converge to the last requested state with <= 2 transitions', () async {
    gate = Completer<void>();
    var mic = true;
    final calls = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      mic = !mic;
      calls.add(s.setMicEnabled(mic));
    }
    // the first transition is still in flight; the UI already shows the last tap
    expect(s.isMicMuted.value, !mic);
    gate!.complete();
    gate = null;
    await Future.wait(calls);
    expect(mic, isTrue, reason: '20 flips from on end on');
    expect(applied.length, lessThanOrEqualTo(2));
    expect(applied.last, mic);
    expect(s.isMicMuted.value, isFalse);
  });

  test('an odd number of rapid toggles ends muted', () async {
    gate = Completer<void>();
    var mic = true;
    final calls = <Future<void>>[];
    for (var i = 0; i < 21; i++) {
      mic = !mic;
      calls.add(s.setMicEnabled(mic));
    }
    gate!.complete();
    gate = null;
    await Future.wait(calls);
    expect(applied.last, isFalse);
    expect(applied.length, lessThanOrEqualTo(2));
    expect(s.isMicMuted.value, isTrue);
  });

  test('toggle back to the in-flight state: nothing more is applied', () async {
    gate = Completer<void>();
    final a = s.setMicEnabled(false);
    final b = s.setMicEnabled(true);
    final c = s.setMicEnabled(false);
    gate!.complete();
    gate = null;
    await Future.wait([a, b, c]);
    expect(applied, [false]);
    expect(s.isMicMuted.value, isTrue);
  });

  test('a failing transition does not wedge later toggles', () async {
    var fail = true;
    final svc = GravixRoomService(
      applyMic: (enabled) async {
        applied.add(enabled);
        if (fail) throw StateError('native said no');
      },
    );
    await svc.setMicEnabled(false);
    fail = false;
    await svc.setMicEnabled(true);
    expect(applied, [false, true]);
    expect(svc.isMicMuted.value, isFalse);
  });

  test('muteLocalAudio goes through the same coalescing', () async {
    gate = Completer<void>();
    final calls = [s.muteLocalAudio(true), s.muteLocalAudio(false), s.muteLocalAudio(true)];
    gate!.complete();
    gate = null;
    await Future.wait(calls);
    expect(applied, [false]);
    expect(s.isMicMuted.value, isTrue);
  });
}

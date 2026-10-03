// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.8 fast join (GravixFastJoin.enabled, the one-flag rollback):
//  - the camera publishes beside the microphone instead of behind it. Up to 0.4.7
//    ONE SerialRunner in LocalParticipant serialised every publish, including the
//    camera open inside setCameraEnabled, so an app's
//    `Future.wait([setMicrophoneEnabled(true), setCameraEnabled(true)])`
//    still ran mic, then camera. Same-source publishes stay serialised (the
//    "track already exists" guard and mute/unmute ordering depend on it).
//  - FastConnectOptions publishes run side by side and do not hold the rest of
//    the JoinResponse handling (remote participants, RoomConnectedEvent).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/participant/gravix_publish_runners.dart';

void main() {
  final shippedDefault = GravixFastJoin.enabled; // read before any setUp changes it
  setUp(() => GravixFastJoin.enabled = true);
  tearDown(() => GravixFastJoin.enabled = false);

  // runs a step that logs start/end around a gate
  Future<void> step(List<String> log, String name, Completer<void> gate) async {
    log.add('$name:start');
    await gate.future;
    log.add('$name:end');
  }

  group('publish runners', () {
    test('default is off (opt in)', () => expect(shippedDefault, isFalse));

    test('on: camera and microphone overlap', () async {
      final r = GravixPublishRunners<void>();
      final log = <String>[];
      final mic = Completer<void>(), cam = Completer<void>();
      final a = r.forSource(TrackSource.microphone).run(() => step(log, 'mic', mic));
      final b = r.forSource(TrackSource.camera).run(() => step(log, 'cam', cam));
      await Future<void>.delayed(Duration.zero);
      expect(log, ['mic:start', 'cam:start']);
      cam.complete();
      mic.complete();
      await Future.wait([a, b]);
    });

    test('on: the same source stays serialised', () async {
      final r = GravixPublishRunners<void>();
      final log = <String>[];
      final g1 = Completer<void>(), g2 = Completer<void>();
      final a = r.forSource(TrackSource.camera).run(() => step(log, 'c1', g1));
      final b = r.forSource(TrackSource.camera).run(() => step(log, 'c2', g2));
      await Future<void>.delayed(Duration.zero);
      expect(log, ['c1:start']);
      g1.complete();
      g2.complete();
      await Future.wait([a, b]);
      expect(log, ['c1:start', 'c1:end', 'c2:start', 'c2:end']);
    });

    test('on: screen share stays with the microphone (it may publish screen audio)', () async {
      final r = GravixPublishRunners<void>();
      expect(identical(r.forSource(TrackSource.screenShareVideo), r.forSource(TrackSource.microphone)), isTrue);
      expect(identical(r.forSource(TrackSource.camera), r.forSource(TrackSource.microphone)), isFalse);
    });

    test('off (rollback): one runner for everything, exactly 0.4.7', () async {
      GravixFastJoin.enabled = false;
      final r = GravixPublishRunners<void>();
      final log = <String>[];
      final mic = Completer<void>(), cam = Completer<void>();
      final a = r.forSource(TrackSource.microphone).run(() => step(log, 'mic', mic));
      final b = r.forSource(TrackSource.camera).run(() => step(log, 'cam', cam));
      await Future<void>.delayed(Duration.zero);
      expect(log, ['mic:start']);
      mic.complete();
      cam.complete();
      await Future.wait([a, b]);
      expect(log, ['mic:start', 'mic:end', 'cam:start', 'cam:end']);
    });
  });

  group('join-response publishes (FastConnectOptions)', () {
    test('on: steps run side by side; the caller is not held', () async {
      final log = <String>[];
      final mic = Completer<void>(), cam = Completer<void>();
      final done = gravixRunJoinPublishes([
        () => step(log, 'mic', mic),
        () => step(log, 'cam', cam),
      ], onError: (e) => log.add('error:$e'));
      // returned without waiting for either step
      expect(done, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(log, ['mic:start', 'cam:start']);
      mic.complete();
      cam.complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('on: a failing step is reported, the others still run', () async {
      final log = <String>[];
      gravixRunJoinPublishes([
        () async => throw StateError('no camera'),
        () async => log.add('mic'),
      ], onError: (e) => log.add('error'));
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(log, containsAll(['mic', 'error']));
    });

    test('off (rollback): one after another, awaited by the caller, errors propagate', () async {
      GravixFastJoin.enabled = false;
      final log = <String>[];
      final mic = Completer<void>(), cam = Completer<void>();
      final done = gravixRunJoinPublishes([
        () => step(log, 'mic', mic),
        () => step(log, 'cam', cam),
      ], onError: (e) => log.add('error:$e'));
      expect(done, isNotNull);
      await Future<void>.delayed(Duration.zero);
      expect(log, ['mic:start']);
      mic.complete();
      cam.complete();
      await done;
      expect(log, ['mic:start', 'mic:end', 'cam:start', 'cam:end']);
      GravixFastJoin.enabled = false;
      await expectLater(gravixRunJoinPublishes([() async => throw StateError('x')], onError: (_) {}), throwsStateError);
    });
  });
}

// Copyright 2026 Gravity Compile. MIT License; see LICENSE.
//
// 0.7.1 (field crash 2026-10-27): local track creation and setRemoteDescription
// never overlap (flutter_webrtc's getUserMedia id lookup disposes the wrappers
// its onAddTrack is using; the app aborts). See gravix_native_gate.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/gravix_native_gate.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/track.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

class _Track extends Track {
  _Track(FakeMediaTrack t) : super(TrackType.AUDIO, TrackSource.microphone, FakeMediaStream([]), t);
  @override
  Future<bool> monitorStats() async => true;
}

void main() {
  final logs = <String>[];
  setUp(() {
    GravixNativeGate.reset();
    logs.clear();
    GravixNativeGate.log = logs.add;
  });
  tearDown(GravixNativeGate.reset);

  Future<void> tick([int ms = 0]) => Future<void>.delayed(Duration(milliseconds: ms));

  test('a local track creation waits for a setRemoteDescription in flight', () async {
    final order = <String>[];
    final srd = Completer<void>();
    final remote = GravixNativeGate.remoteDescription(() async {
      order.add('srd start');
      await srd.future;
      order.add('srd end');
    });
    await tick();
    final local = GravixNativeGate.localTrack(() async => order.add('gum'));
    await tick(20);
    expect(order, ['srd start'], reason: 'getUserMedia must not start mid setRemoteDescription');
    srd.complete();
    await Future.wait([remote, local]);
    expect(order, ['srd start', 'srd end', 'gum']);
    expect(logs.single, startsWith('[GravixGate] localTrack waited for remoteSet'));
  });

  test('a setRemoteDescription right after a local track creation began waits for it', () async {
    final order = <String>[];
    final gum = Completer<void>();
    final local = GravixNativeGate.localTrack(() async {
      order.add('gum start');
      await gum.future;
      order.add('gum end');
    });
    await tick();
    final remote = GravixNativeGate.remoteDescription(() async => order.add('srd'), pc: 'sub#1');
    await tick(20);
    expect(order, ['gum start']);
    gum.complete();
    await Future.wait([local, remote]);
    expect(order, ['gum start', 'gum end', 'srd']);
    expect(logs.single, contains('remoteSet waited for local track pc=sub#1'));
  });

  test('a slow capture start holds a setRemoteDescription for the headroom only', () async {
    GravixNativeGate.localHeadroom = const Duration(milliseconds: 60);
    final gum = Completer<void>();
    final local = GravixNativeGate.localTrack(() => gum.future);
    await tick();
    final sw = Stopwatch()..start();
    await GravixNativeGate.remoteDescription(() async {});
    expect(sw.elapsedMilliseconds, inInclusiveRange(40, 400));
    gum.complete();
    await local;
  });

  test('a local track creation that starts while a setRemoteDescription waits queues behind it', () async {
    final order = <String>[];
    final gum1 = Completer<void>();
    final local1 = GravixNativeGate.localTrack(() async {
      order.add('gum1');
      await gum1.future;
    });
    await tick();
    final remote = GravixNativeGate.remoteDescription(() async => order.add('srd')); // waits for gum1
    await tick();
    final local2 = GravixNativeGate.localTrack(() async => order.add('gum2')); // must not slip in before srd
    await tick(20);
    gum1.complete();
    await Future.wait([local1, remote, local2]);
    expect(order, ['gum1', 'srd', 'gum2']);
  });

  test('no setRemoteDescription is waiting long after a local track creation', () async {
    await GravixNativeGate.localTrack(() async {});
    final sw = Stopwatch()..start();
    await GravixNativeGate.remoteDescription(() async {});
    expect(sw.elapsedMilliseconds, lessThan(30));
    expect(logs, isEmpty);
  });

  test('an error in either body releases the gate', () async {
    await expectLater(GravixNativeGate.remoteDescription<void>(() async => throw StateError('x')), throwsStateError);
    await expectLater(GravixNativeGate.localTrack<void>(() async => throw StateError('y')), throwsStateError);
    final sw = Stopwatch()..start();
    await GravixNativeGate.localTrack(() async {});
    await GravixNativeGate.remoteDescription(() async {});
    expect(sw.elapsedMilliseconds, lessThan(30));
  });

  test('afterRemoteSet returns at once when nothing is in flight, and waits for a setRemoteDescription', () async {
    final sw = Stopwatch()..start();
    await GravixNativeGate.afterRemoteSet();
    expect(sw.elapsedMilliseconds, lessThan(20));
    expect(logs, isEmpty);
    final srd = Completer<void>();
    final order = <String>[];
    final remote = GravixNativeGate.remoteDescription(() async {
      await srd.future;
      order.add('srd end');
    });
    await tick();
    final call = GravixNativeGate.afterRemoteSet(what: 'trackEnable').then((_) => order.add('call'));
    await tick(20);
    expect(order, isEmpty);
    srd.complete();
    await Future.wait([remote, call]);
    expect(order, ['srd end', 'call']);
    expect(logs.single, startsWith('[GravixGate] trackEnable waited for remoteSet'));
  });

  test('a remote track is enabled only after the setRemoteDescription that added it', () async {
    final media = FakeMediaTrack('remote-audio')..enabled = false;
    final track = _Track(media);
    await track.start();
    final srd = Completer<void>();
    final remote = GravixNativeGate.remoteDescription(() => srd.future);
    await tick();
    final enabling = track.enable();
    await tick(20);
    expect(media.enabled, isFalse, reason: 'mediaStreamTrackSetEnable must not reach the plugin mid onAddTrack');
    srd.complete();
    await Future.wait([remote, enabling]);
    expect(media.enabled, isTrue);
    await track.stop();
  });

  test('every setRemoteDescription / getUserMedia / getDisplayMedia in the SDK goes through the gate', () {
    final offenders = <String>[];
    // Raw libwebrtc calls only: Transport.setRemoteDescription is gated inside.
    final raw = RegExp(r'(\bpc[!?]?\.setRemoteDescription\(|mediaDevices\.(getUserMedia|getDisplayMedia)\()');
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      if (f.path.endsWith('gravix_native_gate.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//') || l.startsWith('///') || l.startsWith('*')) continue;
        if (!raw.hasMatch(l)) continue;
        // The wrapped call sits on the same line as the gate, or on the line after it.
        final here = l.contains('GravixNativeGate.');
        final above = i > 0 && lines[i - 1].contains('GravixNativeGate.');
        if (!here && !above) offenders.add('${f.path}:${i + 1}: $l');
      }
    }
    expect(offenders, isEmpty);
  });
}

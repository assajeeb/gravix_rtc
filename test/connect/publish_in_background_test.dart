// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// publishInBackground: connect() returns once the transport is up; the mic /
// camera publication (here: the music-mixer install that precedes it, held on a
// gate) runs behind it. Field 2026-09-29 (Android): ~0.5 s between pcConnected and
// connect() returning.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Completer<void> installGate;
  late List<String> order;

  setUp(() {
    installGate = Completer<void>();
    order = <String>[];
    GravixAudioRouting.v2 = false;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('com.gravitycompile.gravix_rtc/music'), (call) async {
      if (call.method == 'install') {
        order.add('install:start');
        await installGate.future;
        order.add('install:end');
        return true;
      }
      return null;
    });
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

  GravixRoomService service() => GravixRoomService(connectRoom: (room, url, token) async => order.add('transport'));

  test('off (default): connect() returns only after the publication step', () async {
    final s = service();
    var returned = false;
    final joining = s.connect(url: 'wss://a.example', token: 't', publishMic: true).then((ok) {
      returned = true;
      return ok;
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(order, ['transport', 'install:start']);
    expect(returned, isFalse);
    installGate.complete();
    expect(await joining, isTrue);
    await s.disconnect();
  });

  test('on: connect() returns while the publication still runs; the timeline says when the mic went live', () async {
    final s = service();
    final ok = await s.connect(
      url: 'wss://a.example',
      token: 't',
      publishMic: true,
      publishInBackground: true,
      joinTimeline: GravixJoinTimelineInput(tapAt: DateTime.now()),
    );
    expect(ok, isTrue);
    expect(order, ['transport', 'install:start'], reason: 'returned with the publication still held');

    // a mute meanwhile does not race the initial publication: nothing is live
    // yet, so it returns at once (field review 2026-09-30: it must not wait on a
    // blocked first enable), and the publication applies it at its mic step
    var toggled = false;
    final toggle = s.setMicEnabled(false).then((_) => toggled = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(toggled, isTrue);
    expect(s.isMicMuted.value, isTrue);
    installGate.complete();
    await toggle;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(order.last, 'install:end');
    expect(s.isMicMuted.value, isTrue, reason: 'the tap during the join wins over publishMic');

    await s.disconnect();
    final t = s.joinTimeline.value!;
    expect(t.publishInBackground, isTrue);
    expect(t.t[GravixJoinStep.connectReturned], isNotNull);
    expect(t.t[GravixJoinStep.micPublished], isNotNull);
    expect(t.t[GravixJoinStep.micPublished]!.isBefore(t.t[GravixJoinStep.connectReturned]!), isFalse);
    expect(t.toJson()['publishInBackground'], isTrue);
    expect((t.toJson()['ms'] as Map).containsKey('pcToMicPublished'), isTrue);
  });

  test('disconnect waits for a publication still running', () async {
    final s = service();
    await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishInBackground: true);
    var left = false;
    final leaving = s.disconnect().then((_) => left = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(left, isFalse);
    installGate.complete();
    await leaving;
    expect(left, isTrue);
  });
}

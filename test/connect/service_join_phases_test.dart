// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixRoomService.onJoinPhase (0.4.8): the service attaches the same public
// join-phase hooks to the Room it creates in connect().
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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

  test('unset (default): nothing attached', () async {
    final s = GravixRoomService(connectRoom: (room, url, token) async {});
    expect(await s.connect(url: 'wss://a.example', token: 't'), isTrue);
    expect(s.joinPhases, isNull);
    // (no s.dispose(): disconnecting a Room that never had a transport waits out
    // the 10 s leave timeout)
  });

  test('set: the room connect() created is watched, events reach the callback, counted from the tap', () async {
    final seen = <GravixJoinPhaseEvent>[];
    Room? created;
    final s = GravixRoomService(connectRoom: (room, url, token) async => created = room)..onJoinPhase = seen.add;
    final tap = DateTime.now().subtract(const Duration(milliseconds: 250));
    expect(
      await s.connect(
        url: 'wss://a.example',
        token: 't',
        joinTimeline: GravixJoinTimelineInput(tapAt: tap),
      ),
      isTrue,
    );
    final phases = s.joinPhases!;
    expect(identical(phases.room, created), isTrue);
    expect(phases.startedAt, tap);
    phases.debugNoteRemoteSubscribed(TrackType.AUDIO);
    expect(seen.single.phase, GravixJoinPhase.remoteAudioSubscribed);
    expect(seen.single.elapsed.inMilliseconds, greaterThanOrEqualTo(250));
    await phases.dispose();
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.13: the core joins again after a media-connect failure (Room.connect,
// ConnectOptions.joinRetries), which makes a join's window longer. The service
// surfaces the retry (joinRetry / onJoinRetry / isJoining), and a disconnect()
// while the join is in flight ends it: the joined room is not used and nothing
// (no microphone) is published.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const sgp = 'wss://rtc.example.com';
const blr = 'wss://rtc-blr1.example.com';
const fra = 'wss://rtc-fra1.example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<bool> applied;

  setUp(() {
    applied = <bool>[];
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

  test('a retry reaches joinRetry / onJoinRetry; isJoining while joining; both clear when connect returns', () async {
    final gate = Completer<void>();
    late Room joining;
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {
        joining = room;
        // what Room.connect emits before a retry
        room.events.emit(
          RoomJoinRetryEvent(retry: 1, maxRetries: 2, delay: Duration.zero, error: MediaConnectException('pc')),
        );
        await gate.future;
      },
      applyMic: (enabled) async => applied.add(enabled),
    );
    final seen = <RoomJoinRetryEvent>[];
    s.onJoinRetry = seen.add;
    final connecting = s.connect(url: 'wss://a.example', token: 't', publishMic: true);
    expect(s.isJoining.value, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(seen.map((e) => e.retry), [1]);
    expect(s.joinRetry.value?.retry, 1);
    expect(s.isConnected.value, isFalse, reason: '"Take seat" stays disabled while the join is retried');
    gate.complete();
    expect(await connecting, isTrue);
    expect(identical(s.room, joining), isTrue);
    expect(s.isJoining.value, isFalse);
    expect(s.joinRetry.value, isNull);
    expect(s.isConnected.value, isTrue);
    expect(applied, [true]);
    await s.disconnect();
  });

  test('disconnect() while the join is in flight: connect returns false, the room is dropped, no mic', () async {
    final gate = Completer<void>();
    Room? joining;
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {
        joining = room;
        await gate.future; // the attempt (or a retry) is still running
      },
      applyMic: (enabled) async => applied.add(enabled),
    );
    final connecting = s.connect(url: 'wss://a.example', token: 't', publishMic: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(joining, isNotNull);
    await s.disconnect(); // the user leaves the room screen
    expect(joining!.gravixLeaving, isTrue, reason: 'the joining room stops retrying');
    gate.complete(); // the attempt then succeeds anyway
    expect(await connecting, isFalse);
    expect(applied, isEmpty, reason: 'the microphone is never enabled for a join that was left');
    expect(s.isConnected.value, isFalse);
    expect(s.room, isNull);
    expect(joining!.isDisposed, isTrue);
    expect(s.isJoining.value, isFalse);
  });

  // blr answers the probe first: the ladder is blr, fra, then the pinned sgp
  GravixRegionProber blrWins() => GravixRegionProber(
    probe: (url) async {
      if (url != blr) await Future<void>.delayed(const Duration(milliseconds: 40));
    },
  );

  test('disconnect() while joining, and the attempt then fails: false, no mic, the ladder stops', () async {
    final gate = Completer<void>();
    final dialled = <String>[];
    final s = GravixRoomService(
      regionProber: blrWins(),
      connectRoom: (room, url, token) async {
        dialled.add(url);
        await gate.future;
        throw MediaConnectException('pc');
      },
      applyMic: (enabled) async => applied.add(enabled),
    );
    final connecting = s.connect(
      url: sgp,
      token: 't',
      publishMic: true,
      regionProbe: true,
      regionDecisionCache: false,
      regionUrls: const [sgp, blr, fra],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await s.disconnect();
    gate.complete();
    expect(await connecting, isFalse);
    expect(applied, isEmpty);
    expect(dialled, [blr], reason: 'no other region is tried after the leave');
  });

  test('a region ladder: only the last url retries its join; the others move down at once', () async {
    final retriesPerUrl = <String, int?>{};
    late final GravixRoomService s;
    s = GravixRoomService(
      regionProber: blrWins(),
      connectOptions: const ConnectOptions(joinRetryDelays: [Duration(milliseconds: 1)]),
      connectRoom: (room, url, token) async {
        retriesPerUrl[url] = s.debugAttemptConnectOptions?.joinRetries;
        throw MediaConnectException('pc');
      },
    );
    expect(
      await s.connect(
        url: sgp,
        token: 't',
        regionProbe: true,
        regionDecisionCache: false,
        regionUrls: const [sgp, blr, fra],
      ),
      isFalse,
    );
    expect(retriesPerUrl, {blr: 0, fra: 0, sgp: 2});
  });

  test('a new connect after a left join joins normally', () async {
    final gate = Completer<void>();
    var calls = 0;
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {
        if (calls++ == 0) await gate.future;
      },
      applyMic: (enabled) async => applied.add(enabled),
    );
    final first = s.connect(url: 'wss://a.example', token: 't1', publishMic: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await s.disconnect();
    gate.complete();
    expect(await first, isFalse);
    expect(await s.connect(url: 'wss://a.example', token: 't2', publishMic: true), isTrue);
    expect(s.isConnected.value, isTrue);
    expect(applied, [true]);
    await s.disconnect();
  });

  test('a connect() for another session while one is joining: that join stops and is not used', () async {
    final gate = Completer<void>();
    final joining = <Room>[];
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {
        joining.add(room);
        if (token == 't1') await gate.future; // the first join is slow (retrying)
      },
      applyMic: (enabled) async => applied.add(enabled),
    );
    final first = s.connect(url: 'wss://a.example', token: 't1', publishMic: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final second = s.connect(url: 'wss://a.example', token: 't2', publishMic: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(joining.first.gravixLeaving, isTrue, reason: 'the first join stops retrying at once');
    gate.complete();
    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(joining, hasLength(2));
    expect(identical(s.room, joining.last), isTrue);
    expect(applied, [true], reason: 'one mic, for the second join only');
    await s.disconnect();
  });

  test('disconnect() before the join has a Room (still probing): nothing is dialled', () async {
    final dialled = <String>[];
    final s = GravixRoomService(
      regionProber: GravixRegionProber(probe: (url) => Future<void>.delayed(const Duration(milliseconds: 80))),
      connectRoom: (room, url, token) async => dialled.add(url),
      applyMic: (enabled) async => applied.add(enabled),
    );
    final connecting = s.connect(
      url: sgp,
      token: 't',
      publishMic: true,
      regionProbe: true,
      regionDecisionCache: false,
      regionUrls: const [sgp, blr],
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await s.disconnect();
    expect(await connecting, isFalse);
    expect(dialled, isEmpty);
    expect(applied, isEmpty);
  });

  test('connectOptions: null by default (the core defaults: 2 retries)', () {
    expect(GravixRoomService().connectOptions, isNull);
    expect(const ConnectOptions().joinRetries, 2);
    expect(GravixRoomService(connectOptions: const ConnectOptions(joinRetries: 0)).connectOptions?.joinRetries, 0);
  });
}

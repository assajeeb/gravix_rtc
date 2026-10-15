// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixPrejoin over a real Room and its default connect / leave (the scripted
// engine of join_retry_test): abandon() while the join waits for a retry ends the
// join at once (0.4.13: Room.disconnect ends its retries) -- no waiting out a join
// nobody wants -- and the room is disposed. The success path hands the screen the
// connected Room.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';

import '../connect/join_retry_test.dart' show ScriptedEngine;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
    messenger.setMockMethodCallHandler(Native.channel, (call) async => null);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(Native.channel, null);
    await GravixPrejoin.debugEndAll();
  });

  test('abandon while the join waits for a retry: ended at once, one attempt, the room disposed', () async {
    final engine = ScriptedEngine([MediaConnectException('pc'), null]);
    final room = Room(engine: engine);
    final h = GravixPrejoin.start(
      key: 'r1',
      target: () => const GravixJoinTarget(url: 'wss://sfu.example', token: 'tok'),
      createRoom: () => room,
      connectOptions: const ConnectOptions(joinRetries: 2, joinRetryDelays: [Duration(seconds: 30)]),
      abandonInBackground: false,
    );
    final retried = Completer<void>();
    room.events.on<RoomJoinRetryEvent>((_) {
      if (!retried.isCompleted) retried.complete();
    });
    await retried.future.timeout(const Duration(seconds: 5));
    final sw = Stopwatch()..start();
    await h.abandon().timeout(const Duration(seconds: 5));
    expect(await h.ended, GravixPrejoinEndReason.abandoned);
    expect(await h.attach(), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(engine.attempts, 1, reason: 'no retry after the abandon');
    expect(room.isDisposed, isTrue);
  });

  test('the join succeeds: attach() is that Room, one attempt', () async {
    final engine = ScriptedEngine([null]);
    final room = Room(engine: engine);
    final h = GravixPrejoin.start(
      key: 'r2',
      target: () => const GravixJoinTarget(url: 'wss://sfu.example', token: 'tok'),
      createRoom: () => room,
      abandonInBackground: false,
    );
    expect(await h.attach(), same(room));
    expect(engine.attempts, 1);
    await h.leave();
    expect(room.isDisposed, isTrue);
  });
}

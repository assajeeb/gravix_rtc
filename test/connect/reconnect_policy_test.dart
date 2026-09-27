// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

class _Recording implements ReconnectPolicy {
  _Recording(this.answer);
  final int? Function(ReconnectContext) answer;
  final seen = <ReconnectContext>[];
  @override
  int? nextRetryDelayInMs(ReconnectContext context) {
    seen.add(context);
    return answer(context);
  }
}

ReconnectContext ctx(int n) => ReconnectContext(retryCount: n, elapsedMs: 0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DefaultReconnectPolicy (React parity)', () {
    test('walks the SDK table: no jitter on the first two attempts, then up to 1 s', () {
      final p = DefaultReconnectPolicy(null, math.Random(1));
      expect(p.maxAttempts, 10);
      expect(p.nextRetryDelayInMs(ctx(0)), 0);
      expect(p.nextRetryDelayInMs(ctx(1)), 300);
      for (var i = 2; i < 10; i++) {
        final d = p.nextRetryDelayInMs(ctx(i))!;
        expect(d, inInclusiveRange(kDefaultReconnectDelaysInMs[i], kDefaultReconnectDelaysInMs[i] + 999));
      }
      expect(p.nextRetryDelayInMs(ctx(10)), isNull, reason: 'gives up after the table');
    });

    test('a custom table', () {
      final p = DefaultReconnectPolicy([100, 200]);
      expect(p.nextRetryDelayInMs(ctx(0)), 100);
      expect(p.nextRetryDelayInMs(ctx(1)), 200);
      expect(p.nextRetryDelayInMs(ctx(2)), isNull);
    });
  });

  group('engine', () {
    test('default when none is set', () {
      final room = Room();
      expect(room.engine.reconnectPolicy, isA<DefaultReconnectPolicy>());
    });

    test('the policy decides the delay, and sees the attempt context', () async {
      final policy = _Recording((_) => 4242);
      final room = Room(roomOptions: RoomOptions(reconnectPolicy: policy));
      final attempt = room.engine.events.waitFor<EngineAttemptReconnectEvent>(duration: const Duration(seconds: 2));
      await room.engine.handleReconnect(ClientDisconnectReason.signal);
      final e = await attempt;
      expect(e.nextRetryDelaysInMs, 4242);
      expect(e.maxAttempts, -1, reason: 'a custom policy has no fixed attempt count');
      expect(policy.seen.single.retryCount, 0);
      expect(policy.seen.single.retryReason, 'signal');
      await room.dispose();
    });

    test('null stops reconnecting: the room disconnects with reconnectAttemptsExceeded', () async {
      final room = Room(roomOptions: RoomOptions(reconnectPolicy: _Recording((_) => null)));
      final gone = room.engine.events.waitFor<EngineDisconnectedEvent>(duration: const Duration(seconds: 2));
      await room.engine.handleReconnect(ClientDisconnectReason.signal);
      expect((await gone).reason, DisconnectReason.reconnectAttemptsExceeded);
    });

    test('a policy that throws is treated as "stop" (React parity)', () async {
      final room = Room(roomOptions: RoomOptions(reconnectPolicy: _Recording((_) => throw StateError('app bug'))));
      final gone = room.engine.events.waitFor<EngineDisconnectedEvent>(duration: const Duration(seconds: 2));
      await room.engine.handleReconnect(ClientDisconnectReason.signal);
      expect((await gone).reason, DisconnectReason.reconnectAttemptsExceeded);
    });

    test('GravixRoomService passes its policy on', () {
      final p = DefaultReconnectPolicy([1]);
      expect(GravixRoomService(reconnectPolicy: p).reconnectPolicy, same(p));
    });
  });
}

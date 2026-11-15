// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-11-15 (Edu reconnect rig, Bangladesh networks): after a long cut the SDKs reached the SFU
// up to ~23 s after the network was back. Each reconnect dial waited out its timeout while TCP
// backed off, then 7 s + up to 1 s of jitter: no dial was in flight when the network returned.
// 0.10.2 (JS 0.9.1 parity): reconnect dials must get a connection within 3.5 s, the wait after
// a dial with none is 1-2 s, the attempt limit is a 150 s budget, and a connectivity change starts
// a waiting reconnect at once.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/reconnect_policy.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/reconnect_timing.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/blackhole_path.dart';
import '../support/fake_rtc.dart';

ReconnectContext ctx(int n, {int elapsedMs = 10000}) => ReconnectContext(retryCount: n, elapsedMs: elapsedMs);

class _Fixed implements math.Random {
  _Fixed(this.v);
  final double v;
  @override
  double nextDouble() => v;
  @override
  int nextInt(int max) => (v * max).floor().clamp(0, max - 1);
  @override
  bool nextBool() => v >= 0.5;
}

int? delay(
  ReconnectPolicy p,
  ReconnectContext c, {
  bool timedOut = true,
  Duration cap = const Duration(seconds: 2),
  Duration giveUp = const Duration(seconds: 150),
  double r = 0.999,
}) =>
    gravixReconnectDelay(p, c, lastDialTimedOut: timedOut, retryDelayCap: cap, giveUpAfter: giveUp, random: _Fixed(r));

/// Worst case from the network's return to the first SYN that gets through, over a long cut:
/// each dial sends SYNs at 0, 1, 3, 7, 15 s of its life until its bound.
int worstGapAfterRestore(GravixRecoveryOptions o, Duration dialTimeout, double r) {
  const syns = [0, 1000, 3000, 7000, 15000, 31000];
  final sends = <int>[];
  var t = 0;
  final policy = DefaultReconnectPolicy(null, _Fixed(r));
  for (var attempt = 0; t < 140000; attempt++) {
    final dial =
        (gravixReconnectConnectWithin(o.reconnectDialTimeout, dialTimeout, attempt) ?? dialTimeout).inMilliseconds;
    for (final s in syns) {
      if (s < dial) sends.add(t + s);
    }
    t += dial;
    final d = gravixReconnectDelay(
      policy,
      ReconnectContext(retryCount: attempt + 1, elapsedMs: t),
      lastDialTimedOut: true,
      retryDelayCap: o.reconnectRetryDelayCap,
      giveUpAfter: o.reconnectGiveUpAfter > Duration.zero ? o.reconnectGiveUpAfter : const Duration(days: 1),
      random: _Fixed(r),
    );
    if (d == null) break;
    t += d;
  }
  var worst = 0;
  for (var restore = 20000; restore < 110000; restore += 10) {
    final next = sends.firstWhere((s) => s >= restore, orElse: () => -1);
    if (next < 0) continue;
    worst = math.max(worst, next - restore);
  }
  return worst;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('options', () {
    test('defaults: 3.5 s to get a connection, 2 s wait after none, 150 s budget', () {
      const o = GravixRecoveryOptions();
      expect(o.reconnectDialTimeout, const Duration(milliseconds: 3500));
      expect(o.reconnectRetryDelayCap, const Duration(seconds: 2));
      expect(o.reconnectGiveUpAfter, const Duration(seconds: 150));
    });

    test('before0102 and legacy: the 0.10.1 timing (all zero)', () {
      for (final o in [GravixRecoveryOptions.before0102, GravixRecoveryOptions.legacy]) {
        expect(o.reconnectDialTimeout, Duration.zero);
        expect(o.reconnectRetryDelayCap, Duration.zero);
        expect(o.reconnectGiveUpAfter, Duration.zero);
      }
      // only the timing differs from the defaults
      expect(GravixRecoveryOptions.before0102.boundedSignalConnect, isTrue);
    });

    test('copyWith keeps and replaces the timing', () {
      final o = const GravixRecoveryOptions().copyWith(reconnectDialTimeout: const Duration(seconds: 5));
      expect(o.reconnectDialTimeout, const Duration(seconds: 5));
      expect(o.reconnectGiveUpAfter, const Duration(seconds: 150));
    });
  });

  group('gravixReconnectConnectWithin', () {
    const cap = Duration(milliseconds: 3500);
    const ten = Duration(seconds: 10);
    test('the cap, never above the dial timeout; zero = off', () {
      expect(gravixReconnectConnectWithin(cap, ten, 0), cap);
      expect(gravixReconnectConnectWithin(cap, const Duration(seconds: 2), 0), const Duration(seconds: 2));
      expect(gravixReconnectConnectWithin(Duration.zero, ten, 0), isNull);
    });

    test('every 4th dial in a row with no connection is max(2x, 8 s)', () {
      expect(kGravixLongDialEvery, 4);
      final seq = [for (var n = 0; n < 8; n++) gravixReconnectConnectWithin(cap, ten, n)!.inMilliseconds];
      expect(seq, [3500, 3500, 3500, 8000, 3500, 3500, 3500, 8000]);
      expect(gravixReconnectConnectWithin(const Duration(seconds: 5), ten * 2, 3), ten);
    });

    test('a full reconnect: the long slot has no bound (0.10.1 raced dial), the rest are capped', () {
      final seq = [for (var n = 0; n < 8; n++) gravixFullReconnectConnectWithin(cap, ten, n)];
      expect(seq, [cap, cap, cap, null, cap, cap, cap, null]);
      expect(gravixFullReconnectConnectWithin(Duration.zero, ten, 0), isNull);
    });

    test('a path whose connection takes 6 s (slow 3G) gets it within 4 dials', () {
      var n = 0;
      while (gravixReconnectConnectWithin(cap, ten, n)! < const Duration(seconds: 6)) {
        n++;
      }
      expect(n, 3);
    });
  });

  group('gravixReconnectDelay', () {
    test('after a dial with no connection: at most 2 s, 1-2 s from the table step 2.7 s on (jitter kept)', () {
      for (var n = 2; n < 30; n++) {
        final hi = delay(DefaultReconnectPolicy(null, _Fixed(0.999)), ctx(n), r: 0.999)!;
        final lo = delay(DefaultReconnectPolicy(null, _Fixed(0)), ctx(n), r: 0)!;
        expect(hi, lessThanOrEqualTo(2000));
        if (n >= 3) {
          expect(lo, greaterThanOrEqualTo(1000));
          expect(hi, greaterThan(lo));
        }
      }
    });

    test('the first two steps keep 0 and 300 ms', () {
      expect(delay(DefaultReconnectPolicy(), ctx(0)), 0);
      expect(delay(DefaultReconnectPolicy(), ctx(1)), 300);
    });

    test('a failure the server answered keeps the old back-off (7 s + jitter): no extra server load', () {
      for (var n = 5; n < 10; n++) {
        expect(delay(DefaultReconnectPolicy(), ctx(n), timedOut: false), inInclusiveRange(7000, 7999));
      }
    });

    test('time budget: past the 10th attempt while under 150 s; null from 150 s', () {
      expect(
        delay(DefaultReconnectPolicy(), ctx(25, elapsedMs: 100000), timedOut: false),
        inInclusiveRange(7000, 7999),
      );
      expect(delay(DefaultReconnectPolicy(), ctx(3, elapsedMs: 150000)), isNull);
    });

    test('budget zero = the 10-attempt limit (0.10.1)', () {
      final p = DefaultReconnectPolicy();
      expect(delay(p, ctx(9), giveUp: Duration.zero, cap: Duration.zero), isNotNull);
      expect(delay(p, ctx(10), giveUp: Duration.zero, cap: Duration.zero), isNull);
      expect(delay(p, ctx(6), giveUp: Duration.zero, cap: Duration.zero), greaterThanOrEqualTo(7000));
    });

    test("an app's own policy, or its own table, is used exactly", () {
      final own = DefaultReconnectPolicy([0, 5000, 5000]);
      expect(own.gravixDefaultTable, isFalse);
      expect(DefaultReconnectPolicy().gravixDefaultTable, isTrue);
      expect(delay(own, ctx(3)), isNull);
      expect(delay(own, ctx(2)), greaterThanOrEqualTo(5000));
    });

    test('the context tells a custom policy whether the last dial had no connection', () {
      final seen = <bool?>[];
      final spy = _Spy((c) {
        seen.add(c.gravixLastDialTimedOut);
        return 1;
      });
      delay(spy, ctx(0), timedOut: true);
      delay(spy, ctx(0), timedOut: false);
      expect(seen, [true, false]);
    });
  });

  group('the gap from the network coming back to the next dial getting through', () {
    test('0.10.1 timing: up to ~10 s (the bug)', () {
      expect(
        worstGapAfterRestore(GravixRecoveryOptions.before0102, const Duration(seconds: 10), 0.999),
        greaterThan(7000),
      );
    });
    test('0.10.2 defaults: at most 4 s, with any jitter', () {
      for (final r in [0.0, 0.5, 0.999]) {
        expect(
          worstGapAfterRestore(const GravixRecoveryOptions(), const Duration(seconds: 10), r),
          lessThanOrEqualTo(4000),
        );
      }
    });
  });

  group('signal client and engine, blackholed path', () {
    const url = 'ws://blr1.gravixcloud.run';
    const connection = Duration(seconds: 2);
    const cap = Duration(milliseconds: 300);
    late LocalSignalServer server;
    late BlackholePath path;

    setUp(() async {
      installRecoveryChannelMocks();
      HttpOverrides.global = null;
      server = LocalSignalServer();
      await server.start();
      path = BlackholePath(server.port);
      IOOverrides.global = path;
    });
    tearDown(() async {
      IOOverrides.global = null;
      await server.stop();
    });

    ConnectOptions connectOptions() => ConnectOptions(
      timeouts: fastTimeouts(connection: connection, peerConnection: const Duration(seconds: 2)),
    );
    RoomOptions roomOptions(GravixRecoveryOptions recovery, {ReconnectPolicy? policy}) => RoomOptions(
      reconnectPolicy: policy,
      recovery: recovery.copyWith(silentHostFailFast: false, signalDialCap: const Duration(seconds: 3)),
    );
    final fast = const GravixRecoveryOptions().copyWith(
      reconnectDialTimeout: cap,
      reconnectRetryDelayCap: const Duration(milliseconds: 200),
    );

    test('a resume dial with no connection ends at the cap (not the 2 s timeout) and says so', () async {
      path.up = false;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      sc.gravixNextConnectWithin = cap;
      final watch = Stopwatch()..start();
      await expectLater(
        sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: roomOptions(fast), reconnect: true),
        throwsA(anything),
      );
      expect(watch.elapsedMilliseconds, lessThan(cap.inMilliseconds + 400));
      expect(sc.gravixLastDialNoConnection, isTrue);
      await sc.dispose();
    });

    test('without it: the dial timeout (0.10.1)', () async {
      path.up = false;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      final watch = Stopwatch()..start();
      await expectLater(
        sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: roomOptions(fast), reconnect: true),
        throwsA(anything),
      );
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(connection.inMilliseconds - 50));
      await sc.dispose();
    });

    Future<Engine> connected(GravixRecoveryOptions recovery, {ReconnectPolicy? policy}) async {
      final pcs = FakePcFactory();
      autoConnectPcs(pcs);
      final engine = Engine(
        connectOptions: connectOptions(),
        roomOptions: roomOptions(recovery, policy: policy),
        signalClient: FakeConnectivitySignalClient(GravixRtcWebSocket.connect),
        peerConnectionCreate: pcs.create,
      );
      addTearDown(engine.dispose);
      await engine.connect(url, 'tok');
      return engine;
    }

    test('a cut: short resume dials, still resumes (no full rejoin), back soon after the path is', () async {
      final engine = await connected(fast);
      final resumed = <EngineResumedEvent>[];
      final restarted = <EngineRestartedEvent>[];
      final l = engine.createListener()
        ..on<EngineResumedEvent>(resumed.add)
        ..on<EngineRestartedEvent>(restarted.add);
      addTearDown(l.dispose);
      final w0 = Stopwatch()..start();
      final trace = <String>[];
      final l2 = engine.createListener()
        ..on<EngineAttemptReconnectEvent>((e) => trace.add('${w0.elapsedMilliseconds} sched ${e.nextRetryDelaysInMs}'))
        ..on<EngineReconnectAttemptEvent>((e) => trace.add('${w0.elapsedMilliseconds} attempt full=${e.full}'));
      addTearDown(() async {
        // ignore: avoid_print
        print('TRACE $trace');
        await l2.dispose();
      });
      path.up = false;
      expect(engine.gravixRequestResume('cut test'), isTrue);
      // (back during the 3rd short dial: this fake path never lets a dial started blackholed
      // through, so the 4th, long, dial would sit out its bound; a real one's SYN retries do)
      await settle(1100);
      final dials = path.kinds.where((k) => k == 'dial').length;
      // 0.10.1: one 2 s dial in this window
      expect(dials, greaterThanOrEqualTo(3), reason: '${path.blackholed}');
      expect(path.kinds, isNot(contains('validate')), reason: 'a full rejoin validates: ${path.blackholed}');
      path.up = true;
      final back = Stopwatch()..start();
      expect(await eventually(() => resumed.isNotEmpty, timeout: const Duration(seconds: 4)), isTrue);
      // ignore: avoid_print
      print('RESULT resumed_after_path_back_ms=${back.elapsedMilliseconds} dials_during_cut=$dials');
      // the dial in flight (<= its cap) and the wait (<= 200 ms), plus the resume itself
      expect(back.elapsedMilliseconds, lessThan(1500));
      expect(restarted, isEmpty);
    });

    // Rig 2026-11-15 (JS, cut 75 s, grace 120 s): the resume dial as the network came back failed
    // at the socket; taken for a dead session, the full rejoin dropped the session the SFU held.
    Future<(List<EngineResumedEvent>, List<EngineRestartedEvent>)> cutThenRefused(
      GravixRecoveryOptions recovery,
      int refusals,
    ) async {
      final engine = await connected(recovery);
      final resumed = <EngineResumedEvent>[];
      final restarted = <EngineRestartedEvent>[];
      final l = engine.createListener()
        ..on<EngineResumedEvent>(resumed.add)
        ..on<EngineRestartedEvent>(restarted.add);
      addTearDown(l.dispose);
      path.up = false;
      expect(engine.gravixRequestResume('cut test'), isTrue);
      await settle(450);
      expect(path.kinds.where((k) => k == 'dial'), isNotEmpty);
      path.refuseNext = refusals;
      path.up = true;
      await eventually(() => resumed.isNotEmpty || restarted.isNotEmpty, timeout: const Duration(seconds: 6));
      return (resumed, restarted);
    }

    test('the socket fails as the network comes back (after a dial with no connection): resumes again', () async {
      final (resumed, restarted) = await cutThenRefused(fast, 1);
      expect(path.refused, greaterThanOrEqualTo(1));
      expect(resumed, isNotEmpty);
      expect(restarted, isEmpty);
    });

    test('two socket failures in a row: a full reconnect (a session that is gone)', () async {
      final (_, restarted) = await cutThenRefused(fast, 2);
      expect(restarted, isNotEmpty);
    });

    test('a connectivity change starts a reconnect waiting for its timer at once', () async {
      final engine = await connected(fast, policy: _Spy((_) => 60000));
      final signal = engine.signalClient as FakeConnectivitySignalClient;
      path.up = false;
      unawaited(engine.handleReconnect(ClientDisconnectReason.signal));
      await settle(50);
      expect(engine.isPendingReconnect, isTrue);
      final before = path.kinds.length;
      path.up = true;
      signal.events.emit(
        SignalConnectivityChangedEvent(
          oldState: const [ConnectivityResult.none],
          state: const [ConnectivityResult.wifi],
        ),
      );
      await settle(100);
      expect(engine.isPendingReconnect, isFalse);
      expect(path.upConnects + path.kinds.length, greaterThan(before), reason: 'a dial went out');
    });
  });
}

class _Spy implements ReconnectPolicy {
  _Spy(this.f);
  final int? Function(ReconnectContext) f;
  @override
  int? nextRetryDelayInMs(ReconnectContext context) => f(context);
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The bounded signal dial (GravixRecoveryOptions.boundedSignalConnect, soak
// 2026-10-11) at the WebSocket layer, its rollback switch, the standby race
// under the bound, and its cost on a normal join. See
// signal_dial_timeout_test.dart for the field event; this file uses the new API.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/standby.dart';

import '../support/blackhole_path.dart';
import '../support/fake_rtc.dart';

const url = 'ws://blr1.gravixcloud.run';
const bound = Duration(milliseconds: 300);

/// Accepts TCP, answers a HEAD (keep-alive), never answers anything else (an
/// upgrade that reached a server whose answer is lost); records the connections
/// the client closed.
class _SilentServer {
  late ServerSocket _socket;
  int accepts = 0;
  int closedByClient = 0;
  int upgradesSeen = 0;
  final _conns = <Socket>[];

  int get port => _socket.port;

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((c) {
      accepts++;
      _conns.add(c);
      var buf = '';
      c.listen(
        (data) {
          buf += latin1.decode(data);
          while (buf.contains('\r\n\r\n')) {
            final end = buf.indexOf('\r\n\r\n') + 4;
            final head = buf.substring(0, end);
            buf = buf.substring(end);
            if (head.startsWith('HEAD')) {
              c.add(latin1.encode('HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n'));
            } else {
              upgradesSeen++;
            }
          }
        },
        onDone: () => closedByClient++,
        onError: (Object _) => closedByClient++,
      );
    });
  }

  Future<void> stop() async {
    for (final c in _conns) {
      c.destroy();
    }
    await _socket.close();
  }
}

void main() {
  // these cases test the bound itself with low RTTs: the pre-0.7.2 floor
  setUp(() => gravixStandbyLowRttUpgradeFloor = null);
  tearDown(() => gravixStandbyLowRttUpgradeFloor = kGravixStandbyLowRttUpgradeFloorDefault);
  TestWidgetsFlutterBinding.ensureInitialized();

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
    // every connect named a real port (emulator 2026-10-11: the raced dial asked
    // dart:io for port 0, which this redirecting override used to hide)
    expect(path.requested.where((r) => r.endsWith(':0')), isEmpty, reason: '${path.requested}');
    await GravixSignalStandby.closeAll();
    await server.stop();
  });

  ConnectOptions connectOptions() => ConnectOptions(timeouts: fastTimeouts(connection: bound));

  test('the switch: on by default, off in legacy', () {
    expect(const GravixRecoveryOptions().boundedSignalConnect, isTrue);
    expect(GravixRecoveryOptions.legacy.boundedSignalConnect, isFalse);
    expect(const GravixRecoveryOptions().copyWith(boundedSignalConnect: false).boundedSignalConnect, isFalse);
    // (off in the 2026-10-11 interim, on again with the port fix)
    expect(const GravixRecoveryOptions().signalDialCap, const Duration(seconds: 30));
    expect(GravixRecoveryOptions.legacy.signalDialCap, isNull);
    expect(const GravixRecoveryOptions().copyWith(clearSignalDialCap: true).signalDialCap, isNull);
  });

  group('signalDialCap (device recheck 2026-10-11, "Very Bad Network")', () {
    const slow = Duration(milliseconds: 450);

    test('null: a fresh join dial gives up at the dial timeout (as with boundedSignalConnect alone)', () async {
      path.slow = slow;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      await expectLater(
        sc.connect(
          url,
          'tok',
          connectOptions: connectOptions(),
          roomOptions: RoomOptions(recovery: const GravixRecoveryOptions(signalDialCap: null)),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(path.slowConnects.where((c) => c.kind == 'dial').length, 1, reason: 'not raced');
      await sc.dispose();
    });

    test('a resume dial is not raced and keeps the dial timeout', () async {
      path.slow = slow;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      final watch = Stopwatch()..start();
      await expectLater(
        sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: RoomOptions(), reconnect: true),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsedMilliseconds, lessThan(bound.inMilliseconds + 400));
      expect(path.slowConnects.single.cancelled, isTrue);
      await sc.dispose();
    });

    test('a refused connection fails the dial at once (no wait for a parallel one)', () async {
      path.refuse = true;
      final watch = Stopwatch()..start();
      Object? error;
      try {
        await GravixRtcWebSocket.connect(
          Uri.parse('$url/rtc?x=1'),
          connectTimeout: const Duration(seconds: 3),
          hedgeAfter: bound,
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<WebSocketException>());
      expect(watch.elapsedMilliseconds, lessThan(200));
      expect(path.refused, 1);
    });

    test('a connector without the new parameters keeps the dial timeout (an app\'s or a test fake)', () async {
      final never = Completer<GravixRtcWebSocket>();
      final sc = SignalClient((uri, {options, headers, networkOptions, preconnected}) => never.future);
      final watch = Stopwatch()..start();
      await expectLater(
        sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: RoomOptions()),
        throwsA(anything),
      );
      // the dial timeout, then the validate request (answered at once here)
      expect(watch.elapsedMilliseconds, lessThan(bound.inMilliseconds + 400));
      await sc.dispose();
    });
  });

  group('boundedSignalConnect: false = the 0.4.14 connect', () {
    final legacy = RoomOptions(recovery: const GravixRecoveryOptions(boundedSignalConnect: false));

    test('the resume dial times out at the bound, its socket is left connecting', () async {
      path.up = false;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      await expectLater(
        sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: legacy, reconnect: true),
        throwsA(isA<TimeoutException>()),
      );
      await settle(bound.inMilliseconds * 2);
      expect(path.kinds, ['dial']);
      expect(path.blackholed.single.cancelled, isFalse);
      await sc.dispose();
    });

    test('the first join waits on its validate request past the bound', () async {
      path.up = false;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      var done = false;
      unawaited(
        sc
            .connect(url, 'tok', connectOptions: connectOptions(), roomOptions: legacy)
            .then<void>((_) => done = true, onError: (Object _) => done = true),
      );
      await settle(bound.inMilliseconds * 4);
      expect(done, isFalse);
      expect(path.kinds, ['dial', 'validate']);
      expect(path.blackholed.any((c) => c.cancelled), isFalse);
    });
  });

  group('the bounded dial (websocket/io.dart)', () {
    test(
      'blackholed: a dart:async TimeoutException at the bound (not a WebSocketException), connect aborted',
      () async {
        path.up = false;
        final watch = Stopwatch()..start();
        Object? error;
        try {
          await GravixRtcWebSocket.connect(Uri.parse('$url/rtc?x=1'), connectTimeout: bound);
        } catch (e) {
          error = e;
        }
        // the engine escalates a resume at once on a WebSocketException, and on dial
        // timeouts only after two: a blackholed path must keep reading as a timeout
        expect(error, isA<TimeoutException>());
        expect(watch.elapsedMilliseconds, lessThan(bound.inMilliseconds + 600));
        expect(path.blackholed.single.cancelled, isTrue);
        expect(path.blackholed.single.cancelledAfter!, lessThan(bound + const Duration(milliseconds: 500)));
      },
    );

    test('connected but the upgrade is never answered: TimeoutException at the bound, connection closed', () async {
      final silent = _SilentServer();
      await silent.start();
      addTearDown(silent.stop);
      path.serverPort = silent.port;
      final watch = Stopwatch()..start();
      await expectLater(
        GravixRtcWebSocket.connect(Uri.parse('$url/rtc?x=1'), connectTimeout: bound),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsedMilliseconds, lessThan(bound.inMilliseconds + 600));
      expect(silent.upgradesSeen, 1);
      expect(
        await eventually(() => silent.closedByClient == 1, timeout: const Duration(seconds: 1)),
        isTrue,
        reason: 'the unanswered upgrade connection was left open',
      );
    });

    test('a normal dial with a bound connects as before', () async {
      final ws = await GravixRtcWebSocket.connect(Uri.parse('$url/rtc?x=1'), connectTimeout: bound);
      expect(await eventually(() => server.openSockets == 1), isTrue);
      await ws.dispose();
    });
  });

  group('standby under the bound', () {
    test('a normal warm upgrade still goes over the standby connection (one TCP connect)', () async {
      expect(await GravixSignalStandby.open(url, 'tok'), isTrue);
      expect(path.upConnects, 1);
      final taken = await GravixSignalStandby.take(url, 'tok');
      final ws = await GravixRtcWebSocket.connect(
        Uri.parse('$url/rtc?x=1'),
        preconnected: taken,
        connectTimeout: const Duration(seconds: 2),
      );
      expect(ws.gravixDial?.path, 'standby');
      expect(path.upConnects, 1, reason: 'no fresh dial');
      GravixSignalStandby.release(taken.client);
      await ws.dispose();
    });

    test('warm upgrade unanswered and the fresh dial blackholed: both closed at the bound', () async {
      final silent = _SilentServer();
      await silent.start();
      addTearDown(silent.stop);
      path.serverPort = silent.port;
      // 3 x 10 ms is below the floor: the upgrade gets 500 ms, then a fresh dial races it
      expect(await GravixSignalStandby.open(url, 'tok', rttHintMs: 10), isTrue);
      final taken = await GravixSignalStandby.take(url, 'tok');
      expect(taken.usable, isTrue);
      path.up = false;
      const dialBound = Duration(milliseconds: 900);
      final watch = Stopwatch()..start();
      await expectLater(
        GravixRtcWebSocket.connect(Uri.parse('$url/rtc?x=1'), preconnected: taken, connectTimeout: dialBound),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsedMilliseconds, lessThan(dialBound.inMilliseconds + 600));
      expect(silent.upgradesSeen, 1, reason: 'the upgrade went over the warm connection');
      expect(path.kinds, ['dial'], reason: 'the fresh dial of the race');
      expect(path.blackholed.single.cancelled, isTrue);
      expect(
        await eventually(() => silent.closedByClient == 1, timeout: const Duration(seconds: 1)),
        isTrue,
        reason: 'the warm connection with the unanswered upgrade was left open',
      );
      GravixSignalStandby.release(taken.client);
    });
  });

  test('cost on a normal join: the bounded dial vs the 0.4.14 dial (local server)', () async {
    // straight to the local server: no override in the measured path
    IOOverrides.global = null;
    final uri = Uri.parse('ws://127.0.0.1:${server.port}/rtc?x=1');
    final bounded = <int>[];
    final legacy = <int>[];
    final hedged = <int>[];
    Future<void> dial(List<int> into, Duration? timeout, [Duration? hedgeAfter]) async {
      final w = Stopwatch()..start();
      final ws = await GravixRtcWebSocket.connect(uri, connectTimeout: timeout, hedgeAfter: hedgeAfter);
      into.add(w.elapsedMicroseconds);
      await ws.dispose();
    }

    // warm-up, then alternate
    await dial([], null);
    await dial([], const Duration(seconds: 10));
    await dial([], const Duration(seconds: 30), const Duration(seconds: 10));
    for (var i = 0; i < 40; i++) {
      await dial(legacy, null);
      await dial(bounded, const Duration(seconds: 10));
      await dial(hedged, const Duration(seconds: 30), const Duration(seconds: 10));
    }
    int median(List<int> v) => (List.of(v)..sort())[v.length ~/ 2];
    // ignore: avoid_print
    print(
      'RESULT dial_local_median_us bounded=${median(bounded)} hedged=${median(hedged)} legacy=${median(legacy)} '
      '(n=${bounded.length} each)',
    );
    // a new HttpClient and a timer per dial (and the race's own timer): well
    // under a millisecond
    expect(median(hedged) - median(legacy), lessThan(2000));
    expect(median(bounded) - median(legacy), lessThan(2000));
  });
}

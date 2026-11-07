// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field 2026-11-08 (Tuki, Redmi on Wi-Fi, 28 ms to dac1, signal isolate on): a
// viewer join took the standby connection (open, opened at tap-down) and its
// upgrade went unanswered; wsOpen came 5.9 s after wsConnecting
// (stalled_redialed). Two costs on the SDK side:
//  - at an RTT under 30 ms the bound was the 0.7.2 low-RTT floor, 1.5 s, before
//    a fresh dial even started;
//  - the fresh dial's connection was ONE socket left to the OS's SYN
//    retransmissions (1 s, 3 s, 7 s): it inherited the join's hedge, a
//    parallel connection only every Timeouts.connection (10 s).
// Now: a fresh socket starts at max(3 x RTT, 0.8 s) (capped at 1.5 s), races the
// standby upgrade, and is itself hedged every that long.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/http_client/io.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/standby.dart';

/// A server behind a proxy that answers the FIRST connection's warm-up (HEAD) and
/// then nothing more on it: the standby upgrade reaches the server, its answer is
/// lost (field 2026-09-30 / 2026-11-08).
class _StalledStandbyServer {
  late HttpServer http;
  late ServerSocket proxy;
  int accepts = 0;
  final upgrades = <WebSocket>[];
  final closed = <int>[];
  final _sockets = <Socket>[];

  String get url => 'ws://127.0.0.1:${proxy.port}';

  Future<void> start() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        final n = upgrades.length;
        upgrades.add(ws);
        ws.listen(ws.add, onDone: () => closed.add(n), onError: (_) {});
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    proxy = await ServerSocket.bind('127.0.0.1', 0);
    proxy.listen((c) async {
      final n = ++accepts;
      final up = await Socket.connect('127.0.0.1', http.port);
      _sockets
        ..add(c)
        ..add(up);
      var responses = 0;
      c.listen(up.add, onError: (_) {}, onDone: () => up.destroy());
      up.listen(
        (d) {
          if (n == 1 && ++responses > 1) return; // the HEAD's answer only
          c.add(d);
        },
        onError: (_) {},
        onDone: () => c.destroy(),
      );
    });
  }

  Future<void> stop() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await proxy.close();
    await http.close(force: true);
  }
}

// the join's dial as the signal client makes it on a fresh join with the default
// options (signal_client.dart: dialCap 30 s, hedged every Timeouts.connection,
// upgrade window 20 s, ceiling 45 s)
Future<GravixRtcWebSocket> _fieldDial(String url, Object? pre) => GravixRtcWebSocket.connect(
  Uri.parse('$url/rtc?x=1'),
  preconnected: pre,
  connectTimeout: const Duration(seconds: 30),
  hedgeAfter: const Duration(seconds: 10),
  upgradeWindow: const Duration(seconds: 20),
  dialCeiling: const Duration(seconds: 45),
);

void main() {
  late _StalledStandbyServer server;

  setUp(() async {
    server = _StalledStandbyServer();
    await server.start();
  });

  tearDown(() async {
    gravixDebugSocketConnect = null;
    gravixStandbyInSignalIsolate = false;
    await GravixSignalStandby.closeAll();
    await server.stop();
  });

  test('bound: max(3 x RTT, 0.8 s) at a low RTT, in either isolate; 3 x RTT above; capped at 1.5 s', () {
    expect(kGravixStandbyLowRttUpgradeFloorDefault, kGravixStandbyHedgeFloor);
    expect(gravixStandbyUpgradeBound(28), const Duration(milliseconds: 800), reason: 'the field join: 28 ms');
    expect(gravixStandbyUpgradeBound(6), const Duration(milliseconds: 800));
    gravixStandbyInSignalIsolate = true;
    expect(gravixStandbyUpgradeBound(28), const Duration(milliseconds: 800));
    expect(gravixStandbyUpgradeBound(300), const Duration(milliseconds: 900));
    expect(gravixStandbyUpgradeBound(900), kGravixStandbyUpgradeTimeout);
  });

  test('a stalled standby at 28 ms: the fresh socket starts at 0.8 s and carries the join; timeline fields', () async {
    expect(await GravixSignalStandby.open(server.url, 'tok', rttHintMs: 28), isTrue);
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    expect(taken.upgradeBound, const Duration(milliseconds: 800));
    final watch = Stopwatch()..start();
    final ws = await _fieldDial(server.url, taken);
    final ms = watch.elapsedMilliseconds;
    expect(ms, greaterThanOrEqualTo(780));
    expect(ms, lessThan(800 + 600), reason: 'fresh dial at the bound, not after 1.5 s');
    final dial = ws.gravixDial!;
    expect(dial.path, 'redial');
    expect(dial.stalledAfterMs, 800);
    expect(dial.freshConnects, 1);
    expect(dial.freshUpMs, isNotNull);
    expect(dial.freshUpMs!, inInclusiveRange(800, dial.totalMs!));
    expect(server.accepts, 2);
    // one join reached the server for real: the abandoned one is closed
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.upgrades.length, 2);
    expect(server.closed, [0]);
    GravixSignalStandby.release(taken.client);
    await ws.dispose();
  });

  test('the fresh socket\'s SYN goes nowhere: a parallel one starts after one more bound, not after 10 s', () async {
    expect(await GravixSignalStandby.open(server.url, 'tok', rttHintMs: 28), isTrue);
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    // the fresh dial's first socket never connects (a lost SYN, a Wi-Fi hiccup);
    // every later one does
    var fresh = 0;
    final cancelled = <int>[];
    gravixDebugSocketConnect = (url, proxyHost, proxyPort) async {
      final n = ++fresh;
      if (n == 1) {
        final never = Completer<Socket>();
        return ConnectionTask.fromSocket<Socket>(never.future, () {
          cancelled.add(n);
          if (!never.isCompleted) never.completeError(const SocketException('cancelled'));
        });
      }
      return gravixRealSocketConnect(url, proxyHost, proxyPort);
    };
    final watch = Stopwatch()..start();
    final ws = await _fieldDial(server.url, taken);
    final ms = watch.elapsedMilliseconds;
    expect(ms, lessThan(800 + 800 + 600), reason: 'bound + one hedge interval + the upgrade');
    final dial = ws.gravixDial!;
    expect(dial.path, 'redial');
    expect(dial.freshConnects, 2);
    expect(dial.freshUpMs!, greaterThanOrEqualTo(1580));
    expect(cancelled, [1], reason: 'the stuck socket is cancelled, nothing is written on it');
    GravixSignalStandby.release(taken.client);
    await ws.dispose();
  });

  test('the standby upgrade answers just after the bound, before a fresh socket is up: it wins', () async {
    // a fresh socket that takes 400 ms to come up: the late warm answer (the
    // proxy holds it 950 ms) lands first
    await server.stop();
    final http = await HttpServer.bind('127.0.0.1', 0);
    http.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        await Future<void>.delayed(const Duration(milliseconds: 950));
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen(ws.add, onError: (_) {});
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    final url = 'ws://127.0.0.1:${http.port}';
    gravixDebugSocketConnect = (u, ph, pp) async {
      final task = await gravixRealSocketConnect(u, ph, pp);
      return ConnectionTask.fromSocket<Socket>(
        task.socket.then((s) => Future<Socket>.delayed(const Duration(milliseconds: 400), () => s)),
        task.cancel,
      );
    };
    try {
      expect(await GravixSignalStandby.open(url, 'tok', rttHintMs: 28), isTrue);
      final taken = await GravixSignalStandby.take(url, 'tok');
      final ws = await _fieldDial(url, taken);
      final dial = ws.gravixDial!;
      expect(dial.path, 'standby_late');
      expect(dial.freshUpMs, isNull, reason: 'the fresh socket never came up in time');
      expect(dial.freshConnects, 1);
      GravixSignalStandby.release(taken.client);
      await ws.dispose();
    } finally {
      await http.close(force: true);
      server = _StalledStandbyServer();
      await server.start();
    }
  });
}

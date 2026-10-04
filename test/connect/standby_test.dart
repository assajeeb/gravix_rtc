// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The Flutter standby pre-connect (standby_io.dart): a HEAD leaves a keep-alive
// connection in a dart:io HttpClient's pool, and the join's WebSocket upgrade goes
// over it. Against a real local server behind a counting TCP proxy, so "the
// upgrade reused the warm connection" is checked by counting TCP accepts.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/standby.dart';

class _Server {
  late HttpServer http;
  late ServerSocket proxy;
  int accepts = 0;
  int heads = 0;
  final _sockets = <Socket>[];

  String get url => 'ws://127.0.0.1:${proxy.port}';

  Future<void> start({Duration idle = const Duration(minutes: 3)}) async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.idleTimeout = idle;
    http.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((m) => ws.add(m));
        return;
      }
      if (req.method == 'HEAD') heads++;
      req.response.statusCode = 404;
      await req.response.close();
    });
    proxy = await ServerSocket.bind('127.0.0.1', 0);
    proxy.listen((c) async {
      accepts++;
      final up = await Socket.connect('127.0.0.1', http.port);
      _sockets
        ..add(c)
        ..add(up);
      c.cast<List<int>>().pipe(up).catchError((_) {});
      up.cast<List<int>>().pipe(c).catchError((_) {});
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

Future<GravixRtcWebSocket> _dial(String url, Object? pre) =>
    GravixRtcWebSocket.connect(Uri.parse('$url/rtc?x=1'), preconnected: pre);

void main() {
  late _Server server;
  late DateTime clock;

  setUp(() async {
    server = _Server();
    await server.start();
    clock = DateTime(2026, 9, 29, 12);
    GravixSignalStandby.now = () => clock;
  });

  tearDown(() async {
    await GravixSignalStandby.closeAll();
    GravixSignalStandby.now = DateTime.now;
    await server.stop();
  });

  test('open -> the join upgrade goes over the warm connection: one TCP accept in all', () async {
    expect(await GravixSignalStandby.open(server.url, 'tok'), isTrue);
    expect(server.accepts, 1);
    expect(server.heads, 1);
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'open');

    final taken = await GravixSignalStandby.take(server.url, 'tok');
    expect(taken.outcome, 'used');
    expect(taken.usable, isTrue);
    final ws = await _dial(server.url, taken.client);
    expect(server.accepts, 1, reason: 'the upgrade must not open a second connection');
    expect(GravixSignalStandby.connectsOf(taken.client), taken.connectsAtTake);
    GravixSignalStandby.release(taken.client);
    await ws.dispose();
    // taken: nothing left for this url + token
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'none');
  });

  test('a HOST standby (empty token) serves a join with any token: usedHost, one TCP accept', () async {
    expect(await GravixSignalStandby.open(server.url, ''), isTrue);
    expect(server.accepts, 1);
    final taken = await GravixSignalStandby.take(server.url, 'any-token');
    expect(taken.outcome, 'usedHost');
    expect(taken.usable, isTrue);
    final ws = await _dial(server.url, taken.client);
    expect(server.accepts, 1, reason: 'the upgrade goes over the host standby');
    GravixSignalStandby.release(taken.client);
    await ws.dispose();
    expect(GravixSignalStandby.state(server.url, '').state, 'none', reason: 'taken');
    // nothing left: the next join dials cold
    expect((await GravixSignalStandby.take(server.url, 'another')).outcome, 'none');
  });

  test('the exact standby wins over the host one, which stays for the next join', () async {
    await GravixSignalStandby.open(server.url, '');
    await GravixSignalStandby.open(server.url, 'tok');
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    expect(taken.outcome, 'used');
    GravixSignalStandby.release(taken.client);
    expect(GravixSignalStandby.state(server.url, '').state, 'open');
  });

  test('an expired host standby is not used', () async {
    await GravixSignalStandby.open(server.url, '');
    clock = clock.add(const Duration(seconds: 111));
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    expect(taken.usable, isFalse);
  });

  test('exact url + token: no standby for the host is outcome none and dials cold', () async {
    await GravixSignalStandby.open(server.url, 'tok');
    final other = await GravixSignalStandby.take('ws://127.0.0.1:1', 'another');
    expect(other.outcome, 'none');
    expect(other.usable, isFalse);
    final ws = await _dial(server.url, other.client);
    expect(server.accepts, 2);
    await ws.dispose();
    // the standby for 'tok' (another host) is untouched
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'open');
    // ws/http and wss/https name the same host; a trailing slash does not matter
    expect(GravixSignalStandby.state('${server.url.replaceFirst('ws:', 'http:')}/', 'tok').state, 'open');
  });

  test('per server: a token with no standby of its own takes another card\'s standby to the same host', () async {
    await GravixSignalStandby.open(server.url, 'card-a');
    clock = clock.add(const Duration(seconds: 2));
    await GravixSignalStandby.open(server.url, 'card-b');
    expect(server.accepts, 2);
    final taken = await GravixSignalStandby.take(server.url, 'tapped-card');
    expect(taken.outcome, 'usedSameHost');
    expect(taken.ageMs, 0, reason: 'the youngest one is taken');
    final ws = await _dial(server.url, taken.client);
    expect(server.accepts, 2, reason: 'the upgrade went over a warm connection');
    GravixSignalStandby.release(taken.client);
    await ws.dispose();
    expect(GravixSignalStandby.state(server.url, 'card-a').state, 'open', reason: 'the other one stays');
    expect(GravixSignalStandby.state(server.url, 'card-b').state, 'none', reason: 'taken');
  });

  test('per server: a standby to ANOTHER host is never taken (other server)', () async {
    final other = _Server();
    await other.start();
    addTearDown(other.stop);
    await GravixSignalStandby.open(other.url, 'old-server-card');
    final taken = await GravixSignalStandby.take(server.url, 'tapped');
    expect(taken.outcome, 'none');
    expect(GravixSignalStandby.state(other.url, 'old-server-card').state, 'open');
  });

  test('per server: one still opening to the same host is waited for (awaitedSameHost)', () async {
    final gate = Completer<void>();
    GravixSignalStandby.warm = (client, uri) async {
      await gate.future;
      final r = await (await client.openUrl('HEAD', uri)).close();
      await r.drain<void>();
      return r.persistentConnection;
    };
    addTearDown(
      () => GravixSignalStandby.warm = (c, u) async {
        final r = await (await c.openUrl('HEAD', u)).close();
        await r.drain<void>();
        return r.persistentConnection;
      },
    );
    unawaited(GravixSignalStandby.open(server.url, 'neighbour'));
    final taking = GravixSignalStandby.take(server.url, 'tapped', wait: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    final taken = await taking;
    expect(taken.outcome, 'awaitedSameHost');
    expect(taken.usable, isTrue);
    GravixSignalStandby.release(taken.client);
  });

  test('per server: an open neighbour beats waiting for the exact one still opening (tap-down warm-up)', () async {
    await GravixSignalStandby.open(server.url, 'neighbour');
    GravixSignalStandby.warm = (client, uri) => Completer<bool>().future; // never lands
    addTearDown(
      () => GravixSignalStandby.warm = (c, u) async {
        final r = await (await c.openUrl('HEAD', u)).close();
        await r.drain<void>();
        return r.persistentConnection;
      },
    );
    unawaited(GravixSignalStandby.open(server.url, 'tapped'));
    expect(GravixSignalStandby.state(server.url, 'tapped').state, 'opening');
    final watch = Stopwatch()..start();
    final taken = await GravixSignalStandby.take(server.url, 'tapped', wait: const Duration(seconds: 2));
    expect(taken.outcome, 'usedSameHost');
    expect(watch.elapsedMilliseconds, lessThan(500), reason: 'no wait for the one still opening');
    GravixSignalStandby.release(taken.client);
  });

  test('over the limit: a second connection to one host goes before the only one to another', () async {
    final other = _Server();
    await other.start();
    addTearDown(other.stop);
    await GravixSignalStandby.open(other.url, 'blr1-card'); // the oldest
    for (var i = 0; i < 4; i++) {
      clock = clock.add(const Duration(seconds: 1));
      await GravixSignalStandby.open(server.url, 'old$i');
    }
    expect(GravixSignalStandby.state(other.url, 'blr1-card').state, 'open', reason: 'only one to its host');
    expect(GravixSignalStandby.state(server.url, 'old0').state, 'none', reason: 'oldest duplicate');
    for (var i = 1; i < 4; i++) {
      expect(GravixSignalStandby.state(server.url, 'old$i').state, 'open', reason: 'old$i');
    }
  });

  test('idempotent: a call while one is opening joins it; a young one is kept', () async {
    final a = GravixSignalStandby.open(server.url, 'tok');
    final b = GravixSignalStandby.open(server.url, 'tok');
    expect(await a, isTrue);
    expect(await b, isTrue);
    clock = clock.add(const Duration(seconds: 44));
    expect(await GravixSignalStandby.open(server.url, 'tok'), isTrue);
    expect(server.heads, 1, reason: 'one warm-up for three calls within 45 s');
  });

  test('rotation at 45 s: a replacement is opened; expiry at 110 s: the join does not use it', () async {
    await GravixSignalStandby.open(server.url, 'tok');
    clock = clock.add(const Duration(seconds: 46));
    expect(GravixSignalStandby.state(server.url, 'tok').ageMs, 46000);
    await GravixSignalStandby.open(server.url, 'tok');
    expect(server.heads, 2);
    expect(GravixSignalStandby.state(server.url, 'tok').ageMs, 0, reason: 'the replacement is the one kept');

    clock = clock.add(const Duration(seconds: 111));
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    expect(taken.outcome, 'expired');
    expect(taken.usable, isFalse);
    expect(taken.ageMs, 111000);
  });

  test('at most 4 kept: the oldest goes', () async {
    for (var i = 0; i < 5; i++) {
      await GravixSignalStandby.open(server.url, 'tok$i');
      clock = clock.add(const Duration(seconds: 1));
    }
    expect(GravixSignalStandby.state(server.url, 'tok0').state, 'none');
    for (var i = 1; i < 5; i++) {
      expect(GravixSignalStandby.state(server.url, 'tok$i').state, 'open', reason: 'tok$i');
    }
  });

  test('the join waits for one still opening (awaited), up to its bound', () async {
    final gate = Completer<void>();
    GravixSignalStandby.warm = (client, uri) async {
      await gate.future;
      return true;
    };
    addTearDown(
      () => GravixSignalStandby.warm = (c, u) async {
        final r = await (await c.openUrl('HEAD', u)).close();
        await r.drain<void>();
        return r.persistentConnection;
      },
    );
    unawaited(GravixSignalStandby.open(server.url, 'tok'));
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'opening');
    final taking = GravixSignalStandby.take(server.url, 'tok', wait: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    final taken = await taking;
    expect(taken.outcome, 'awaited');
    expect(taken.usable, isTrue);
    GravixSignalStandby.release(taken.client);

    // one that never finishes: the join gives up after its bound, dials cold
    GravixSignalStandby.warm = (client, uri) => Completer<bool>().future;
    unawaited(GravixSignalStandby.open(server.url, 'slow'));
    final watch = Stopwatch()..start();
    GravixSignalStandby.now = DateTime.now;
    final late = await GravixSignalStandby.take(server.url, 'slow', wait: const Duration(milliseconds: 150));
    expect(late.usable, isFalse);
    expect(late.outcome, 'dead');
    expect(watch.elapsedMilliseconds, lessThan(1500));
  });

  test('a host that does not answer: open() is false, state dead, the join is told dead', () async {
    final dead = 'ws://127.0.0.1:1'; // nothing listens on port 1
    expect(await GravixSignalStandby.open(dead, 'tok'), isFalse);
    expect(GravixSignalStandby.state(dead, 'tok').state, 'dead');
    final taken = await GravixSignalStandby.take(dead, 'tok');
    expect(taken.outcome, 'dead');
    expect(taken.usable, isFalse);
  });

  test('warm connection closed by the server meanwhile: the upgrade still works, reused=false', () async {
    await server.stop();
    server = _Server();
    await server.start(idle: const Duration(milliseconds: 200));
    await GravixSignalStandby.open(server.url, 'tok');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    expect(taken.outcome, 'used'); // the client cannot know yet
    final ws = await _dial(server.url, taken.client);
    expect(server.accepts, 2);
    expect(GravixSignalStandby.connectsOf(taken.client), taken.connectsAtTake + 1, reason: 'reported as reused: false');
    GravixSignalStandby.release(taken.client);
    await ws.dispose();
  });

  test('warm connection dropped silently (black hole): the join dials cold within the bound', () async {
    // a proxy that forwards the warm-up, then swallows every later byte on that
    // connection (a carrier NAT that dropped the mapping without a RST)
    final http = await HttpServer.bind('127.0.0.1', 0);
    http.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen(ws.add);
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    var accepts = 0;
    final sockets = <Socket>[];
    final proxy = await ServerSocket.bind('127.0.0.1', 0);
    proxy.listen((c) async {
      final n = ++accepts;
      final up = await Socket.connect('127.0.0.1', http.port);
      sockets
        ..add(c)
        ..add(up);
      var requests = 0;
      c.listen((d) {
        if (n == 1 && ++requests > 1) return; // first connection: only the HEAD gets through
        up.add(d);
      }, onError: (_) {});
      up.listen(c.add, onError: (_) {});
    });
    final url = 'ws://127.0.0.1:${proxy.port}';
    final saved = kGravixStandbyUpgradeTimeout;
    kGravixStandbyUpgradeTimeout = const Duration(milliseconds: 300);
    try {
      expect(await GravixSignalStandby.open(url, 'tok'), isTrue);
      final taken = await GravixSignalStandby.take(url, 'tok');
      expect(taken.usable, isTrue);
      final watch = Stopwatch()..start();
      final ws = await _dial(url, taken.client);
      expect(watch.elapsedMilliseconds, lessThan(2000));
      expect(accepts, 2, reason: 'the fresh dial opened its own connection');
      expect(ws.gravixDial?.path, 'redial');
      GravixSignalStandby.release(taken.client);
      await ws.dispose();
    } finally {
      kGravixStandbyUpgradeTimeout = saved;
      for (final s in sockets) {
        s.destroy();
      }
      await proxy.close();
      await http.close(force: true);
    }
  });

  test(
    'upgrade reached the server, the answer is lost: fresh dial at the bound, the abandoned session is closed',
    () async {
      // field 2026-09-30: the SFU started a session at the tap from the upgrade over
      // the standby connection; nothing came back. The proxy forwards everything
      // client -> server, and on the FIRST connection nothing server -> client after
      // the warm-up's response.
      final serverSockets = <WebSocket>[];
      final closed = <int>[];
      final http = await HttpServer.bind('127.0.0.1', 0);
      http.listen((req) async {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          final n = serverSockets.length;
          serverSockets.add(ws);
          ws.listen(ws.add, onDone: () => closed.add(n), onError: (_) {});
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });
      var accepts = 0;
      final sockets = <Socket>[];
      final proxy = await ServerSocket.bind('127.0.0.1', 0);
      proxy.listen((c) async {
        final n = ++accepts;
        final up = await Socket.connect('127.0.0.1', http.port);
        sockets
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
      final url = 'ws://127.0.0.1:${proxy.port}';
      try {
        expect(await GravixSignalStandby.open(url, 'tok', rttHintMs: 10), isTrue);
        final taken = await GravixSignalStandby.take(url, 'tok');
        expect(taken.upgradeBound, kGravixStandbyUpgradeFloor, reason: '3 x 10 ms is below the floor');
        final watch = Stopwatch()..start();
        final ws = await GravixRtcWebSocket.connect(Uri.parse('$url/rtc?x=1'), preconnected: taken);
        final ms = watch.elapsedMilliseconds;
        expect(ms, greaterThanOrEqualTo(kGravixStandbyUpgradeFloor.inMilliseconds - 20));
        expect(ms, lessThan(kGravixStandbyUpgradeFloor.inMilliseconds + 700), reason: 'redialled at the bound');
        expect(ws.gravixDial?.path, 'redial');
        expect(ws.gravixDial?.stalledAfterMs, kGravixStandbyUpgradeFloor.inMilliseconds);
        expect(accepts, 2);
        // the server got both upgrades; the first (abandoned) one is closed, the
        // fresh one is alive
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(serverSockets.length, 2);
        expect(closed, [0], reason: 'the abandoned session was closed, the fresh one was not');
        GravixSignalStandby.release(taken.client);
        await ws.dispose();
      } finally {
        for (final s in sockets) {
          s.destroy();
        }
        await proxy.close();
        await http.close(force: true);
      }
    },
  );

  test('a normal warm upgrade is path standby, not raced', () async {
    await GravixSignalStandby.open(server.url, 'tok');
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    final ws = await GravixRtcWebSocket.connect(Uri.parse('${server.url}/rtc?x=1'), preconnected: taken);
    expect(ws.gravixDial?.path, 'standby');
    expect(server.accepts, 1, reason: 'no fresh dial');
    GravixSignalStandby.release(taken.client);
    await ws.dispose();
  });

  test('upgrade bound: 3 x RTT within 0.5 - 1.5 s, 1.5 s without an RTT', () {
    expect(gravixStandbyUpgradeBound(null), const Duration(milliseconds: 1500));
    expect(gravixStandbyUpgradeBound(10), const Duration(milliseconds: 500));
    expect(gravixStandbyUpgradeBound(171), const Duration(milliseconds: 513));
    expect(gravixStandbyUpgradeBound(400), const Duration(milliseconds: 1200));
    expect(gravixStandbyUpgradeBound(900), const Duration(milliseconds: 1500));
  });

  test('reopenAll (app resumed): the old connection is closed at once and a new one opened', () async {
    await GravixSignalStandby.open(server.url, 'tok');
    expect(server.accepts, 1);
    final reopening = GravixSignalStandby.reopenAll();
    // the suspect one is not handed out while its replacement opens
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'opening');
    await reopening;
    expect(server.accepts, 2);
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'open');
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    final ws = await _dial(server.url, taken.client);
    expect(server.accepts, 2, reason: 'the join used the reopened connection');
    GravixSignalStandby.release(taken.client);
    await ws.dispose();
  });
}

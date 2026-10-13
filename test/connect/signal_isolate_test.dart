// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixSignalIsolate (2026-10-12, opt-in): the signalling WebSocket and the
// standby pool in a background isolate (websocket/signal_isolate_io.dart).
// Against real local servers: the bridge must carry the same bytes, the same
// errors, the same close / leave order and the same standby reuse as the
// in-isolate dial -- and, with the switch off, nothing may change at all.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_signal_isolate.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/io.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/signal_isolate.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/standby.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

/// A signal server behind a TCP proxy that counts accepted connections (so
/// "the upgrade reused the warm connection" is a count), recording what each
/// socket received, in order.
class _Server {
  late HttpServer http;
  late ServerSocket proxy;
  int accepts = 0;
  int upgrades = 0;

  /// Received on each socket: 'leave', 'offer', 'trickle', ..., `bytes:<n>`
  /// for raw echo frames, then 'closed'.
  final log = <List<String>>[];
  final sockets = <WebSocket>[];

  /// Resume upgrades (`reconnect=1`), answered with a ReconnectResponse.
  final resumes = <Uri>[];

  /// Echo raw frames back (no JoinResponse); otherwise a signal server.
  bool echo = false;

  /// How long an upgrade waits before it is answered.
  Duration upgradeDelay = Duration.zero;
  final _proxied = <Socket>[];

  String get url => 'ws://127.0.0.1:${proxy.port}';

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.idleTimeout = const Duration(minutes: 3);
    http.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        upgrades++;
        if (upgradeDelay > Duration.zero) await Future<void>.delayed(upgradeDelay);
        final WebSocket ws;
        try {
          ws = await WebSocketTransformer.upgrade(req);
        } catch (_) {
          return;
        }
        sockets.add(ws);
        final l = <String>[];
        log.add(l);
        ws.listen(
          (dynamic m) {
            if (echo) {
              l.add('bytes:${(m as List<int>).length}');
              ws.add(m);
              return;
            }
            final r = lk_rtc.SignalRequest.fromBuffer(m as List<int>);
            l.add(r.whichMessage().name);
          },
          onDone: () => l.add('closed'),
          onError: (Object _) => l.add('closed'),
        );
        if (!echo) {
          if (req.uri.queryParameters['reconnect'] == '1') {
            resumes.add(req.uri);
            ws.add(lk_rtc.SignalResponse(reconnect: lk_rtc.ReconnectResponse()).writeToBuffer());
          } else {
            ws.add(lk_rtc.SignalResponse(join: fakeJoinResponse(subscriberPrimary: true)).writeToBuffer());
          }
        }
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((c) async {
      accepts++;
      final up = await Socket.connect(InternetAddress.loopbackIPv4, http.port);
      _proxied
        ..add(c)
        ..add(up);
      c.cast<List<int>>().pipe(up).catchError((_) {});
      up.cast<List<int>>().pipe(c).catchError((_) {});
    });
  }

  Future<void> stop() async {
    for (final s in _proxied) {
      s.destroy();
    }
    await proxy.close();
    await http.close(force: true);
  }
}

class _NoOverrides extends HttpOverrides {}

Future<void> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Server server;

  setUp(() async {
    installRecoveryChannelMocks();
    HttpOverrides.global = null;
    server = _Server();
    await server.start();
  });

  tearDown(() async {
    GravixSignalIsolate.enabled = false;
    await GravixSignalStandby.closeAll();
    await GravixSignalIsolateRuntime.debugShutdown();
    await server.stop();
  });

  ConnectOptions connectOptions() => ConnectOptions(timeouts: fastTimeouts(connection: const Duration(seconds: 3)));

  test('the switch: off by default; off = the dial and the standby stay on this isolate', () async {
    expect(GravixSignalIsolate.enabled, isFalse);
    server.echo = true;
    final ws = await GravixRtcWebSocket.connect(Uri.parse('${server.url}/rtc'));
    expect(ws, isA<GravixRtcWebSocketIO>());
    expect(ws.gravixViaIsolate, isFalse);
    await ws.dispose();

    expect(await GravixSignalStandby.open(server.url, 'tok'), isTrue);
    final taken = await GravixSignalStandby.take(server.url, 'tok');
    expect(taken.client, isA<HttpClient>(), reason: 'a dart:io client of this isolate, as before');
    GravixSignalStandby.release(taken.client);

    // a join's standby block carries no signalIsolate key with the switch off
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    server.echo = false;
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    expect(sc.gravixStandby!.containsKey('signalIsolate'), isFalse);
  });

  test('on: the socket lives in the signal isolate; bytes go both ways, in order', () async {
    GravixSignalIsolate.enabled = true;
    server.echo = true;
    final got = <int>[];
    var closed = false;
    final ws = await GravixRtcWebSocket.connect(
      Uri.parse('${server.url}/rtc'),
      options: WebSocketEventHandlers(
        onData: (dynamic d) => got.add((d as List<int>).length),
        onDispose: () => closed = true,
      ),
    );
    expect(ws, isNot(isA<GravixRtcWebSocketIO>()));
    expect(ws.gravixViaIsolate, isTrue);
    for (var i = 1; i <= 200; i++) {
      ws.send(List<int>.filled(i, i & 0xff));
    }
    await _until(() => got.length == 200);
    expect(got, [for (var i = 1; i <= 200; i++) i], reason: 'every frame, in the order it was sent');
    expect(server.log.single.take(3), ['bytes:1', 'bytes:2', 'bytes:3']);
    await ws.dispose();
    // as in websocket/io.dart: our own close reaches onDispose too, shortly
    // after dispose() resolved (measured there: never before, always within 300 ms)
    await _until(() => closed, timeout: const Duration(milliseconds: 500));
    expect(closed, isTrue);
    await _until(() => server.log.single.last == 'closed');
    expect(server.log.single.last, 'closed');
  });

  test('on: the standby pool lives in the signal isolate; the join takes it and reuses the warm connection', () async {
    GravixSignalIsolate.enabled = true;
    expect(await GravixSignalStandby.open(server.url, 'tok', rttHintMs: 6), isTrue);
    expect(server.accepts, 1);
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'open', reason: 'the synchronous state mirrors it');
    expect(GravixSignalStandby.state(server.url, 'other').state, 'none');

    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    final joined = sc.events.waitFor<SignalJoinResponseEvent>(duration: const Duration(seconds: 3));
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    await joined;
    expect(server.accepts, 1, reason: 'the upgrade went over the warm connection');
    final sb = sc.gravixStandby!;
    expect(sb['outcome'], 'used');
    expect(sb['path'], 'standby');
    expect(sb['reused'], isTrue);
    expect(sb['boundMs'], 500, reason: '3 x 6 ms, at the 0.5 s floor');
    expect(sb['signalIsolate'], isTrue);
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'none', reason: 'taken');
  });

  test('on: no standby for the url -> outcome none, a cold dial in the signal isolate', () async {
    GravixSignalIsolate.enabled = true;
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    expect(sc.gravixStandby!['outcome'], 'none');
    expect(sc.gravixStandby!['reused'], isNull);
    expect(sc.gravixStandby!['signalIsolate'], isTrue);
    expect(sc.connectionState, ConnectionState.connected);
  });

  test('on: a resume dials through the signal isolate too (the old socket closed, ReconnectResponse read)', () async {
    GravixSignalIsolate.enabled = true;
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    final joined = sc.events.waitFor<SignalJoinResponseEvent>(duration: const Duration(seconds: 3));
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    await joined;
    final resumed = sc.events.waitFor<SignalReconnectResponseEvent>(duration: const Duration(seconds: 3));
    await sc.connect(
      server.url,
      'tok',
      connectOptions: connectOptions(),
      roomOptions: const RoomOptions(),
      reconnect: true,
    );
    await resumed;
    expect(sc.connectionState, ConnectionState.connected);
    expect(server.resumes.single.queryParameters['sid'], 'PA_me', reason: 'the resume names the session');
    await _until(() => server.log.first.contains('closed'));
    expect(server.log.first, ['closed'], reason: 'the join socket was closed by the resume (no leave)');
  });

  test('on: the leave written on dispose reaches the server before the socket closes', () async {
    GravixSignalIsolate.enabled = true;
    final sc = SignalClient(GravixRtcWebSocket.connect);
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    await sc.dispose();
    await _until(() => server.log.isNotEmpty && server.log.single.contains('closed'));
    expect(server.log.single, ['leave', 'closed']);
  });

  test('on: the server closing the socket is a signal disconnect', () async {
    GravixSignalIsolate.enabled = true;
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    final gone = sc.events.waitFor<SignalDisconnectedEvent>(duration: const Duration(seconds: 3));
    await server.sockets.single.close();
    expect((await gone).reason, DisconnectReason.disconnected);
    expect(sc.connectionState, ConnectionState.disconnected);
  });

  test('on: requests are written in order (a burst of offers and a leave)', () async {
    GravixSignalIsolate.enabled = true;
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    for (var i = 0; i < 20; i++) {
      sc.sendMuteTrack('TR_$i', i.isEven);
    }
    await sc.sendLeave();
    await _until(() => server.log.single.length >= 21);
    expect(server.log.single.take(21), [...List.filled(20, 'mute'), 'leave']);
  });

  test('on: dial errors keep their types (refused -> WebSocketException; unanswered -> dial timeout)', () async {
    GravixSignalIsolate.enabled = true;
    // nothing listens on the port any more
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();
    await expectLater(
      GravixRtcWebSocket.connect(Uri.parse('ws://127.0.0.1:$port/rtc')),
      throwsA(isA<WebSocketException>()),
    );
    // a connection that is up, an upgrade never answered within the bound
    server.upgradeDelay = const Duration(seconds: 5);
    final e = await GravixRtcWebSocket.connect(
      Uri.parse('${server.url}/rtc'),
      connectTimeout: const Duration(milliseconds: 300),
    ).then<Object>((ws) => ws, onError: (Object e) => e);
    expect(e, isA<GravixDialTimeoutException>());
    expect((e as GravixDialTimeoutException).noConnection, isFalse, reason: 'the connection was up');
    expect(e, isA<TimeoutException>(), reason: 'the engine reads a dial timeout as a TimeoutException');
  });

  test('on: a dial superseded by cleanUp closes its socket when it lands (a fresh join gets the leave)', () async {
    GravixSignalIsolate.enabled = true;
    server.upgradeDelay = const Duration(milliseconds: 150);
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    final dialing = sc
        .connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions())
        .then<Object?>((_) => null, onError: (Object e) => e);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await sc.cleanUp();
    expect(await dialing, isNotNull, reason: 'the superseded connect fails');
    await _until(() => server.log.isNotEmpty && server.log.single.contains('closed'));
    expect(server.log.single, ['leave', 'closed']);
  });

  test('on, but the app installed HttpOverrides: this dial stays on this isolate', () async {
    GravixSignalIsolate.enabled = true;
    server.echo = true;
    HttpOverrides.global = _NoOverrides();
    addTearDown(() => HttpOverrides.global = null);
    final ws = await GravixRtcWebSocket.connect(Uri.parse('${server.url}/rtc'));
    expect(ws, isA<GravixRtcWebSocketIO>());
    await ws.dispose();
  });

  test('on, HttpOverrides installed: a standby take meant for the signal isolate takes nothing', () async {
    GravixSignalIsolate.enabled = true;
    expect(await GravixSignalStandby.open(server.url, 'tok'), isTrue);
    HttpOverrides.global = _NoOverrides();
    addTearDown(() => HttpOverrides.global = null);
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    expect(sc.gravixStandby!['outcome'], 'none');
    expect(sc.gravixStandby!['reused'], isNull);
    expect(sc.gravixStandby!['signalIsolate'], isFalse);
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'open', reason: 'still in the pool for a later join');
  });

  // 2026-10-13: an app whose HttpOverrides only tune its own HTTP clients (e.g.
  // HttpOverrides.global for pooled-client timeouts) says so, and its signal
  // dials and standbys run in the signal isolate anyway.
  test('on, HttpOverrides installed, ignoreHttpOverrides: this dial goes through the signal isolate', () async {
    GravixSignalIsolate.enabled = true;
    GravixSignalIsolate.ignoreHttpOverrides = true;
    addTearDown(() => GravixSignalIsolate.ignoreHttpOverrides = false);
    server.echo = true;
    HttpOverrides.global = _NoOverrides();
    addTearDown(() => HttpOverrides.global = null);
    final ws = await GravixRtcWebSocket.connect(Uri.parse('${server.url}/rtc'));
    expect(ws.gravixViaIsolate, isTrue);
    await ws.dispose();
  });

  test('on, HttpOverrides installed, ignoreHttpOverrides: the join takes the standby in the signal isolate', () async {
    GravixSignalIsolate.enabled = true;
    GravixSignalIsolate.ignoreHttpOverrides = true;
    addTearDown(() => GravixSignalIsolate.ignoreHttpOverrides = false);
    HttpOverrides.global = _NoOverrides();
    addTearDown(() => HttpOverrides.global = null);
    expect(await GravixSignalStandby.open(server.url, 'tok'), isTrue);
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    expect(sc.connectionState, ConnectionState.connected);
    expect(sc.gravixStandby!['signalIsolate'], isTrue);
    expect(sc.gravixStandby!['outcome'], isNot('none'), reason: 'the warm connection carried the join');
    await sc.cleanUp();
  });

  test('ignoreHttpOverrides off (default): HttpOverrides keep the dial on this isolate, as before', () async {
    expect(GravixSignalIsolate.ignoreHttpOverrides, isFalse);
    GravixSignalIsolate.enabled = true;
    HttpOverrides.global = _NoOverrides();
    addTearDown(() => HttpOverrides.global = null);
    expect(GravixSignalIsolateRuntime.routes(null), isFalse);
    GravixSignalIsolate.ignoreHttpOverrides = true;
    addTearDown(() => GravixSignalIsolate.ignoreHttpOverrides = false);
    expect(GravixSignalIsolateRuntime.routes(null), isTrue);
  });

  test('the signal isolate cannot start: the join dials on this isolate', () async {
    // a setup hook that cannot be sent to an isolate makes the start fail
    final unsendable = RawReceivePort();
    addTearDown(unsendable.close);
    GravixSignalIsolateRuntime.debugIsolateSetup = () => unsendable.sendPort.send(null);
    addTearDown(() => GravixSignalIsolateRuntime.debugIsolateSetup = null);
    GravixSignalIsolate.enabled = true;
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    await sc.connect(server.url, 'tok', connectOptions: connectOptions(), roomOptions: const RoomOptions());
    expect(sc.connectionState, ConnectionState.connected);
    expect(sc.gravixStandby!['signalIsolate'], isFalse);
    expect(sc.gravixStandby!['outcome'], 'none');
  });

  test('rollback: switched off again, the next join dials on this isolate', () async {
    GravixSignalIsolate.enabled = true;
    server.echo = true;
    final a = await GravixRtcWebSocket.connect(Uri.parse('${server.url}/rtc'));
    expect(a.gravixViaIsolate, isTrue);
    GravixSignalIsolate.enabled = false;
    final b = await GravixRtcWebSocket.connect(Uri.parse('${server.url}/rtc'));
    expect(b, isA<GravixRtcWebSocketIO>());
    // the one already open keeps working until it ends
    a.send(const [1, 2, 3]);
    await _until(() => server.log.first.isNotEmpty);
    expect(server.log.first.first, 'bytes:3');
    await a.dispose();
    await b.dispose();
  });

  test('switching on closes standby connections opened on this isolate (they cannot be handed over)', () async {
    expect(await GravixSignalStandby.open(server.url, 'tok'), isTrue);
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'open');
    GravixSignalIsolate.enabled = true;
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'none');
    GravixSignalIsolate.enabled = false;
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'none', reason: 'closed, not kept for later');
  });

  test('on: reopenAll / closeAll reach the pool in the signal isolate', () async {
    GravixSignalIsolate.enabled = true;
    expect(await GravixSignalStandby.open(server.url, 'tok'), isTrue);
    await GravixSignalStandby.reopenAll();
    expect(server.accepts, 2, reason: 'the connection was replaced');
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'open');
    await GravixSignalStandby.closeAll();
    expect(GravixSignalStandby.state(server.url, 'tok').state, 'none');
  });

  test('the signal isolate going away fails pending dials and reports live sockets closed', () async {
    GravixSignalIsolate.enabled = true;
    server.echo = true;
    var closed = false;
    final ws = await GravixRtcWebSocket.connect(
      Uri.parse('${server.url}/rtc'),
      options: WebSocketEventHandlers(onDispose: () => closed = true),
    );
    expect(ws.gravixViaIsolate, isTrue);
    await GravixSignalIsolateRuntime.debugShutdown();
    expect(closed, isTrue);
    // the next dial starts a new one
    final again = await GravixRtcWebSocket.connect(Uri.parse('${server.url}/rtc'));
    expect(again.gravixViaIsolate, isTrue);
    await again.dispose();
    await ws.dispose();
  });
}

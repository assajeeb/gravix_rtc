// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Device recheck 2026-10-11 06:10-06:25 (Xiaomi on an iPhone hotspot, Network
// Link Conditioner "Very Bad Network": RTT ~1-2 s, 25-35 % loss): joins failed
// on 33a1032 ("[WebSocketIO] not connected within 10000 ms, aborting the dial":
// TCP + TLS were up, the upgrade's answer had not come back), and on main
// 36862c4 too (the viewer: "could not connect ... TimeoutException after 10 s").
// Every version gave the signal dial Timeouts.connection (10 s) and failed the
// join past it, on a path that works, only slowly.
//
// Scaled down: Timeouts.connection 300 ms, a "slow" path takes 450 ms (the
// device's 12-15 s against 10 s). The path is a dart:io override
// (support/blackhole_path.dart). Only the base API is used, so this file also
// runs against the unhedged SDK (where it fails).
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/reconnect_policy.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';

import 'dart:io';

import '../support/blackhole_path.dart';
import '../support/fake_rtc.dart';

class _KeepTrying extends ReconnectPolicy {
  @override
  int? nextRetryDelayInMs(ReconnectContext context) => 10;
}

const url = 'ws://blr1.gravixcloud.run';
const bound = Duration(milliseconds: 300);
const slow = Duration(milliseconds: 450);

void main() {
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
    await server.stop();
  });

  ConnectOptions connectOptions() => ConnectOptions(
    timeouts: fastTimeouts(connection: bound, peerConnection: const Duration(seconds: 2)),
  );
  // (the same-url retry's short dial is below the slow path too, so only the
  // full reconnect's own dial can carry the rejoin)
  RoomOptions roomOptions() => RoomOptions(
    reconnectPolicy: _KeepTrying(),
    // (signalDialCap: off by default since the 2026-10-11 interim correction)
    recovery: const GravixRecoveryOptions(
      sameUrlRetryDialTimeout: Duration(milliseconds: 200),
      signalDialCap: Duration(seconds: 30),
    ),
  );

  Future<String> outcome(Future<void> f, {Duration within = const Duration(seconds: 3)}) => f
      .then<String>((_) => 'connected', onError: (Object e) => 'failed: $e')
      .timeout(within, onTimeout: () => 'still waiting');

  group('signal client, first join', () {
    test('TCP + TLS slower than the dial timeout: the join still connects (one upgrade)', () async {
      path.slow = slow;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      final watch = Stopwatch()..start();
      // base: aborted at 300 ms, the connect fails
      expect(
        await outcome(sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: roomOptions())),
        'connected',
      );
      // ignore: avoid_print
      print('RESULT slow_tcp_tls_join_ms=${watch.elapsedMilliseconds} connects=${path.slowConnects}');
      expect(sc.connectionState.name, 'connected');
      // the first connection carried the join; a parallel one (started at the
      // dial timeout) was closed before anything was written on it
      expect(path.slowConnects.first.connected, isTrue, reason: '${path.slowConnects}');
      expect(path.slowConnects.skip(1).every((c) => c.cancelled), isTrue, reason: '${path.slowConnects}');
      expect(server.upgrades, 1);
      await sc.dispose();
    });

    test('the upgrade answered after the dial timeout (TCP + TLS fast): the join still connects', () async {
      server.upgradeDelay = slow;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      // base: "Connection closed before full header was received" at 300 ms (the
      // device log of 33a1032 at 06:14)
      expect(
        await outcome(sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: roomOptions())),
        'connected',
      );
      expect(server.upgrades, 1, reason: 'a connected dial waiting for its answer is not raced');
      await sc.dispose();
    });

    test('a very slow first connection, then the path improves: the parallel dial wins', () async {
      path.slow = const Duration(seconds: 10);
      final sc = SignalClient(GravixRtcWebSocket.connect);
      final watch = Stopwatch()..start();
      final connecting = outcome(sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: roomOptions()));
      await settle(150);
      path.slow = null; // better now: a connection started from here is fast
      // base: aborted at 300 ms
      expect(await connecting, 'connected');
      expect(watch.elapsedMilliseconds, lessThan(bound.inMilliseconds + 400));
      expect(path.slowConnects.single.cancelled, isTrue, reason: 'the slow first connection was left open');
      expect(server.upgrades, 1);
      await sc.dispose();
    });

    test('blackholed, the path comes back mid-dial: a parallel dial started after it connects', () async {
      path.up = false;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      final connecting = outcome(sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: roomOptions()));
      await settle(450);
      path.up = true;
      final back = Stopwatch()..start();
      // base: the dial was aborted at 300 ms and the validate request at 600 ms
      expect(await connecting, 'connected');
      // ignore: avoid_print
      print('RESULT blackhole_mid_dial_connected_after_path_back_ms=${back.elapsedMilliseconds}');
      expect(back.elapsedMilliseconds, lessThan(1000));
      await settle(50);
      expect(path.blackholed.every((c) => c.cancelled), isTrue, reason: '${path.blackholed}');
      await sc.dispose();
    });
  });

  group('engine and room', () {
    late Engine engine;
    late FakePcFactory pcs;

    Engine newEngine() {
      pcs = FakePcFactory();
      autoConnectPcs(pcs);
      return Engine(
        connectOptions: connectOptions(),
        roomOptions: roomOptions(),
        signalClient: FakeConnectivitySignalClient(GravixRtcWebSocket.connect),
        peerConnectionCreate: pcs.create,
      );
    }

    test('engine first join over a slow path joins', () async {
      engine = newEngine();
      addTearDown(engine.dispose);
      path.slow = slow;
      expect(await outcome(engine.connect(url, 'tok')), 'connected');
      expect(engine.connectionState.name, 'connected');
    });

    test('room join on a cloud url over a slow path joins (the region list fetch does not hold it)', () async {
      engine = newEngine();
      final room = Room(engine: engine, roomOptions: roomOptions());
      addTearDown(room.dispose);
      path.slow = slow;
      final watch = Stopwatch()..start();
      expect(
        await outcome(
          room.connect(
            url,
            'tok',
            connectOptions: ConnectOptions(
              timeouts: fastTimeouts(connection: bound, peerConnection: const Duration(seconds: 2)),
              joinRetries: 0,
            ),
          ),
        ),
        'connected',
      );
      // ignore: avoid_print
      print('RESULT slow_room_join_ms=${watch.elapsedMilliseconds} connects=${path.slowConnects}');
      expect(room.connectionState.name, 'connected');
    });

    test('field order on a slow path: resume x2 time out, the full reconnect connects', () async {
      engine = newEngine();
      addTearDown(engine.dispose);
      await engine.connect(url, 'tok');
      final restarted = <EngineRestartedEvent>[];
      final listener = engine.createListener()..on<EngineRestartedEvent>(restarted.add);
      addTearDown(listener.dispose);

      path.slow = slow;
      expect(engine.gravixRequestResume('slow path test'), isTrue);
      // base: every full reconnect dial is aborted at 300 ms, and its validate,
      // same-url retry, ... with it, for as long as the path stays slow
      expect(
        await eventually(() => restarted.isNotEmpty, timeout: const Duration(seconds: 4)),
        isTrue,
        reason: '${path.slowConnects}',
      );
      expect(engine.connectionState.name, 'connected');
    });
  });
}

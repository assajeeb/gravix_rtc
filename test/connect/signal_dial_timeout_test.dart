// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Real-device soak 2026-10-11 02:35-02:39 (runs/s01_fix): the office ISP
// blackholed the route to DigitalOcean for ~2 min while Wi-Fi stayed up. Every
// TCP connect of the reconnect hung until Android gave up on the SYN (errno 110,
// Infinix ~133 s, Xiaomi ~31 s):
//  - the signal WebSocket dials were abandoned by their 10 s Future.timeout, but
//    their sockets kept connecting until the OS timeout (02:38:11, :21, :34);
//  - the full reconnect's /rtc/validate GET (run after the dial timed out) had no
//    timeout at all: it held the host's reconnect until 02:38:44, ~46 s after the
//    path was back (02:37:58); the guest lost 31 s twice on it;
//  - the failover's /settings/regions GET had none either (guest, 31 s).
// Here the path is a dart:io override: blackholed, every TCP connect hangs
// forever (a SYN nobody answers) and records whether the SDK aborted it; up, the
// connect goes to a local signal server. Only the base API is used, so this file
// also runs against the unfixed SDK (where it fails).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/reconnect_policy.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';

import '../support/blackhole_path.dart';
import '../support/fake_rtc.dart';

/// Retries for as long as the test runs (FastPolicy stops after 8).
class _KeepTrying extends ReconnectPolicy {
  @override
  int? nextRetryDelayInMs(ReconnectContext context) => 10;
}

// a cloud url (the region failover runs), plain ws so the override sees the dial
const url = 'ws://blr1.gravixcloud.run';
const bound = Duration(milliseconds: 300);
const retryBound = Duration(milliseconds: 200);
// (2026-10-11, signalDialCap) a fresh join's dial: raced every [bound], up to 3
const cap = Duration(milliseconds: 900);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalSignalServer server;
  late BlackholePath path;

  setUp(() async {
    installRecoveryChannelMocks();
    // real HttpClients (the test binding's mock answers every request 400)
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
  RoomOptions roomOptions() => RoomOptions(
    reconnectPolicy: _KeepTrying(),
    // (silentHostFailFast off: these steps -- the validate request after a dial
    // with no connection up included -- are what this file bounds; with it on, the
    // validate is skipped and the race shortened: silent_host_failover_test.dart)
    recovery: const GravixRecoveryOptions(
      sameUrlRetryDialTimeout: retryBound,
      signalDialCap: cap,
      silentHostFailFast: false,
    ),
  );

  /// Every connect made while the path was blackholed was aborted, each within
  /// [limit] of its start.
  void expectAllAborted(Duration limit) {
    expect(path.blackholed, isNotEmpty);
    for (final c in path.blackholed) {
      expect(c.cancelled, isTrue, reason: '$c left pending (a leaked socket): ${path.blackholed}');
      expect(c.cancelledAfter!, lessThanOrEqualTo(limit), reason: '$c aborted late');
    }
  }

  group('signal client, blackholed path', () {
    test('first join: the dial (raced every bound, up to its cap) and the validate request give up and abort '
        'their sockets', () async {
      path.up = false;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      final watch = Stopwatch()..start();
      Object? error;
      final done = sc
          .connect(url, 'tok', connectOptions: connectOptions(), roomOptions: roomOptions())
          .then<Object?>((_) => null, onError: (Object e) => error = e);
      // base: the validate GET waits for the OS (02:36:31 -> 02:38:44 on the Infinix)
      final finished = await done.then((_) => true).timeout(const Duration(seconds: 3), onTimeout: () => false);
      expect(finished, isTrue, reason: 'connect still waiting ${watch.elapsedMilliseconds} ms after it started');
      expect(error, isNotNull);
      expect(watch.elapsedMilliseconds, lessThan(cap.inMilliseconds + bound.inMilliseconds + 700));
      // a parallel connection every bound while none is up, then the validate
      expect(path.kinds.where((k) => k == 'dial').length, inInclusiveRange(3, 4), reason: '${path.blackholed}');
      expect(path.kinds.last, 'validate');
      expectAllAborted(cap + const Duration(milliseconds: 600));
      await sc.dispose();
    });

    test('resume dial: gives up at the bound and its pending socket is aborted, not left to the OS', () async {
      path.up = false;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      final watch = Stopwatch()..start();
      await expectLater(
        sc.connect(url, 'tok', connectOptions: connectOptions(), roomOptions: roomOptions(), reconnect: true),
        throwsA(anything),
      );
      expect(watch.elapsedMilliseconds, lessThan(bound.inMilliseconds + 700));
      // (a resume does not validate)
      expect(path.kinds, ['dial']);
      // base: the dial is abandoned at the bound but its SYN keeps going until the
      // OS gives up (errno 110 at 02:38:11 for a dial started at 02:36:02)
      await settle(100);
      expectAllAborted(bound + const Duration(milliseconds: 600));
      await sc.dispose();
    });
  });

  group('engine, blackholed path', () {
    late Engine engine;
    late FakePcFactory pcs;
    late FakeConnectivitySignalClient signal;
    tearDown(() async => engine.dispose());

    Engine newEngine({Duration? networkWaitProbeInterval}) {
      pcs = FakePcFactory();
      autoConnectPcs(pcs);
      signal = FakeConnectivitySignalClient(GravixRtcWebSocket.connect);
      final options = roomOptions();
      return Engine(
        connectOptions: connectOptions(),
        roomOptions: networkWaitProbeInterval == null
            ? options
            : options.copyWith(recovery: options.recovery.copyWith(networkWaitProbeInterval: networkWaitProbeInterval)),
        signalClient: signal,
        peerConnectionCreate: pcs.create,
      );
    }

    test('first join fails within its bounds, and joins once the path is back', () async {
      engine = newEngine();
      path.up = false;
      final watch = Stopwatch()..start();
      final first = await engine
          .connect(url, 'tok')
          .then<String>((_) => 'connected', onError: (Object e) => 'failed')
          .timeout(const Duration(seconds: 3), onTimeout: () => 'still waiting');
      expect(first, 'failed', reason: 'after ${watch.elapsedMilliseconds} ms');
      // ignore: avoid_print
      print(
        'RESULT first_join_blackholed_fail_ms=${watch.elapsedMilliseconds} (bound ${bound.inMilliseconds} ms) '
        'steps=${path.blackholed}',
      );
      expect(watch.elapsedMilliseconds, lessThan(cap.inMilliseconds + bound.inMilliseconds + 700));
      expectAllAborted(cap + const Duration(milliseconds: 600));

      path.up = true;
      await engine.connect(url, 'tok').timeout(const Duration(seconds: 3));
      expect(engine.connectionState.name, 'connected');
      expect(server.joins, 1);
    });

    test('reconnect (resume x2, then full with same-url retry and region failover): every step gives up at '
        'its bound, and it reconnects right after the path is back', () async {
      engine = newEngine();
      await engine.connect(url, 'tok');
      // the failover asks the server for its regions (the 5 s cache expired)
      engine.setRegionUrlProvider(RegionUrlProvider(url: url, token: 'tok')..settingsCacheTime = 0);
      final restarted = <EngineRestartedEvent>[];
      final listener = engine.createListener()..on<EngineRestartedEvent>(restarted.add);
      addTearDown(listener.dispose);

      path.up = false;
      // media stopped arriving: a resume (02:36:02 on both phones)
      expect(engine.gravixRequestResume('blackhole test'), isTrue);
      await settle(3500);
      final steps = path.kinds;
      // the resumes, then full reconnects that keep cycling (dial, validate,
      // same-url retry, validate, regions); base: stuck in the first validate
      expect(steps.where((k) => k == 'dial').length, greaterThanOrEqualTo(4), reason: '${path.blackholed}');
      expect(steps, contains('validate'), reason: '${path.blackholed}');
      expect(steps, contains('regions'), reason: '${path.blackholed}');

      path.up = true;
      final back = Stopwatch()..start();
      expect(
        await eventually(() => restarted.isNotEmpty, timeout: const Duration(seconds: 3)),
        isTrue,
        reason: 'not reconnected ${back.elapsedMilliseconds} ms after the path came back',
      );
      // ignore: avoid_print
      print(
        'RESULT reconnected_after_path_back_ms=${back.elapsedMilliseconds} (bound ${bound.inMilliseconds} ms) '
        'blackholed_steps=${path.blackholed.length}: ${path.blackholed}',
      );
      // one step in flight at most (its bound) and the next attempt
      expect(back.elapsedMilliseconds, lessThan(1500));
      expect(engine.connectionState.name, 'connected');
      await settle(cap.inMilliseconds + 100);
      expectAllAborted(cap + const Duration(milliseconds: 600));
      expect(server.openSockets, 1, reason: 'only the session socket is open');
    });

    test('F3 network wait: every reachability probe is aborted at its interval', () async {
      engine = newEngine(networkWaitProbeInterval: const Duration(milliseconds: 200));
      await engine.connect(url, 'tok');
      final restarted = <Object>[];
      final listener = engine.createListener()
        ..on<EngineRestartedEvent>(restarted.add)
        ..on<EngineResumedEvent>(restarted.add);
      addTearDown(listener.dispose);

      path.up = false;
      signal.online = false; // the reading says offline: the attempt waits and probes
      expect(engine.gravixRequestResume('blackhole test'), isTrue);
      await settle(2000);
      final probes = path.blackholed.where((c) => c.kind == 'probe').toList();
      expect(probes.length, greaterThanOrEqualTo(3), reason: '${path.blackholed}');
      for (final p in probes.take(probes.length - 1)) {
        // base: each probe's socket waits for the OS while the next one starts
        expect(p.cancelled, isTrue, reason: '$p left pending: ${path.blackholed}');
      }

      path.up = true; // the probe answers: reconnecting
      expect(await eventually(() => restarted.isNotEmpty, timeout: const Duration(seconds: 3)), isTrue);
      await settle(400);
      expectAllAborted(const Duration(milliseconds: 900));
    });
  });
}

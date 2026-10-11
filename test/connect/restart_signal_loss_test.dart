// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// RECHECK 2026-10-11 (REAL-DEVICE, Xiaomi viewer, Wi-Fi flapping 5 x [2 s off /
// 3 s on]): far-side video came back ~1 s or ~11-13 s after the last ON
// (fddb56e n=6: 0.7 / 1.5 / 7.7 / 12.1 / 12.7 / 13.4 s; 33a1032 n=3: 0.7 / 1.6 /
// 11.1 s). In all 9 runs every full reconnect that spanned an OFF lost its
// signal socket ("Signal disconnected during a reconnect; the reconnect handles
// it") and then kept waiting: 10 s (Timeouts.connection) for the primary peer
// connection, or, once ICE brought the subscriber back by itself, 10 s
// (Timeouts.peerConnection) for the publisher, whose offer could not be sent
// ("Could not send message, socket not connected" x7, r357). The bimodality is
// only where that dead wait ended relative to the network's return (fast runs:
// 0.8-6.5 s before it; slow runs: 9.3-9.7 s after).
//
// Now (GravixRecoveryOptions.restartAbortsOnSignalLoss) the full reconnect fails
// as soon as its own signal socket closes, and an attempt that failed that way
// while the device's network changed does not count against the reconnect
// budget. The tests above the option section use only APIs the base has.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/reconnect_policy.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

class _RecordingPolicy extends ReconnectPolicy {
  final retryCounts = <int>[];
  @override
  int? nextRetryDelayInMs(ReconnectContext context) {
    retryCounts.add(context.retryCount);
    return context.retryCount >= 8 ? null : 10;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late FakeConnectivitySignalClient signal;
  late Engine engine;
  late int restarted;
  DateTime? restartedAt;
  tearDown(() async => engine.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';
  int resumes(int from) => server.dials.skip(from).where(isResume).length;
  int rejoins(int from) => server.dials.skip(from).where((u) => !isResume(u)).length;

  /// A viewer (subscriber primary) with the device's timeouts (10 s).
  Future<void> start({RoomOptions? roomOptions, ReconnectPolicy? policy}) async {
    server = FakeSignalServer();
    signal = FakeConnectivitySignalClient(server.connect);
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(
      server,
      pcs,
      subscriberPrimary: true,
      signalClient: signal,
      roomOptions: roomOptions ?? RoomOptions(reconnectPolicy: policy ?? FastPolicy()),
      connection: const Duration(seconds: 10),
      peerConnection: const Duration(seconds: 10),
    );
    engine.gravixReachabilityProbe = (url, timeout) async => false;
    restarted = 0;
    restartedAt = null;
    engine.events.on<EngineRestartedEvent>((_) {
      restarted++;
      restartedAt ??= DateTime.now();
    });
  }

  void connectivity(List<ConnectivityResult> from, List<ConnectivityResult> to) =>
      signal.events.emit(SignalConnectivityChangedEvent(oldState: from, state: to));

  /// A full reconnect starts; its join is answered and its peer connections are
  /// created, still connecting (r357 22.117 "Waiting for engine to connect...").
  Future<void> fullReconnectWaitingForPcs() async {
    final before = pcs.all.length;
    unawaited(engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
    expect(await eventually(() => pcs.all.length >= before + 2), isTrue);
    await settle(50);
  }

  group('the full reconnect\'s signal socket closes while it waits', () {
    test('r357 shape: closed while waiting for the primary connection -> the reconnect goes on at once '
        '(not after the 10 s connection timeout)', () async {
      await start();
      final from = server.dials.length;
      await fullReconnectWaitingForPcs();
      expect(rejoins(from), 1);
      // Wi-Fi off (r357 22.330): the connectivity reading goes none and the
      // restart's socket dies (22.541)
      connectivity([ConnectivityResult.wifi], [ConnectivityResult.none]);
      autoConnectPcs(pcs); // peer connections created from now on come up
      final closedAt = DateTime.now();
      await server.last.serverClose();
      expect(
        await eventually(() => rejoins(from) >= 2, timeout: const Duration(seconds: 2)),
        isTrue,
        reason: 'base: the restart sat out Timeouts.connection (10 s) on a dead socket',
      );
      expect(await eventually(() => restarted == 1, timeout: const Duration(seconds: 3)), isTrue);
      // ignore: avoid_print
      print('RESULT restart_socket_closed_to_restarted_ms=${restartedAt!.difference(closedAt).inMilliseconds}');
      expect(engine.signalClient.connectionState, ConnectionState.connected);
    });

    test('pure viewer: the socket closes, then ICE brings the restart\'s connections back by itself -> '
        'not "restarted" on a dead signal channel', () async {
      await start();
      final from = server.dials.length;
      await fullReconnectWaitingForPcs();
      final sub = pcs.subscriber, pub = pcs.publisher;
      connectivity([ConnectivityResult.wifi], [ConnectivityResult.none]);
      autoConnectPcs(pcs);
      await server.last.serverClose();
      await settle(100);
      // the network is back; ICE completes on the candidates exchanged before
      connectivity([ConnectivityResult.none], [ConnectivityResult.wifi]);
      sub.connect();
      pub.connect();
      expect(await eventually(() => restarted >= 1, timeout: const Duration(seconds: 3)), isTrue);
      await settle(300);
      expect(
        engine.signalClient.connectionState,
        ConnectionState.connected,
        reason: 'base: the session reported restarted with its signal socket closed, and nothing reconnects it',
      );
      expect(rejoins(from), greaterThanOrEqualTo(2));
    });

    test(
      'guard: the socket closes AFTER the full reconnect finished -> a resume, not another full reconnect',
      () async {
        await start();
        autoConnectPcs(pcs);
        final from = server.dials.length;
        unawaited(engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
        expect(await eventually(() => restarted == 1, timeout: const Duration(seconds: 3)), isTrue);
        await settle(100);
        await server.last.serverClose();
        expect(await eventually(() => resumes(from) >= 1, timeout: const Duration(seconds: 3)), isTrue);
        await settle(300);
        expect(rejoins(from), 1);
      },
    );
  });

  // --- new API / the abort's own behaviour (not in the base) ---

  group('GravixRecoveryOptions.restartAbortsOnSignalLoss', () {
    test('closed while waiting for the PUBLISHER (the primary is back) -> the reconnect goes on at once '
        '(not after the 10 s peer connection timeout)', () async {
      await start();
      engine.gravixPublisherWaitInTests = true; // flutter test skips this wait otherwise
      await engine.negotiate(); // something was published: the restart waits for the publisher
      final from = server.dials.length;
      await fullReconnectWaitingForPcs();
      pcs.subscriber.connect(); // the primary is back; the publisher never negotiates
      await settle(100);
      expect(restarted, 0, reason: 'the restart is waiting for the publisher');
      autoConnectPcs(pcs);
      await server.last.serverClose();
      expect(await eventually(() => rejoins(from) >= 2, timeout: const Duration(seconds: 2)), isTrue);
    });

    test('an attempt failed that way while the network changed does not count against the budget', () async {
      final policy = _RecordingPolicy();
      await start(policy: policy);
      var dials = 0;
      server.onDial = (u) async {
        // the restart's dial goes through, its same-url retry does not (no network yet)
        if (!isResume(u) && ++dials == 2) throw Exception('Network is unreachable');
      };
      await fullReconnectWaitingForPcs();
      connectivity([ConnectivityResult.wifi], [ConnectivityResult.none]);
      autoConnectPcs(pcs);
      await server.last.serverClose();
      expect(await eventually(() => restarted == 1, timeout: const Duration(seconds: 3)), isTrue);
      expect(policy.retryCounts, [0, 0], reason: 'the failed attempt was not counted');
    });

    test('guard: the same failure with the network steady IS counted (the back-off applies)', () async {
      final policy = _RecordingPolicy();
      await start(policy: policy);
      var dials = 0;
      server.onDial = (u) async {
        if (!isResume(u) && ++dials == 2) throw Exception('refused');
      };
      await fullReconnectWaitingForPcs();
      autoConnectPcs(pcs);
      await server.last.serverClose(); // no connectivity change: the server side closed it
      expect(await eventually(() => restarted == 1, timeout: const Duration(seconds: 3)), isTrue);
      expect(policy.retryCounts, [0, 1]);
    });

    test('off -> the 0.4.14 wait (no new dial while the restart waits out its timeout)', () async {
      await start(
        roomOptions: RoomOptions(
          reconnectPolicy: FastPolicy(),
          recovery: const GravixRecoveryOptions(restartAbortsOnSignalLoss: false),
        ),
      );
      final from = server.dials.length;
      await fullReconnectWaitingForPcs();
      autoConnectPcs(pcs);
      await server.last.serverClose();
      await settle(2000);
      expect(rejoins(from), 1);
    });

    test('defaults: on; off in legacy; kept by copyWith', () {
      expect(const GravixRecoveryOptions().restartAbortsOnSignalLoss, isTrue);
      expect(GravixRecoveryOptions.legacy.restartAbortsOnSignalLoss, isFalse);
      expect(const GravixRecoveryOptions().copyWith(boundedSignalConnect: false).restartAbortsOnSignalLoss, isTrue);
      expect(
        const GravixRecoveryOptions().copyWith(restartAbortsOnSignalLoss: false).restartAbortsOnSignalLoss,
        isFalse,
      );
    });
  });
}

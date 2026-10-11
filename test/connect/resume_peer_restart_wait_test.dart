// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// iOS real-device recheck of 30fd11b, 2026-10-11 run 3 (iPhone 17 Pro Max,
// iOS 27.0.1, host, subscriber primary, Airplane Mode ~30 s, 22:13:15-45 UTC):
// both peer connections reported their OLD ICE session Failed while the resume
// waited for the network (22:13:32.20). The network came back, the resume
// restarted ICE (45.46); iOS reported the restarting publisher Disconnected
// (45.4719); the subscriber (primary) was connected at 45.608 and the resume
// succeeded. The publisher's restart was still running, so 30fd11b's check
// (primary AND the other connection connected, at once) said "not satisfied"
// and dispatched the queued full reconnect: the far side saw the host leave and
// join again (45.71 / 46.70).
//
// Now a connection still restarting (Connecting / Disconnected) when the
// resume ends gets a bounded wait (GravixRecoveryOptions.resumePeerRestartWait):
// Connected -> nothing; Failed -> its own reconnect (a rejoin); the bound
// passes -> the rejoin. With the subscriber enough for an idle publisher, the
// publisher watch decides. The tests above the option section use only APIs
// that 30fd11b has, so they run against its lib unchanged.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';

import '../support/fake_rtc.dart';

const _failed = rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed;
const _disconnected = rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;
const _connecting = rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late FakeConnectivitySignalClient signal;
  late Engine engine;
  late int resumed, restarting;
  DateTime? resumedAt, rejoinDialAt;
  tearDown(() async => engine.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';
  int resumes(int from) => server.dials.skip(from).where(isResume).length;
  int rejoins(int from) => server.dials.skip(from).where((u) => !isResume(u)).length;

  Future<void> start({
    bool subscriberPrimary = false,
    RoomOptions? roomOptions,
    Duration peerConnection = const Duration(seconds: 10),
  }) async {
    server = FakeSignalServer();
    signal = FakeConnectivitySignalClient(server.connect);
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(
      server,
      pcs,
      subscriberPrimary: subscriberPrimary,
      signalClient: signal,
      roomOptions: roomOptions,
      peerConnection: peerConnection,
    );
    engine.gravixReachabilityProbe = (url, timeout) async => false;
    resumed = 0;
    restarting = 0;
    resumedAt = null;
    rejoinDialAt = null;
    engine.events.on<EngineResumedEvent>((_) {
      resumed++;
      resumedAt ??= DateTime.now();
    });
    engine.events.on<EngineFullRestartingEvent>((_) => restarting++);
    server.onDial = (u) async {
      if (!isResume(u)) rejoinDialAt ??= DateTime.now();
    };
  }

  /// Run 3's shape: Airplane Mode ON, both connections disconnect (22:13:20 /
  /// 22.17), the resume waits for the network, and BOTH report the old ICE
  /// session Failed while it waits (32.20). Then the network is back (45.13).
  Future<void> outageBothFailedThenBack() async {
    signal.online = false;
    pcs.publisher.disconnect();
    pcs.subscriber.disconnect();
    await settle(100);
    pcs.publisher.setState(_failed);
    pcs.subscriber.setState(_failed);
    await settle(50);
    signal.online = true;
    signal.events.emit(
      const SignalConnectivityChangedEvent(oldState: [ConnectivityResult.none], state: [ConnectivityResult.wifi]),
    );
  }

  /// After the ReconnectResponse: [restarting] reports Disconnected (iOS, as its
  /// ICE restart begins: 45.4719), [first] connects 40 ms later (run 3: the
  /// subscriber, 45.608) and [restarting] connects [otherAfterMs] after the
  /// ReconnectResponse (or never, when null).
  void restart(FakePeerConnection first, FakePeerConnection restarting, {int? otherAfterMs}) {
    server.afterResumeAnswer = (ws) {
      restarting.setState(_disconnected);
      Timer(const Duration(milliseconds: 40), first.connect);
      if (otherAfterMs != null) Timer(Duration(milliseconds: otherAfterMs), restarting.connect);
    };
  }

  group('run 3: the other connection is still restarting when the resume succeeds', () {
    test(
      'subscriber primary (run 3): publisher Disconnected, connected 1.2 s after the resume -> no full rejoin',
      () async {
        await start(subscriberPrimary: true);
        final from = server.dials.length;
        final sub = pcs.subscriber, pub = pcs.publisher;
        restart(sub, pub, otherAfterMs: 1240);
        await outageBothFailedThenBack();
        expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
        await settle(4000); // past the bound
        expect(rejoins(from), 0, reason: '30fd11b: a full rejoin right after the resume (far side: left / joined)');
        expect(restarting, 0);
        expect(resumes(from), 1);
        expect(pub.connectionState, rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      },
    );

    test('publisher primary: subscriber Disconnected, connected 0.5 s after the resume -> no full rejoin', () async {
      await start();
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      restart(pub, sub, otherAfterMs: 540);
      await outageBothFailedThenBack();
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      await settle(4000);
      expect(rejoins(from), 0, reason: '30fd11b: a full rejoin right after the resume');
      expect(restarting, 0);
    });

    test(
      'the restarting publisher flaps (Connecting -> Disconnected) after the resume: a resume, not a rejoin',
      () async {
        await start(subscriberPrimary: true);
        final from = server.dials.length;
        final sub = pcs.subscriber, pub = pcs.publisher;
        server.afterResumeAnswer = (ws) {
          if (resumes(from) > 1) return; // the second resume: nothing to restart in the fake
          pub.setState(_disconnected);
          Timer(const Duration(milliseconds: 40), sub.connect);
          Timer(const Duration(milliseconds: 300), () => pub.setState(_connecting));
          // a Disconnected report after the attempt ended starts a new attempt;
          // with the request still pending it would be a FULL reconnect
          Timer(const Duration(milliseconds: 350), () => pub.setState(_disconnected));
          Timer(const Duration(milliseconds: 1200), pub.connect);
        };
        await outageBothFailedThenBack();
        expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
        await settle(4000);
        expect(rejoins(from), 0, reason: '30fd11b: a full rejoin right after the resume');
        expect(resumes(from), 2, reason: 'the flap is handled by a resume');
      },
    );

    test(
      'guard: the restarting publisher FAILS after the resume -> full rejoin at once (not after the bound)',
      () async {
        await start(subscriberPrimary: true);
        autoConnectPcs(pcs);
        final from = server.dials.length;
        final sub = pcs.subscriber, pub = pcs.publisher;
        server.afterResumeAnswer = (ws) {
          pub.setState(_disconnected);
          Timer(const Duration(milliseconds: 40), sub.connect);
          Timer(const Duration(milliseconds: 600), () => pub.setState(_failed)); // the restarted session failed
        };
        await outageBothFailedThenBack();
        expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
        expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 2)), isTrue);
        expect(rejoinDialAt!.difference(resumedAt!).inMilliseconds, lessThan(1500));
      },
    );

    test('guard: the other connection never comes back -> full rejoin (after the bound)', () async {
      await start(subscriberPrimary: true);
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      restart(sub, pub); // the publisher stays Disconnected
      await outageBothFailedThenBack();
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 5)), isTrue);
      // ignore: avoid_print
      print('RESULT resume_to_rejoin_ms_default_bound=${rejoinDialAt!.difference(resumedAt!).inMilliseconds}');
    });

    test('subscriber enough (idle publisher primary): the publisher still restarting is left to the publisher '
        'watch; it connects 1 s later -> no full rejoin', () async {
      await start();
      engine.gravixHasUnmutedLocalMedia = () => false; // everything published is muted
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      restart(sub, pub, otherAfterMs: 1040);
      await outageBothFailedThenBack();
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      await settle(4000);
      expect(rejoins(from), 0, reason: '30fd11b: a full rejoin right after the resume');
      expect(restarting, 0);
    });

    test('guard: subscriber enough, the idle publisher never comes back -> the publisher watch rejoins at its '
        'deadline', () async {
      await start(peerConnection: const Duration(seconds: 2));
      engine.gravixHasUnmutedLocalMedia = () => false;
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      restart(sub, pub);
      await outageBothFailedThenBack();
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 4)), isTrue);
    });
  });

  // --- the option (new API: not on 30fd11b) ---

  group('GravixRecoveryOptions.resumePeerRestartWait', () {
    test('the bound passes with the other connection still restarting -> the rejoin starts one bound after the '
        'resume (worst-case added delay)', () async {
      const bound = Duration(milliseconds: 500);
      await start(
        subscriberPrimary: true,
        roomOptions: RoomOptions(
          reconnectPolicy: FastPolicy(),
          recovery: const GravixRecoveryOptions(resumePeerRestartWait: bound),
        ),
      );
      final from = server.dials.length;
      restart(pcs.subscriber, pcs.publisher);
      await outageBothFailedThenBack();
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 3)), isTrue);
      final delay = rejoinDialAt!.difference(resumedAt!).inMilliseconds;
      // ignore: avoid_print
      print('RESULT resume_to_rejoin_ms bound=${bound.inMilliseconds} measured=$delay');
      expect(delay, greaterThanOrEqualTo(bound.inMilliseconds - 20));
      expect(delay, lessThan(bound.inMilliseconds + 400));
    });

    test('Duration.zero -> no wait: the rejoin right after the resume (30fd11b)', () async {
      await start(
        subscriberPrimary: true,
        roomOptions: RoomOptions(
          reconnectPolicy: FastPolicy(),
          recovery: const GravixRecoveryOptions(resumePeerRestartWait: Duration.zero),
        ),
      );
      final from = server.dials.length;
      restart(pcs.subscriber, pcs.publisher, otherAfterMs: 1240);
      await outageBothFailedThenBack();
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 2)), isTrue);
      expect(rejoinDialAt!.difference(resumedAt!).inMilliseconds, lessThan(300));
    });

    test('defaults: 3 s; zero in legacy; kept by copyWith', () {
      expect(const GravixRecoveryOptions().resumePeerRestartWait, const Duration(seconds: 3));
      expect(GravixRecoveryOptions.legacy.resumePeerRestartWait, Duration.zero);
      expect(
        const GravixRecoveryOptions().copyWith(boundedSignalConnect: false).resumePeerRestartWait,
        const Duration(seconds: 3),
      );
      expect(
        const GravixRecoveryOptions().copyWith(resumePeerRestartWait: const Duration(seconds: 1)).resumePeerRestartWait,
        const Duration(seconds: 1),
      );
    });
  });
}

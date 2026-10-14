// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-14, the independent review of 0.4.18 (83ef932..9c287eb):
//  F1 the ICE transport watch read getStats during full rejoins and resumes (it
//     was never stopped by restartConnection and its ticks ran mid-reconnect);
//  F2 resumeBeforeFullOnNetworkFailure resumed a FAILED NON-primary connection
//     and nothing waited for it (a subscriber-primary host's dead mic for 10-30 s);
//  F3 the transport comes from the stats the ICE-connected handler reads anyway
//     (getConnectedAddress): zero extra reads to know it;
//  F6 an exception from networkIsAvailable() in the reconnect catch left the
//     session stuck "reconnecting";
//  F7 the per-connection values outlived the session;
//  F8 a Connected of a connection being disposed re-armed the watch;
//  F10 lightweight: on UDP the watch reads every 30 s (TCP: every 5 s, for the
//     slow-TCP detection) and not at all while the app is in the background;
//  F11 GravixRecoveryOptions.before0418: every 0.4.18 recovery switch off in one step.
// All drive the real Engine / Room over the fakes.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_ice_transport.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart' show WebSocketException;
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

const _failed = rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed;

List<rtc.StatsReport> pairStats(String protocol, {String type = 'srflx', double rtt = 0.01}) => [
  rtc.StatsReport('T1', 'transport', 0, {'selectedCandidatePairId': 'CP1'}),
  rtc.StatsReport('CP1', 'candidate-pair', 0, {
    'localCandidateId': 'L1',
    'remoteCandidateId': 'R1',
    'currentRoundTripTime': rtt,
    'state': 'succeeded',
    'nominated': true,
  }),
  rtc.StatsReport('L1', 'local-candidate', 0, {'protocol': protocol, 'candidateType': type}),
  rtc.StatsReport('R1', 'remote-candidate', 0, {
    'protocol': protocol,
    'candidateType': 'host',
    'address': '203.0.113.7',
    'port': 7881,
  }),
];

/// Its connectivity reading throws on the [throwOn]-th check (a MissingPluginException in a background engine).
class _ThrowingConnectivity extends FakeConnectivitySignalClient {
  _ThrowingConnectivity(super.wsConnector);
  int? throwOn;
  @override
  Future<bool> networkIsAvailable() async {
    final ok = await super.networkIsAvailable();
    if (throwOn != null && checks == throwOn) throw StateError('connectivity: no plugin');
    return ok;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);
  tearDown(() => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late FakeConnectivitySignalClient signal;
  Engine? engine;
  Room? room;
  tearDown(() async {
    await room?.dispose();
    room = null;
    await engine?.dispose();
    engine = null;
  });

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';
  int statsCalls() => pcs.all.fold(0, (n, pc) => n + pc.getStatsCalls);

  Future<Engine> start({
    GravixRecoveryOptions recovery = const GravixRecoveryOptions(),
    bool subscriberPrimary = false,
    FakeConnectivitySignalClient Function(FakeSignalServer s)? signalOf,
  }) async {
    server = FakeSignalServer();
    signal = signalOf?.call(server) ?? FakeConnectivitySignalClient(server.connect);
    pcs = FakePcFactory();
    final e = engine = await connectedFakeEngine(
      server,
      pcs,
      signalClient: signal,
      subscriberPrimary: subscriberPrimary,
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
    e.gravixReachabilityProbe = (url, timeout) async => false;
    return e;
  }

  void netChange() => signal.events.emit(
    const SignalConnectivityChangedEvent(oldState: [ConnectivityResult.wifi], state: [ConnectivityResult.mobile]),
  );

  void allStats(String protocol, {double rtt = 0.01}) {
    pcs.onCreate = (pc) {
      pc.stats = pairStats(protocol, rtt: rtt);
      autoConnect(pc);
    };
    for (final pc in pcs.all) {
      pc.stats = pairStats(protocol, rtt: rtt);
    }
  }

  // a short watch so its ticks land everywhere (F1: the guard, not the timing, keeps them out)
  const busyWatch = GravixRecoveryOptions(
    iceTransportWatch: Duration(milliseconds: 60),
    iceTransportWatchUdp: Duration(milliseconds: 60),
  );

  group('F1: no getStats while a reconnect runs', () {
    test('a full rejoin: zero reads from EngineFullRestartingEvent to EngineRestartedEvent', () async {
      final e = await start(recovery: busyWatch);
      allStats('udp');
      expect(await eventually(() => e.gravixSelectedTransport == GravixIceTransport.udp), isTrue);
      var inRestart = false, during = 0, base = 0;
      e.events.on<EngineFullRestartingEvent>((_) {
        inRestart = true;
        base = statsCalls();
      });
      e.events.on<EngineRestartedEvent>((_) {
        during = statsCalls() - base;
        inRestart = false;
      });
      // the rejoin's subscriber connects at once, its primary (the publisher) only
      // after 600 ms: ~10 watch ticks land while the rejoin waits for it
      var created = 0;
      pcs.onCreate = (pc) {
        pc.stats = pairStats('udp');
        final isPublisher = (created++).isEven;
        Timer(Duration(milliseconds: isPublisher ? 600 : 30), pc.connect);
      };
      await e.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      expect(await eventually(() => !inRestart && base > 0, timeout: const Duration(seconds: 5)), isTrue);
      expect(during, 0, reason: 'the watch must not read getStats during a full rejoin');
      // it reads again after the rejoin
      final after = statsCalls();
      expect(await eventually(() => statsCalls() > after, timeout: const Duration(seconds: 2)), isTrue);
    });

    test('a resume: zero reads from EngineResumingEvent to EngineResumedEvent', () async {
      final e = await start(recovery: busyWatch);
      allStats('udp');
      expect(await eventually(() => e.gravixSelectedTransport == GravixIceTransport.udp), isTrue);
      var resuming = false, during = 0, base = 0, resumed = 0;
      e.events.on<EngineResumingEvent>((_) async {
        resuming = true;
        base = statsCalls();
        await settle(600); // the ICE restart takes a while
        pcs.publisher.connect();
        pcs.subscriber.connect();
      });
      e.events.on<EngineResumedEvent>((_) {
        during = statsCalls() - base;
        resuming = false;
        resumed++;
      });
      pcs.publisher.disconnect();
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(resuming, isFalse);
      expect(during, 0, reason: 'the watch must not read getStats during a resume');
    });

    test('the values of the replaced session are dropped by a full rejoin (F7)', () async {
      final e = await start(recovery: busyWatch);
      allStats('tcp');
      expect(await eventually(() => e.gravixSelectedTransport == GravixIceTransport.tcp), isTrue);
      var seen = <GravixIceTransport?>[];
      e.events.on<EngineFullRestartingEvent>((_) => seen = [e.gravixSelectedTransport]);
      allStats('udp');
      await e.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      expect(await eventually(() => e.gravixSelectedTransport == GravixIceTransport.udp), isTrue);
      expect(seen, [isNull], reason: 'stopped and cleared when the session was replaced');
    });
  });

  group('F2: one resume for a FAILED non-primary connection, then a bounded wait', () {
    Future<void> scenario({required bool subscriberPrimary, required bool otherRecovers}) async {
      final e = await start(
        subscriberPrimary: subscriberPrimary,
        recovery: const GravixRecoveryOptions(resumePeerRestartWait: Duration(milliseconds: 500)),
      );
      var resumed = 0, restarting = 0;
      e.events.on<EngineResumedEvent>((_) => resumed++);
      e.events.on<EngineFullRestartingEvent>((_) => restarting++);
      final primary = subscriberPrimary ? pcs.subscriber : pcs.publisher;
      final other = subscriberPrimary ? pcs.publisher : pcs.subscriber;
      e.events.on<EngineResumingEvent>((_) async {
        await settle(30);
        primary.connect(); // the primary is fine
        if (otherRecovers) {
          await settle(150);
          other.connect();
        }
      });
      final from = server.dials.length;
      netChange();
      other.setState(_failed);
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 4)), isTrue);
      expect(server.dials.skip(from).where(isResume).length, 1);
      if (otherRecovers) {
        await settle(900);
        expect(restarting, 0, reason: 'its ICE restart brought it back: no full rejoin');
      } else {
        autoConnectPcs(pcs);
        expect(
          await eventually(() => restarting == 1, timeout: const Duration(seconds: 2)),
          isTrue,
          reason: 'not back within resumePeerRestartWait: the full rejoin (0.4.16 rejoined at once)',
        );
      }
    }

    test(
      'subscriber primary (an audio host): the publisher FAILED, not back -> full rejoin after the bound',
      () => scenario(subscriberPrimary: true, otherRecovers: false),
    );
    test(
      'subscriber primary: the publisher FAILED and its ICE restart works -> no full rejoin',
      () => scenario(subscriberPrimary: true, otherRecovers: true),
    );
    test(
      'publisher primary: the subscriber FAILED, not back -> full rejoin after the bound',
      () => scenario(subscriberPrimary: false, otherRecovers: false),
    );
  });

  group('F3: the transport from the ICE-connected stats (no extra read)', () {
    test('ICE connected -> the transport is known at once, from the one read that was already made', () async {
      final e = await start(); // defaults: the watch's own first reading would be 3 s away
      pcs.publisher.stats = pairStats('tcp', type: 'prflx');
      final before = statsCalls();
      pcs.publisher.onIceConnectionState?.call(rtc.RTCIceConnectionState.RTCIceConnectionStateConnected);
      expect(await eventually(() => e.gravixPublisherTransport == GravixIceTransport.tcp), isTrue);
      expect(statsCalls() - before, 1, reason: 'the connected-address read only');
    });
  });

  test('F6: networkIsAvailable() throwing in the reconnect catch does not leave the session stuck', () async {
    late _ThrowingConnectivity thrower;
    final e = await start(signalOf: (s) => thrower = _ThrowingConnectivity(s.connect));
    var restarting = 0;
    e.events.on<EngineFullRestartingEvent>((_) => restarting++);
    autoConnectPcs(pcs);
    var failed = false;
    server.onDial = (u) async {
      if (isResume(u) && !failed) {
        failed = true;
        throw const WebSocketException('Failed to connect');
      }
    };
    thrower.throwOn = thrower.checks + 2; // the attempt's own check passes, the catch's throws
    pcs.publisher.disconnect();
    expect(
      await eventually(() => restarting >= 1, timeout: const Duration(seconds: 4)),
      isTrue,
      reason: 'the reconnect carries on (here: a full rejoin, the steady-network path)',
    );
  });

  group('F7 / F8: nothing outlives the session', () {
    test('after a leave the getters are null and nothing is scheduled', () async {
      server = FakeSignalServer()..answerOffers = true;
      pcs = FakePcFactory();
      final r = room = await connectedFakeRoom(server, pcs, roomOptions: RoomOptions(recovery: busyWatch));
      pcs.publisher.stats = pairStats('tcp');
      pcs.subscriber.stats = pairStats('tcp');
      expect(await eventually(() => r.selectedTransport == GravixIceTransport.tcp), isTrue);
      final sub = pcs.subscriber;
      await r.disconnect();
      expect(r.selectedTransport, isNull);
      // a late Connected of the disposed subscriber must not re-arm the watch
      sub.setState(rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
      sub.connect();
      await settle(300);
      expect(r.engine.gravixIceWatchScheduled, isFalse);
    });
  });

  group('F10: lightweight', () {
    test('on UDP a reading every iceTransportWatchUdp; on TCP every iceTransportWatch', () async {
      final e = await start(
        recovery: const GravixRecoveryOptions(
          iceTransportWatch: Duration(milliseconds: 50),
          iceTransportWatchUdp: Duration(milliseconds: 600),
        ),
      );
      allStats('udp');
      expect(await eventually(() => e.gravixSelectedTransport == GravixIceTransport.udp), isTrue);
      var from = statsCalls();
      await settle(500);
      expect(statsCalls() - from, lessThanOrEqualTo(2), reason: 'at most one reading (2 connections) in 500 ms');
      allStats('tcp');
      expect(
        await eventually(
          () => e.gravixSelectedTransport == GravixIceTransport.tcp,
          timeout: const Duration(seconds: 2),
        ),
        isTrue,
      );
      from = statsCalls();
      await settle(500);
      expect(statsCalls() - from, greaterThanOrEqualTo(10), reason: 'every 50 ms on TCP');
    });

    test('no reading while the app is in the background; it carries on when back', () async {
      final e = await start(recovery: busyWatch);
      allStats('udp');
      expect(await eventually(() => e.gravixSelectedTransport == GravixIceTransport.udp), isTrue);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await settle(80);
      final from = statsCalls();
      await settle(400);
      expect(statsCalls(), from, reason: 'paused in the background');
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(await eventually(() => statsCalls() > from, timeout: const Duration(seconds: 1)), isTrue);
    });

    test('the defaults: 5 s on TCP, 30 s on UDP', () {
      expect(const GravixRecoveryOptions().iceTransportWatch, const Duration(seconds: 5));
      expect(const GravixRecoveryOptions().iceTransportWatchUdp, const Duration(seconds: 30));
    });
  });

  test('F11: GravixRecoveryOptions.before0418 turns every 0.4.18 switch off and keeps the 0.4.15-0.4.16 ones', () {
    const o = GravixRecoveryOptions.before0418;
    expect(o.resumeReasonNetworkWindow, Duration.zero);
    expect(o.freshPeerFailedGrace, Duration.zero);
    expect(o.iceTransportWatch, Duration.zero);
    expect(o.resumeAfterNetworkSocketError, isFalse);
    expect(o.resumeBeforeFullOnNetworkFailure, isFalse);
    // the 0.4.15 / 0.4.16 recovery stays on
    expect(o.upstreamReconnectFixes, isTrue);
    expect(o.resumeSatisfiesPeerFailure, isTrue);
    expect(o.resumePeerRestartWait, const GravixRecoveryOptions().resumePeerRestartWait);
  });
}

void autoConnect(FakePeerConnection pc) => Timer(const Duration(milliseconds: 30), pc.connect);

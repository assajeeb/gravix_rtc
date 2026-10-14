// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-14, 0.4.18 device run (an Android host, Wi-Fi off 5-15 s): every drop
// ended in a FULL rejoin although the server still held the session:
//  * x1: the resume dialled while the interface was going away failed with a
//    socket error, and `WebSocketException -> fullReconnectOnNext` made the next
//    attempt a full rejoin, started the instant the Wi-Fi came back;
//  * x2/x4/x5: a connected peer connection reported FAILED during the outage
//    and a FAILED always escalates to a full reconnect.
// Now (GravixRecoveryOptions):
//  * resumeAfterNetworkSocketError: a resume dial that fails with a socket error
//    while the network changed (or reads offline) keeps the next attempt a
//    resume; the consecutive-failure limit still escalates;
//  * resumeBeforeFullOnNetworkFailure: a FAILED during a network change tries one
//    resume (its ICE restart) before the full reconnect; on a steady network a
//    FAILED is a full reconnect as before;
//  * RoomReconnectAttemptEvent for every attempt (resume | full, the cause, the
//    reason sent to the server, the attempt number).

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart' show WebSocketException;

import '../support/fake_rtc.dart';

const _failed = rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

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
  int resumes(int from) => server.dials.skip(from).where(isResume).length;
  int rejoins(int from) => server.dials.skip(from).where((u) => !isResume(u)).length;

  late int resumed, restarting;

  Future<Engine> start({
    GravixRecoveryOptions recovery = const GravixRecoveryOptions(),
    Duration peerConnection = const Duration(seconds: 10),
  }) async {
    server = FakeSignalServer();
    signal = FakeConnectivitySignalClient(server.connect);
    pcs = FakePcFactory();
    final e = engine = await connectedFakeEngine(
      server,
      pcs,
      signalClient: signal,
      peerConnection: peerConnection,
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
    e.gravixReachabilityProbe = (url, timeout) async => false;
    resumed = 0;
    restarting = 0;
    e.events.on<EngineResumedEvent>((_) => resumed++);
    e.events.on<EngineFullRestartingEvent>((_) => restarting++);
    return e;
  }

  void netChange(List<ConnectivityResult> from, List<ConnectivityResult> to) =>
      signal.events.emit(SignalConnectivityChangedEvent(oldState: from, state: to));

  /// The first [n] resume dials from now on fail with a socket error (the
  /// interface going away under the dial).
  void failResumeDials(int n) {
    var left = n;
    server.onDial = (u) async {
      if (isResume(u) && left > 0) {
        left--;
        throw const WebSocketException('Failed to connect', 'SocketException: Network is unreachable');
      }
    };
  }

  /// The peer connections of the resumed session connect again (its ICE restart).
  void reconnectPcsOnResume() {
    final mine = pcs;
    engine!.events.on<EngineResumingEvent>((_) async {
      await settle(30);
      if (mine.all.length < 2) return;
      mine.publisher.connect();
      mine.subscriber.connect();
    });
  }

  group('a resume dial that fails with a socket error', () {
    test('after a network change: the next attempt is a resume again (no full rejoin)', () async {
      await start();
      reconnectPcsOnResume();
      final from = server.dials.length;
      failResumeDials(1);
      netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
      pcs.publisher.disconnect();
      expect(await eventually(() => resumed >= 1, timeout: const Duration(seconds: 4)), isTrue);
      expect(resumes(from), 2, reason: 'the failed resume and the one that worked');
      expect(rejoins(from), 0);
      expect(restarting, 0);
    });

    test('on a steady network: a full rejoin, as before', () async {
      await start();
      autoConnectPcs(pcs);
      final from = server.dials.length;
      failResumeDials(1);
      pcs.publisher.disconnect();
      expect(await eventually(() => restarting >= 1, timeout: const Duration(seconds: 4)), isTrue);
      expect(rejoins(from), greaterThanOrEqualTo(1));
    });

    test('the consecutive-failure limit still escalates: resumes failing on and on -> a full rejoin', () async {
      await start();
      autoConnectPcs(pcs);
      failResumeDials(10);
      netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
      final from = server.dials.length;
      pcs.publisher.disconnect();
      expect(await eventually(() => restarting >= 1, timeout: const Duration(seconds: 6)), isTrue);
      expect(resumes(from), 2, reason: 'two failed resumes, then the full rejoin');
    });

    test('off (resumeAfterNetworkSocketError: false): a full rejoin even after a network change', () async {
      await start(recovery: const GravixRecoveryOptions(resumeAfterNetworkSocketError: false));
      autoConnectPcs(pcs);
      failResumeDials(1);
      netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
      pcs.publisher.disconnect();
      expect(await eventually(() => restarting >= 1, timeout: const Duration(seconds: 4)), isTrue);
    });
  });

  group('a connected peer connection reports FAILED', () {
    test('during a network change: one resume (an ICE restart) first, no full rejoin when it works', () async {
      await start();
      reconnectPcsOnResume();
      final from = server.dials.length;
      netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
      pcs.publisher.setState(_failed);
      expect(await eventually(() => resumed >= 1, timeout: const Duration(seconds: 4)), isTrue);
      expect(resumes(from), 1);
      expect(rejoins(from), 0);
      expect(restarting, 0);
    });

    test('during a network change, and the resume does not bring it back: then the full rejoin', () async {
      await start(peerConnection: const Duration(milliseconds: 400));
      final from = server.dials.length;
      netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
      pcs.publisher.setState(_failed);
      expect(await eventually(() => resumes(from) >= 1, timeout: const Duration(seconds: 3)), isTrue);
      autoConnectPcs(pcs); // the full rejoin's connections connect; the resumed ones never do
      expect(await eventually(() => restarting >= 1, timeout: const Duration(seconds: 6)), isTrue);
      expect(resumes(from), 1, reason: 'one resume only');
    });

    test('on a steady network: a full rejoin at once, as before', () async {
      await start();
      autoConnectPcs(pcs);
      final from = server.dials.length;
      pcs.publisher.setState(_failed);
      expect(await eventually(() => restarting >= 1, timeout: const Duration(seconds: 4)), isTrue);
      expect(resumes(from), 0);
    });

    test('off (resumeBeforeFullOnNetworkFailure: false): a full rejoin even during a network change', () async {
      await start(recovery: const GravixRecoveryOptions(resumeBeforeFullOnNetworkFailure: false));
      autoConnectPcs(pcs);
      final from = server.dials.length;
      netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
      pcs.publisher.setState(_failed);
      expect(await eventually(() => restarting >= 1, timeout: const Duration(seconds: 4)), isTrue);
      expect(resumes(from), 0);
    });
  });

  test('the defaults are on; legacy turns them off', () {
    expect(const GravixRecoveryOptions().resumeAfterNetworkSocketError, isTrue);
    expect(const GravixRecoveryOptions().resumeBeforeFullOnNetworkFailure, isTrue);
    expect(GravixRecoveryOptions.legacy.resumeAfterNetworkSocketError, isFalse);
    expect(GravixRecoveryOptions.legacy.resumeBeforeFullOnNetworkFailure, isFalse);
  });

  group('RoomReconnectAttemptEvent', () {
    Future<Room> hostRoom() async {
      server = FakeSignalServer()..answerOffers = true;
      signal = FakeConnectivitySignalClient(server.connect);
      pcs = FakePcFactory();
      final options = RoomOptions(reconnectPolicy: FastPolicy());
      final e = engine = Engine(
        connectOptions: ConnectOptions(timeouts: fastTimeouts()),
        roomOptions: options,
        signalClient: signal,
        peerConnectionCreate: pcs.create,
      );
      final r = room = Room(engine: e, roomOptions: options);
      engine = null; // disposed by the room
      server.joinResponse = (_) => fakeJoinResponse();
      autoConnectPcs(pcs);
      await r.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0),
      );
      e.gravixReachabilityProbe = (url, timeout) async => false;
      return r;
    }

    test('a resume: mode resume, the cause, the reason sent, attempt 1', () async {
      final r = await hostRoom();
      final attempts = <RoomReconnectAttemptEvent>[];
      r.events.on<RoomReconnectAttemptEvent>(attempts.add);
      pcs.publisher.disconnect();
      expect(await eventually(() => attempts.isNotEmpty, timeout: const Duration(seconds: 3)), isTrue);
      final a = attempts.first;
      expect(a.mode, GravixReconnectMode.resume);
      expect(a.cause, 'peerConnectionClosed');
      expect(a.reconnectReason, 'RR_PUBLISHER_FAILED');
      expect(a.attempt, 1);
      expect(a.afterNetworkChange, isFalse);
    });

    test('after a network change the event shows RR_SIGNAL_DISCONNECTED', () async {
      final r = await hostRoom();
      final attempts = <RoomReconnectAttemptEvent>[];
      r.events.on<RoomReconnectAttemptEvent>(attempts.add);
      netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
      pcs.subscriber.disconnect();
      expect(await eventually(() => attempts.isNotEmpty, timeout: const Duration(seconds: 3)), isTrue);
      expect(attempts.first.reconnectReason, 'RR_SIGNAL_DISCONNECTED');
      expect(attempts.first.afterNetworkChange, isTrue);
    });

    test('a full rejoin: mode full, no reason (a join carries none)', () async {
      final r = await hostRoom();
      final attempts = <RoomReconnectAttemptEvent>[];
      r.events.on<RoomReconnectAttemptEvent>(attempts.add);
      pcs.publisher.setState(_failed);
      expect(await eventually(() => attempts.isNotEmpty, timeout: const Duration(seconds: 3)), isTrue);
      expect(attempts.first.mode, GravixReconnectMode.full);
      expect(attempts.first.cause, 'peerConnectionFailed');
      expect(attempts.first.reconnectReason, isNull);
    });
  });
}

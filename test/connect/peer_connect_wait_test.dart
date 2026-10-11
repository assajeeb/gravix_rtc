// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// RECHECK 2026-10-11 r376 (Xiaomi, NLC "Very Bad Network"): the fresh join's
// signal dial took 10.7 s, ICE was still checking 18 s after it began when the
// 20 s Timeouts.mediaConnect wait ran out (MediaConnectException). On a
// measurably slow signal path (slowSignalSetup / slowSignalRtt) the wait for
// the primary peer connection now goes on up to slowPathPeerConnectWait.
//
// Scaled: Timeouts.connection 300 ms, mediaConnect 600 ms (20 s), ceiling
// 900 ms (30 s), slowSignalSetup 150 ms (5 s); a slow signal = the dial takes
// 200 ms; "slow ICE" connects 750 ms after the peer connections are created.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/exceptions.dart' show MediaConnectException;
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';
import 'full_reconnect_pc_wait_test.dart' show scaledTimeouts;

class _HighRtt extends SignalClient {
  _HighRtt(super.wsConnector);
  @override
  int get rtt => 1500;
}

const recovery = GravixRecoveryOptions(
  slowPathPeerConnectWait: Duration(milliseconds: 900),
  slowSignalSetup: Duration(milliseconds: 150),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;

  Engine newEngine({GravixRecoveryOptions options = recovery, SignalClient Function(FakeSignalServer)? signal}) {
    server = FakeSignalServer()..joinResponse = (_) => fakeJoinResponse(subscriberPrimary: true);
    pcs = FakePcFactory();
    final engine = Engine(
      connectOptions: ConnectOptions(timeouts: scaledTimeouts),
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: options),
      signalClient: signal?.call(server) ?? SignalClient(server.connect),
      peerConnectionCreate: pcs.create,
    );
    addTearDown(engine.dispose);
    return engine;
  }

  void slowSignal() => server.onDial = (_) => Future<void>.delayed(const Duration(milliseconds: 200));
  void iceAfter(int ms) => pcs.onCreate = (pc) => Timer(Duration(milliseconds: ms), pc.connect);

  Future<(Object?, int)> join(Engine engine) async {
    final watch = Stopwatch()..start();
    try {
      await engine.connect('wss://blr1.example', 'tok');
      return (null, watch.elapsedMilliseconds);
    } catch (e) {
      return (e, watch.elapsedMilliseconds);
    }
  }

  test('fresh join, slow signal (setup 200 ms > 150), ICE at 750 ms: joins (the wait goes on to 900 ms)', () async {
    final engine = newEngine();
    slowSignal();
    iceAfter(750);
    final (error, ms) = await join(engine);
    // af9b704 / switch off: MediaConnectException at the 600 ms mediaConnect wait
    expect(error, isNull);
    // ignore: avoid_print
    print('RESULT slow_ice_join_ms=$ms');
  });

  test('fresh join, normal signal, ICE at 750 ms: fails at mediaConnect as before', () async {
    final engine = newEngine();
    iceAfter(750);
    final (error, ms) = await join(engine);
    expect(error, isA<MediaConnectException>());
    expect(ms, inInclusiveRange(550, 600 + 250));
  });

  test('slow signal, dead ICE: fails at the ceiling', () async {
    final engine = newEngine();
    slowSignal();
    final (error, ms) = await join(engine);
    expect(error, isA<MediaConnectException>());
    // 200 ms dial + the 900 ms ceiling of the wait
    expect(ms, inInclusiveRange(1050, 1100 + 250));
  });

  test('normal dial but a signal round trip over 1 s: the wait goes on too', () async {
    final engine = newEngine(signal: (s) => _HighRtt(s.connect));
    iceAfter(750);
    expect((await join(engine)).$1, isNull);
  });

  test('a slow full reconnect: mediaConnect, then on to the ceiling', () async {
    final engine = newEngine();
    autoConnectPcs(pcs);
    await engine.connect('wss://blr1.example', 'tok');
    final restarted = <EngineRestartedEvent>[];
    final listener = engine.createListener()..on<EngineRestartedEvent>(restarted.add);
    addTearDown(listener.dispose);
    slowSignal();
    iceAfter(750);
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => restarted.isNotEmpty, timeout: const Duration(seconds: 3)), isTrue);
  });

  test('fullReconnectMediaConnect: false = the 10 s (scaled 300 ms) full reconnect wait of af9b704', () async {
    final engine = newEngine(
      options: const GravixRecoveryOptions(fullReconnectMediaConnect: false, slowPathPeerConnectWait: null),
    );
    autoConnectPcs(pcs);
    await engine.connect('wss://blr1.example', 'tok');
    final restarted = <EngineRestartedEvent>[];
    final listener = engine.createListener()..on<EngineRestartedEvent>(restarted.add);
    addTearDown(listener.dispose);
    iceAfter(450);
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    await settle(1500);
    expect(restarted, isEmpty);
  });

  test('the switches: on by default, off in legacy', () {
    const d = GravixRecoveryOptions();
    expect(d.fullReconnectMediaConnect, isTrue);
    expect(d.slowPathPeerConnectWait, const Duration(seconds: 30));
    expect(d.slowSignalSetup, const Duration(seconds: 5));
    expect(d.slowSignalRtt, const Duration(seconds: 1));
    expect(GravixRecoveryOptions.legacy.fullReconnectMediaConnect, isFalse);
    expect(GravixRecoveryOptions.legacy.slowPathPeerConnectWait, isNull);
  });
}

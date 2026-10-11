// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// F4 (device test 2026-10-10, r056 / r059, airplane mode 30 s, viewer): the
// full reconnect waited for connectivity; meanwhile the OLD peer connections
// reported failed (+15.4 s), which (upstream #1199 port) queued a full-reconnect
// request. The full reconnect then succeeded (+32.9 s) and dispatched that
// queued request: a SECOND full rejoin 23 ms later, a second video cut, and the
// first rejoin's microphone republish was lost between the sessions.
// (The log's "Connectivity changed [wifi] => [wifi]" requests nothing; a guard
// below pins that.)
//
// A request made against transports that the successful full reconnect has
// since replaced is satisfied by it; one made against the current transports
// (a failure during a resume, a Leave from the node just joined) still runs.

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late FakeConnectivitySignalClient signal;
  late Engine engine;
  tearDown(() async => engine.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';
  int rejoins(int from) => server.dials.skip(from).where((u) => !isResume(u)).length;

  Future<void> viewer() async {
    server = FakeSignalServer();
    signal = FakeConnectivitySignalClient(server.connect);
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(server, pcs, subscriberPrimary: true, signalClient: signal);
  }

  test(
    'a failure of the replaced peer connections, queued during the full reconnect, is not dispatched after it',
    () async {
      await viewer();
      final from = server.dials.length;
      final oldSub = pcs.subscriber, oldPub = pcs.publisher;
      var restarted = 0;
      engine.events.on<EngineRestartedEvent>((_) => restarted++);
      // airplane mode: the signal is gone and the reading says offline; the
      // full reconnect waits for the network
      signal.online = false;
      await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      await settle(300);
      // +15 s: the old peer connections give up while the attempt still waits
      oldSub.setState(rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      oldPub.setState(rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await settle(100);
      // +32 s: the network is back; the full reconnect succeeds
      autoConnectPcs(pcs);
      signal.online = true;
      expect(await eventually(() => restarted == 1, timeout: const Duration(seconds: 6)), isTrue);
      await settle(1500);
      expect(rejoins(from), 1, reason: 'base: a second full rejoin right after the first succeeded');
      expect(restarted, 1);
    },
  );

  test('guard: a same-type connectivity event during the attempt requests nothing', () async {
    await viewer();
    final from = server.dials.length;
    signal.online = false;
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    await settle(200);
    signal.events.emit(
      const SignalConnectivityChangedEvent(oldState: [ConnectivityResult.wifi], state: [ConnectivityResult.wifi]),
    );
    autoConnectPcs(pcs);
    signal.online = true;
    expect(await eventually(() => rejoins(from) >= 1, timeout: const Duration(seconds: 6)), isTrue);
    await settle(1500);
    expect(rejoins(from), 1);
  });

  test('guard: a failure of the NEW session\'s peer connections is still acted on', () async {
    await viewer();
    final from = server.dials.length;
    var restarted = 0;
    engine.events.on<EngineRestartedEvent>((_) => restarted++);
    autoConnectPcs(pcs);
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => restarted == 1, timeout: const Duration(seconds: 4)), isTrue);
    // the new subscriber connection fails right after
    pcs.subscriber.setState(rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    expect(await eventually(() => rejoins(from) == 2, timeout: const Duration(seconds: 4)), isTrue);
  });
}

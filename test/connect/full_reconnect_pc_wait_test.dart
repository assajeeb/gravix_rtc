// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// RECHECK 2026-10-11 r376 (Xiaomi, NLC "Very Bad Network"): a full reconnect's
// signal came up, ICE connected 4.2 s after checking began (ICE RTT 4.1 s),
// the DTLS handshake started -- and "Timed out waiting for PeerConnection to
// connect" fired 10 s after the JoinResponse: a full reconnect waited
// Timeouts.connection (10 s) for its primary peer connection, a fresh join
// Timeouts.mediaConnect (20 s).
//
// Scaled 1/33: Timeouts.connection 300 ms, mediaConnect 600 ms; the full
// reconnect's peer connections connect 450 ms after they are created ("~15 s").
// Only the base API is used (this file also runs against af9b704, where it fails).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/constants.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

const scaledTimeouts = Timeouts(
  connection: Duration(milliseconds: 300),
  debounce: Duration(milliseconds: 5),
  publish: Duration(seconds: 5),
  subscribe: Duration(seconds: 5),
  peerConnection: Duration(seconds: 2),
  iceRestart: Duration(seconds: 5),
  mediaConnect: Duration(milliseconds: 600),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  test('a full reconnect whose peer connection needs ~15 s (scaled) reconnects', () async {
    final server = FakeSignalServer()..joinResponse = (_) => fakeJoinResponse(subscriberPrimary: true);
    final pcs = FakePcFactory();
    autoConnectPcs(pcs);
    final engine = Engine(
      connectOptions: ConnectOptions(timeouts: scaledTimeouts),
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy()),
      signalClient: SignalClient(server.connect),
      peerConnectionCreate: pcs.create,
    );
    addTearDown(engine.dispose);
    await engine.connect('wss://blr1.example', 'tok');
    final restarted = <EngineRestartedEvent>[];
    final listener = engine.createListener()..on<EngineRestartedEvent>(restarted.add);
    addTearDown(listener.dispose);

    // from now on ICE + DTLS take 450 ms: longer than Timeouts.connection, within mediaConnect
    pcs.onCreate = (pc) => Timer(const Duration(milliseconds: 450), pc.connect);
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    // af9b704: every full reconnect gives up its peer connection at 300 ms
    expect(await eventually(() => restarted.isNotEmpty, timeout: const Duration(seconds: 3)), isTrue);
    expect(engine.connectionState.name, 'connected');
  });
}

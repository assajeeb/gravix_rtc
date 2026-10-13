// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The first signal ping goes out with the JoinResponse (2026-10-13).
//
// Field 2026-10-12/13 (an Android app, 6 ms from its region): the room's network chip
// showed "--ms" for the first seconds of every join. The signal client started
// its pings with Timer.periodic(pingInterval) at the JoinResponse, so the first
// round trip existed only one full interval later and Room.signalRttMs read 0
// until then. And after a resume nothing pinged at all: the resume's cleanUp()
// stopped the timer and only a JoinResponse started it again.
//
// Now: one ping right after the JoinResponse (and after a resume's
// ReconnectResponse), then the periodic timer as before.

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_join_phases.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

int pingsOn(FakeWs ws) => ws.sent.where((r) => r.hasPingReq()).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  Room? room;
  tearDown(() async {
    await room?.dispose();
    room = null;
  });

  FakeSignalServer pingingServer({int interval = 5, Duration pong = const Duration(milliseconds: 15)}) {
    final s = FakeSignalServer()..pongDelay = pong;
    s.joinResponse = (_) => fakeJoinResponse(pingTimeout: 15, pingInterval: interval);
    return s;
  }

  test('a join knows its signal round trip one round trip after the JoinResponse, not one interval', () async {
    server = pingingServer(interval: 5);
    pcs = FakePcFactory();
    DateTime? joinAt;
    server.afterJoin = (_) => joinAt = DateTime.now();
    room = await connectedFakeRoom(server, pcs);
    // the pong comes back 15 ms after the ping; the periodic timer's first
    // ping would be 5 s after the JoinResponse
    expect(await eventually(() => room!.signalRttMs > 0, timeout: const Duration(milliseconds: 500)), isTrue);
    expect(room!.signalRttMs, greaterThanOrEqualTo(10));
    expect(server.pingsAt, hasLength(1), reason: 'one ping at the JoinResponse, the next one at the interval');
    expect(server.pingsAt.single.difference(joinAt!).inMilliseconds, lessThan(100));
    expect(pingsOn(server.sockets.single), 1);
  });

  test('the periodic pings still run after the first one', () async {
    server = pingingServer(interval: 1, pong: const Duration(milliseconds: 2));
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs);
    expect(await eventually(() => server.pingsAt.isNotEmpty, timeout: const Duration(milliseconds: 300)), isTrue);
    expect(await eventually(() => server.pingsAt.length >= 2, timeout: const Duration(milliseconds: 1600)), isTrue);
    final gap = server.pingsAt[1].difference(server.pingsAt[0]).inMilliseconds;
    expect(gap, inInclusiveRange(800, 1400), reason: 'the second ping is the interval timer, 1 s later');
  });

  test('a resume pings at once on its new socket (nothing pinged after a resume before)', () async {
    server = pingingServer(interval: 5);
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs);
    expect(await eventually(() => server.pingsAt.length == 1), isTrue);
    final joinSocket = server.sockets.single;

    await room!.engine.handleReconnect(ClientDisconnectReason.signal);
    expect(await eventually(() => server.sockets.length == 2), isTrue);
    final resumeSocket = server.last;
    expect(resumeSocket.isResume, isTrue);
    expect(
      await eventually(() => pingsOn(resumeSocket) == 1, timeout: const Duration(milliseconds: 500)),
      isTrue,
      reason: 'one ping after the ReconnectResponse',
    );
    expect(pingsOn(joinSocket), 1);
  });

  test('a resume restarts the periodic pings too', () async {
    server = pingingServer(interval: 1, pong: const Duration(milliseconds: 2));
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs);
    await room!.engine.handleReconnect(ClientDisconnectReason.signal);
    expect(await eventually(() => server.sockets.length == 2), isTrue);
    final resumeSocket = server.last;
    expect(
      await eventually(() => pingsOn(resumeSocket) >= 2, timeout: const Duration(milliseconds: 1800)),
      isTrue,
      reason: 'the first ping at the ReconnectResponse, the next at the interval',
    );
  });

  test('a join whose server sends no ping config never pings (unchanged)', () async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs);
    await settle(100);
    expect(server.pingsAt, isEmpty);
    expect(room!.signalRttMs, 0);
  });

  test('a JoinResponse read before the dial returned: its ping goes out once the socket counts as connected', () async {
    server = FakeSignalServer();
    // the first frame arrives with the upgrade, before connect() has the socket
    Future<GravixRtcWebSocket> early(
      Uri uri, {
      WebSocketEventHandlers? options,
      Map<String, String>? headers,
      NetworkOptions? networkOptions,
      Object? preconnected,
    }) async {
      final ws = FakeWs(options, uri, server);
      server.sockets.add(ws);
      ws.deliver(lk_rtc.SignalResponse(join: fakeJoinResponse(pingTimeout: 15, pingInterval: 5)));
      return ws;
    }

    final sc = SignalClient(early);
    addTearDown(sc.dispose);
    await sc.connect(
      'wss://blr1.example',
      'tok',
      connectOptions: const ConnectOptions(),
      roomOptions: const RoomOptions(),
    );
    expect(pingsOn(server.sockets.single), 1, reason: 'sent at the connected state, not dropped');
    expect(await eventually(() => sc.rtt > 0, timeout: const Duration(milliseconds: 300)), isTrue);
    await sc.cleanUp();
  });
}

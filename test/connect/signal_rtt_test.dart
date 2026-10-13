// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The signal round trip (`Room.signalRttMs`) is the network's, not the app's
// (2026-10-13).
//
// Field 2026-10-13 (an Android app, ~6-10 ms from its region, signal isolate on): joins
// tapped right after the app opened read firstSignalRtt 766 / 1710 / 221 /
// 1195 ms -- the room's network chip showed "999", "777" -- while the same
// joins from a settled app read 30 / 10 ms. The ping was timestamped when the
// app's isolate sent it and the pong when the app's isolate decoded it: every
// millisecond the app's isolate spent on its own startup work in between was
// counted as network.
//
// Now, with the signal isolate on, the background isolate that owns the socket
// timestamps the ping's write and the pong's arrival itself and hands the
// difference across; the app isolate's delay is excluded. With it off the
// measurement is today's (it cannot be better: the socket's read events are
// tasks on the app's isolate), and apps get the min over the last pings and
// whether a sample is network-only, to judge it.
//
// The server runs in its own isolate (support/isolate_sfu.dart): one on this
// isolate would answer late for the same reason the client reads late.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:fixnum/fixnum.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_join_phases.dart';
import 'package:gravix_rtc/src/connect/gravix_signal_isolate.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/signal_isolate.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/standby.dart';

import '../support/fake_rtc.dart';
import '../support/isolate_sfu.dart';

/// Blocks this isolate for [ms] (an app's startup work).
void _busy(int ms) {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < ms) {}
}

Future<bool> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return cond();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  apiTests();
  requestPingTests();
  group('a busy app isolate (the server in its own isolate)', () {
    late IsolateSfu sfu;

    // every server message leaves this long after it was decided: the pong
    // leaves the server [kPathMs] after the ping reached it
    const kPathMs = 100;
    // the app isolate's work while the pong is on its way and after it arrived
    const kBusyMs = 600;

    setUp(() async {
      installRecoveryChannelMocks();
      HttpOverrides.global = null;
      sfu = await IsolateSfu.start(rttMs: kPathMs, pingIntervalS: 30, pingTimeoutS: 60);
    });

    tearDown(() async {
      GravixSignalIsolate.enabled = false;
      await GravixSignalStandby.closeAll();
      await GravixSignalIsolateRuntime.debugShutdown();
      await sfu.stop();
    });

    /// A join whose first ping's pong arrives while this isolate is busy for
    /// [kBusyMs]; the signal client's RTT once it read the pong.
    Future<SignalClient> joinBusyAtPong() async {
      final sc = SignalClient(GravixRtcWebSocket.connect);
      addTearDown(sc.dispose);
      await sc.connect(
        sfu.url,
        'tok',
        connectOptions: ConnectOptions(timeouts: fastTimeouts(connection: const Duration(seconds: 5))),
        roomOptions: const RoomOptions(),
      );
      // the first ping goes out at the JoinResponse; the server answers it
      // kPathMs after it arrived, and by then this isolate is busy
      await sfu.waitFor((e) => e.name == 'pingReceived');
      _busy(kBusyMs);
      expect(await _until(() => sc.rtt > 0), isTrue, reason: 'the pong was read');
      return sc;
    }

    test('signal isolate on: a busy app isolate does not inflate the round trip', () async {
      GravixSignalIsolate.enabled = true;
      final sc = await joinBusyAtPong();
      expect(
        sc.rtt,
        inInclusiveRange(kPathMs - 5, kPathMs + 150),
        reason: 'the path (${kPathMs} ms), not the app\'s work',
      );
      expect(sc.rttNetworkOnly, isTrue);
      expect(sc.rttCount, 1);
      expect(sc.rttRecent, [sc.rtt]);
    });

    test('signal isolate off: today\'s measurement, the app isolate\'s delay included', () async {
      final sc = await joinBusyAtPong();
      expect(sc.rtt, greaterThanOrEqualTo(kBusyMs - 20), reason: 'read when the app isolate got to it');
      expect(sc.rttNetworkOnly, isFalse, reason: 'apps can tell this sample may be inflated');
    });

    test('signal isolate on, app isolate idle: the same path reads the same', () async {
      GravixSignalIsolate.enabled = true;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      addTearDown(sc.dispose);
      await sc.connect(
        sfu.url,
        'tok',
        connectOptions: ConnectOptions(timeouts: fastTimeouts(connection: const Duration(seconds: 5))),
        roomOptions: const RoomOptions(),
      );
      expect(await _until(() => sc.rtt > 0), isTrue);
      expect(sc.rtt, inInclusiveRange(kPathMs - 5, kPathMs + 150));
      expect(sc.rttNetworkOnly, isTrue);
    });

    test('signal isolate on: a requested ping is timed in the signal isolate too', () async {
      GravixSignalIsolate.enabled = true;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      addTearDown(sc.dispose);
      await sc.connect(
        sfu.url,
        'tok',
        connectOptions: ConnectOptions(timeouts: fastTimeouts(connection: const Duration(seconds: 5))),
        roomOptions: const RoomOptions(),
      );
      expect(await _until(() => sc.rttCount == 1), isTrue);
      await Future<void>.delayed(SignalClient.requestedPingGap);
      expect(sc.requestPing(), isTrue);
      await sfu.waitFor(
        (e) => e.name == 'pingReceived' && sfu.events.where((x) => x.name == 'pingReceived').length == 2,
      );
      _busy(kBusyMs);
      expect(await _until(() => sc.rttCount == 2), isTrue);
      expect(sc.rtt, inInclusiveRange(kPathMs - 5, kPathMs + 150), reason: 'not the app isolate\'s ${kBusyMs} ms');
      expect(sc.rttRecentNetworkOnly, isTrue);
    });
  });
}

/// A socket that timed the pong of ping [timedTs] itself (as the signal
/// isolate's socket does) as [timedMs].
class _TimedWs extends FakeWs {
  _TimedWs(super.handlers, super.uri, super.server, this.timedTs, this.timedMs);
  final int timedTs, timedMs;
  final pingsTimed = <int>[];

  @override
  void gravixSendPing(List<int> data, int pingTimestamp) {
    pingsTimed.add(pingTimestamp);
    send(data);
  }

  @override
  int? gravixPongRttMs(int pingTimestamp) => pingTimestamp == timedTs ? timedMs : null;
}

lk_rtc.SignalResponse _pong(int ts) => lk_rtc.SignalResponse(
  pongResp: lk_rtc.Pong(lastPingTimestamp: Int64(ts), timestamp: Int64(ts)),
);

int _ago(int ms) => DateTime.timestamp().millisecondsSinceEpoch - ms;

void apiTests() {
  group('the samples (fake socket)', () {
    late FakeSignalServer server;
    Room? room;
    setUp(installRecoveryChannelMocks);
    tearDown(() async {
      await room?.dispose();
      room = null;
    });

    test('Room.signalRtt: recent samples, their count, their min; nothing before the first pong', () async {
      server = FakeSignalServer()
        ..answerPings = false
        ..joinResponse = ((_) => fakeJoinResponse(pingTimeout: 60, pingInterval: 30));
      room = await connectedFakeRoom(server, FakePcFactory());
      final r = room!;
      expect(r.signalRttMs, 0);
      expect(r.signalRttMinMs, 0);
      expect(r.signalRtt.count, 0);
      expect(r.signalRtt.recentMs, isEmpty);
      expect(r.signalRtt.lastMs, 0);

      // the app isolate was busy for the first two pings
      for (final ms in const [900, 40, 300, 25, 60, 700]) {
        server.last.deliver(_pong(_ago(ms)));
        await settle(2);
      }
      final s = r.signalRtt;
      expect(s.count, 6);
      expect(s.recentMs, hasLength(GravixSignalRtt.window));
      const want = [40, 300, 25, 60, 700];
      for (var i = 0; i < want.length; i++) {
        expect(s.recentMs[i], inInclusiveRange(want[i], want[i] + 30), reason: 'oldest first: $s');
      }
      expect(r.signalRttMinMs, inInclusiveRange(25, 55), reason: 'the min of the last 5, not the last');
      expect(r.signalRttMs, inInclusiveRange(700, 730), reason: 'signalRttMs stays the last sample');
      expect(s.networkOnly, isFalse, reason: 'timed on this isolate');
      expect(() => (s.recentMs as List).add(1), throwsUnsupportedError);
    });

    test('the socket\'s own timing wins for its ping; any other pong is timed here', () async {
      server = FakeSignalServer()..answerPings = false;
      final timedTs = _ago(500);
      _TimedWs? ws;
      Future<GravixRtcWebSocket> connect(
        Uri uri, {
        WebSocketEventHandlers? options,
        Map<String, String>? headers,
        NetworkOptions? networkOptions,
        Object? preconnected,
      }) async {
        final w = ws = _TimedWs(options, uri, server, timedTs, 7);
        server.sockets.add(w);
        Timer(const Duration(milliseconds: 1), () {
          w.deliver(lk_rtc.SignalResponse(join: fakeJoinResponse(pingTimeout: 60, pingInterval: 30)));
        });
        return w;
      }

      final sc = SignalClient(connect);
      addTearDown(sc.dispose);
      await sc.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: const ConnectOptions(),
        roomOptions: const RoomOptions(),
      );
      // the pings go out through gravixSendPing: the pingReq (timed), not the legacy ping
      expect(await eventually(() => ws!.pingsTimed.length == 1), isTrue);
      expect(ws!.sent.where((r) => r.hasPingReq()).single.pingReq.timestamp.toInt(), ws!.pingsTimed.single);
      expect(ws!.sent.where((r) => r.hasPing()), hasLength(1), reason: 'the legacy ping still goes out, untimed');

      ws!.deliver(_pong(timedTs));
      await settle(2);
      expect(sc.rtt, 7, reason: 'the socket timed it (the app isolate\'s 500 ms excluded)');
      expect(sc.rttNetworkOnly, isTrue);
      expect(sc.rttRecentNetworkOnly, isTrue, reason: 'every sample of the window was timed there');

      // a pong the socket did not time (a stale or foreign timestamp): here
      ws!.deliver(_pong(_ago(300)));
      await settle(2);
      expect(sc.rtt, inInclusiveRange(300, 330));
      expect(sc.rttNetworkOnly, isFalse);
      expect(sc.rttRecentNetworkOnly, isFalse, reason: 'one sample of the window was timed here');
      expect(sc.rttCount, 2);
    });

    test('a new connection starts a new window; the count keeps growing', () async {
      server = FakeSignalServer()
        ..answerPings = false
        ..joinResponse = ((_) => fakeJoinResponse(pingTimeout: 60, pingInterval: 30));
      final sc = SignalClient(server.connect);
      addTearDown(sc.dispose);
      await sc.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: const ConnectOptions(),
        roomOptions: const RoomOptions(),
      );
      expect(await eventually(() => sc.participantSid != null), isTrue);
      server.last.deliver(_pong(_ago(20)));
      server.last.deliver(_pong(_ago(30)));
      await settle(2);
      expect(sc.rttRecent, hasLength(2));

      await sc.connect(
        'wss://blr1.example',
        'tok',
        connectOptions: const ConnectOptions(),
        roomOptions: const RoomOptions(),
        reconnect: true,
      );
      expect(sc.rttRecent, isEmpty, reason: 'a resume may be a new path');
      expect(sc.rttCount, 2);
      expect(sc.rtt, inInclusiveRange(30, 60), reason: 'the last value is kept, as before');
      server.last.deliver(_pong(_ago(15)));
      await settle(2);
      expect(sc.rttRecent, hasLength(1));
      expect(sc.rttCount, 3);
    });
  });

  group('the signal isolate times its pings (local echo server)', () {
    late HttpServer http;
    setUp(() async {
      installRecoveryChannelMocks();
      HttpOverrides.global = null;
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen(ws.add);
      });
    });
    tearDown(() async {
      GravixSignalIsolate.enabled = false;
      await GravixSignalIsolateRuntime.debugShutdown();
      await http.close(force: true);
    });

    Future<(GravixRtcWebSocket, List<List<int>>)> open() async {
      final got = <List<int>>[];
      final ws = await GravixRtcWebSocket.connect(
        Uri.parse('ws://127.0.0.1:${http.port}/rtc'),
        options: WebSocketEventHandlers(onData: (dynamic d) => got.add(List<int>.from(d as List<int>))),
      );
      addTearDown(ws.dispose);
      return (ws, got);
    }

    test('a pong to a ping it wrote: timed there; anything else: not', () async {
      GravixSignalIsolate.enabled = true;
      final (ws, got) = await open();
      expect(ws.gravixViaIsolate, isTrue);

      // (the echo server sends back what it got: a pong frame "answers" itself)
      final pong = _pong(1234).writeToBuffer();
      ws.gravixSendPing(pong, 1234);
      expect(await _until(() => got.length == 1), isTrue);
      expect(got.single, pong, reason: 'the bytes pass through unchanged');
      expect(ws.gravixPongRttMs(1234), inInclusiveRange(1, 500));
      expect(ws.gravixPongRttMs(4321), isNull, reason: 'only for the ping it answers');

      // a pong whose ping went out with a plain send: not timed
      ws.send(_pong(555).writeToBuffer());
      expect(await _until(() => got.length == 2), isTrue);
      expect(ws.gravixPongRttMs(555), isNull);

      // a frame that is not a pong, written as a ping: passes through, not timed
      final join = lk_rtc.SignalResponse(join: fakeJoinResponse()).writeToBuffer();
      ws.gravixSendPing(join, 77);
      expect(await _until(() => got.length == 3), isTrue);
      expect(got.last, join);
      expect(ws.gravixPongRttMs(77), isNull);
    });

    test('off: the socket on this isolate times nothing (the signal client does)', () async {
      final (ws, got) = await open();
      expect(ws.gravixViaIsolate, isFalse);
      final pong = _pong(99).writeToBuffer();
      ws.gravixSendPing(pong, 99);
      expect(await _until(() => got.length == 1), isTrue);
      expect(got.single, pong);
      expect(ws.gravixPongRttMs(99), isNull);
    });
  });
}

/// Room.requestSignalPing (2026-10-13): one ping now, so an app that knows
/// its own isolate just got idle (a join gate opening) can have a fresh round
/// trip ~1 RTT later instead of waiting for the periodic ping (5 s on the
/// fleet: PingIntervalSeconds in the SFU).
void requestPingTests() {
  group('Room.requestSignalPing', () {
    late FakeSignalServer server;
    Room? room;
    setUp(installRecoveryChannelMocks);
    tearDown(() async {
      await room?.dispose();
      room = null;
    });

    FakeSignalServer pinging({int interval = 30}) => FakeSignalServer()
      ..pongDelay = const Duration(milliseconds: 15)
      ..joinResponse = ((_) => fakeJoinResponse(pingTimeout: 60, pingInterval: interval));

    test('connected: one ping now, its round trip one round trip later', () async {
      server = pinging();
      room = await connectedFakeRoom(server, FakePcFactory());
      expect(await eventually(() => room!.signalRtt.count == 1), isTrue, reason: 'the JoinResponse ping');
      await Future<void>.delayed(SignalClient.requestedPingGap);
      expect(room!.requestSignalPing(), isTrue);
      expect(server.pingsAt, hasLength(2), reason: 'sent at once, not at the 30 s interval');
      expect(await eventually(() => room!.signalRtt.count == 2, timeout: const Duration(milliseconds: 300)), isTrue);
      expect(room!.signalRttMs, inInclusiveRange(10, 200));
    });

    test(
      'rate-limited: no second ping within ${SignalClient.requestedPingGap.inMilliseconds} ms of the last one',
      () async {
        server = pinging();
        room = await connectedFakeRoom(server, FakePcFactory());
        expect(await eventually(() => server.pingsAt.length == 1), isTrue);
        expect(room!.requestSignalPing(), isFalse, reason: 'the JoinResponse ping just went out');
        await Future<void>.delayed(SignalClient.requestedPingGap);
        expect(room!.requestSignalPing(), isTrue);
        expect(room!.requestSignalPing(), isFalse);
        expect(server.pingsAt, hasLength(2));
      },
    );

    test('a server that asked for no pings gets none', () async {
      server = FakeSignalServer()..joinResponse = ((_) => fakeJoinResponse());
      room = await connectedFakeRoom(server, FakePcFactory());
      await Future<void>.delayed(SignalClient.requestedPingGap);
      expect(room!.requestSignalPing(), isFalse);
      expect(server.pingsAt, isEmpty);
    });

    test('not connected: a no-op', () async {
      final sc = SignalClient(FakeSignalServer().connect);
      addTearDown(sc.dispose);
      expect(sc.requestPing(), isFalse);

      server = pinging();
      room = await connectedFakeRoom(server, FakePcFactory());
      await Future<void>.delayed(SignalClient.requestedPingGap);
      await room!.disconnect();
      final before = server.pingsAt.length;
      expect(room!.requestSignalPing(), isFalse);
      expect(server.pingsAt, hasLength(before));
    });
  });
}

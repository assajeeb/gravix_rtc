// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field test 2026-10-05: a resume that reached a participant the server had
// already closed was answered Leave{RECONNECT} ("could not restart participant"),
// yet the client resumed 3-4 more times before the full rejoin (10-17 s of extra
// outage). Now the first refusal goes straight to the full rejoin, at once.
//
// And one session per identity: a resume and a fresh connect never run at the
// same time in one engine; a fresh connect or a disconnect cancels the resume in
// flight and its late socket never becomes the session.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/reconnect_policy.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/constants.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

class _FakeWs extends GravixRtcWebSocket {
  _FakeWs(this.handlers) {
    onDispose(() async {
      closed = true;
      handlers?.onDispose?.call();
    });
  }
  final WebSocketEventHandlers? handlers;
  final sent = <lk_rtc.SignalRequest>[];
  bool closed = false;

  @override
  void send(List<int> data) {
    if (closed) return;
    sent.add(lk_rtc.SignalRequest.fromBuffer(data));
  }

  /// A server message.
  void deliver(lk_rtc.SignalResponse r) => handlers?.onData?.call(r.writeToBuffer());

  /// The server closes the socket.
  Future<void> serverClose() => dispose();
}

/// What the scripted server does with a resume (reconnect=1) dial.
enum ResumeScript { leaveReconnectThenClose, leaveResumeThenClose, closeNoMessage, refuseUpgrade, hang }

/// A signal server: fresh joins open a socket (and say nothing); resumes follow
/// [resumeScript]. Every socket and dial is recorded.
class FakeServer {
  ResumeScript resumeScript = ResumeScript.leaveReconnectThenClose;
  final sockets = <_FakeWs>[];
  final dials = <Uri>[];
  final resumeDialAt = <DateTime>[];

  /// For [ResumeScript.hang]: completes the pending resume dial.
  Completer<void>? hangGate;

  Future<GravixRtcWebSocket> connect(
    Uri uri, {
    WebSocketEventHandlers? options,
    Map<String, String>? headers,
    NetworkOptions? networkOptions,
    Object? preconnected,
  }) async {
    dials.add(uri);
    final resume = uri.queryParameters['reconnect'] == '1';
    if (!resume) {
      final ws = _FakeWs(options);
      sockets.add(ws);
      return ws;
    }
    resumeDialAt.add(DateTime.now());
    switch (resumeScript) {
      case ResumeScript.refuseUpgrade:
        throw WebSocketException('Failed to connect', 'not upgraded (500)');
      case ResumeScript.hang:
        hangGate = Completer<void>();
        await hangGate!.future;
        final ws = _FakeWs(options);
        sockets.add(ws);
        return ws;
      case ResumeScript.leaveReconnectThenClose:
      case ResumeScript.leaveResumeThenClose:
      case ResumeScript.closeNoMessage:
        final ws = _FakeWs(options);
        sockets.add(ws);
        // the server's answer lands right after the upgrade
        Timer(const Duration(milliseconds: 5), () async {
          if (resumeScript != ResumeScript.closeNoMessage) {
            ws.deliver(
              lk_rtc.SignalResponse(
                leave: lk_rtc.LeaveRequest(
                  reason: lk_models.DisconnectReason.STATE_MISMATCH,
                  action: resumeScript == ResumeScript.leaveResumeThenClose
                      ? lk_rtc.LeaveRequest_Action.RESUME
                      : lk_rtc.LeaveRequest_Action.RECONNECT,
                ),
              ),
            );
          }
          await ws.serverClose();
        });
        return ws;
    }
  }
}

/// Upstream-like delays (0, 300, 1200, ...) so an "at once" retry is visible.
class _Policy extends ReconnectPolicy {
  @override
  int? nextRetryDelayInMs(ReconnectContext context) =>
      context.retryCount >= 6 ? null : const [0, 300, 1200, 2700, 4800, 7000][context.retryCount];
}

/// The real resume path; the full reconnect only records itself.
class TestEngine extends Engine {
  TestEngine(SignalClient sc, {Duration connectTimeout = const Duration(seconds: 10)})
    : super(
        connectOptions: ConnectOptions(
          timeouts: Timeouts(
            connection: connectTimeout,
            debounce: const Duration(milliseconds: 20),
            publish: const Duration(seconds: 10),
            subscribe: const Duration(seconds: 10),
            peerConnection: const Duration(seconds: 10),
            iceRestart: const Duration(seconds: 10),
          ),
        ),
        roomOptions: RoomOptions(reconnectPolicy: _Policy()),
        signalClient: sc,
      );

  int resumes = 0;
  final restarts = <DateTime>[];
  Completer<void> restarted = Completer<void>();

  @override
  Future<void> resumeConnection(ClientDisconnectReason reason, {lk_models.ReconnectReason? reconnectReason}) {
    resumes++;
    return super.resumeConnection(reason, reconnectReason: reconnectReason);
  }

  @override
  Future<void> restartConnection({String? regionUrl}) async {
    restarts.add(DateTime.now());
    if (!restarted.isCompleted) restarted.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      m.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
  });

  late FakeServer server;
  late SignalClient sc;
  late TestEngine engine;

  Future<void> setUpEngine({Duration connectTimeout = const Duration(seconds: 10)}) async {
    server = FakeServer();
    sc = SignalClient(server.connect);
    engine = TestEngine(sc, connectTimeout: connectTimeout)
      ..url = 'wss://sfu.example'
      ..token = 'tok';
    // a session that was connected
    await sc.connect(
      'wss://sfu.example',
      'tok',
      connectOptions: const ConnectOptions(),
      roomOptions: const RoomOptions(),
    );
    sc.participantSid = 'PA_1';
  }

  tearDown(() async {
    await engine.dispose();
  });

  group('first rejected resume -> full rejoin at once', () {
    for (final script in [
      ResumeScript.leaveReconnectThenClose,
      ResumeScript.closeNoMessage,
      ResumeScript.refuseUpgrade,
    ]) {
      test('$script: one resume, then the full reconnect', () async {
        await setUpEngine();
        server.resumeScript = script;
        // the signal dropped: the engine resumes first (upstream behaviour)
        await engine.handleReconnect(ClientDisconnectReason.signal);
        await engine.restarted.future.timeout(const Duration(seconds: 3));
        expect(engine.resumes, 1, reason: 'no second resume against a closed participant');
        expect(engine.restarts, hasLength(1));
        if (script != ResumeScript.refuseUpgrade) {
          // the server's answer is acted on now, not after the 10 s ReconnectResponse
          // timeout, and the rejoin is not delayed by the back-off (300 ms here)
          final gap = engine.restarts.single.difference(server.resumeDialAt.single);
          expect(gap, lessThan(const Duration(milliseconds: 250)));
        }
      });
    }

    test('Leave{RESUME} during a resume: resume again, at once, not a full rejoin', () async {
      await setUpEngine();
      server.resumeScript = ResumeScript.leaveResumeThenClose;
      await engine.handleReconnect(ClientDisconnectReason.signal);
      // let two resume attempts happen, then switch the server to refusing
      while (server.resumeDialAt.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      server.resumeScript = ResumeScript.leaveReconnectThenClose;
      await engine.restarted.future.timeout(const Duration(seconds: 3));
      expect(engine.resumes, greaterThanOrEqualTo(2));
      final gap = server.resumeDialAt[1].difference(server.resumeDialAt[0]);
      expect(gap, lessThan(const Duration(milliseconds: 250)));
    });

    test('a resume whose socket opens but never answers is a refusal (full rejoin after the timeout)', () async {
      await setUpEngine(connectTimeout: const Duration(milliseconds: 200));
      server.resumeScript = ResumeScript.hang;
      await engine.handleReconnect(ClientDisconnectReason.signal);
      while (server.hangGate == null) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      server.hangGate!.complete(); // the socket opens; the server says nothing
      await engine.restarted.future.timeout(const Duration(seconds: 3));
      expect(engine.resumes, 1);
    });

    test('a Leave{RECONNECT} on a connected session still reconnects fully, at once', () async {
      await setUpEngine();
      final ws = server.sockets.single;
      final t0 = DateTime.now();
      ws.deliver(
        lk_rtc.SignalResponse(
          leave: lk_rtc.LeaveRequest(
            reason: lk_models.DisconnectReason.STATE_MISMATCH,
            action: lk_rtc.LeaveRequest_Action.RECONNECT,
          ),
        ),
      );
      await engine.restarted.future.timeout(const Duration(seconds: 3));
      expect(engine.resumes, 0);
      expect(engine.restarts.single.difference(t0), lessThan(const Duration(milliseconds: 250)));
    });
  });

  group('one session per identity', () {
    test('a fresh connect cancels the resume in flight; its late socket is closed, nothing is retried', () async {
      await setUpEngine(connectTimeout: const Duration(milliseconds: 300));
      server.resumeScript = ResumeScript.hang;
      await engine.handleReconnect(ClientDisconnectReason.signal);
      while (server.hangGate == null) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(engine.gravixResumeInFlight, isTrue);

      // the app joins again while the resume is still dialling
      final fresh = engine.connect('wss://sfu-b.example', 'tok');
      expect(engine.gravixResumeInFlight, isFalse, reason: 'cancelled before the fresh dial');
      // the resume's socket lands late
      server.hangGate!.complete();
      await expectLater(fresh, throwsA(anything)); // no join response from the fake: times out
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final resumeSocket = server.sockets.firstWhere(
        (s) => server.dials[server.sockets.indexOf(s)].queryParameters['reconnect'] == '1',
      );
      expect(resumeSocket.closed, isTrue, reason: 'a late resume socket never becomes the session');
      expect(engine.resumes, 1, reason: 'the cancelled resume does not schedule another');
      expect(engine.restarts, isEmpty);
      expect(server.dials.where((u) => u.queryParameters['reconnect'] == '1'), hasLength(1));
    });

    test('disconnect during a resume: the late socket is closed, no further attempt', () async {
      await setUpEngine();
      server.resumeScript = ResumeScript.hang;
      await engine.handleReconnect(ClientDisconnectReason.signal);
      while (server.hangGate == null) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await engine.disconnect();
      server.hangGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.sockets.last.closed, isTrue);
      expect(engine.resumes, 1);
      expect(engine.restarts, isEmpty);
      expect(engine.isPendingReconnect, isFalse);
    });

    test('a full reconnect leaves the old session first (no cross-node duplicate eviction)', () async {
      server = FakeServer();
      sc = SignalClient(server.connect);
      engine = TestEngine(sc)
        ..url = 'wss://sfu.example'
        ..token = 'tok';
      await sc.connect(
        'wss://sfu.example',
        'tok',
        connectOptions: const ConnectOptions(),
        roomOptions: const RoomOptions(),
      );
      final old = server.sockets.single;
      // the real restartConnection, up to its connect (which fails: no join response)
      final real =
          Engine(
              connectOptions: const ConnectOptions(
                timeouts: Timeouts(
                  connection: Duration(milliseconds: 100),
                  debounce: Duration(milliseconds: 20),
                  publish: Duration(seconds: 1),
                  subscribe: Duration(seconds: 1),
                  peerConnection: Duration(seconds: 1),
                  iceRestart: Duration(seconds: 1),
                ),
              ),
              roomOptions: const RoomOptions(),
              signalClient: sc,
            )
            ..url = 'wss://sfu.example'
            ..token = 'tok';
      addTearDown(real.dispose);
      await expectLater(real.restartConnection(), throwsA(anything));
      expect(old.sent.where((r) => r.hasLeave()), hasLength(1));
      expect(old.closed, isTrue);
    });
  });

  group('SignalClient connect generation', () {
    test('a dial superseded by cleanUp is closed (with a leave) and delivers nothing', () async {
      final gate = Completer<void>();
      _FakeWs? late;
      final events = <Object>[];
      final client = SignalClient((uri, {options, headers, networkOptions, preconnected}) async {
        await gate.future;
        return late = _FakeWs(options);
      });
      addTearDown(client.dispose);
      client.events.listen(events.add);
      final c = client.connect(
        'wss://sfu.example',
        'tok',
        connectOptions: const ConnectOptions(),
        roomOptions: const RoomOptions(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await client.cleanUp(); // e.g. disconnect while dialling
      gate.complete();
      await expectLater(c, throwsA(anything));
      expect(late!.closed, isTrue);
      expect(late!.sent.where((r) => r.hasLeave()), hasLength(1));
      expect(client.connectionState, ConnectionState.disconnected);
      events.clear();
      late!.deliver(lk_rtc.SignalResponse(leave: lk_rtc.LeaveRequest()));
      expect(events, isEmpty);
    });
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.13, field 2026-10-06/07: a phone in a transient network stall (ICE RTT
// 3.9 s) timed out its peer connection on the first join attempt; the SDK threw
// MediaConnectException and gave up. Room.connect now joins again
// (ConnectOptions.joinRetries, default 2) on a media-connect failure, never on a
// refusal, never after a leave, and a fresh join waits Timeouts.mediaConnect
// (20 s) for its peer connection instead of 10 s.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/constants.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/exceptions.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

SignalClient _noNetwork() => SignalClient((uri, {options, headers, networkOptions, preconnected}) async {
  throw Exception('no network in tests');
});

/// An engine whose fresh joins follow [script]: null = the join succeeds,
/// anything else is thrown, after the same EngineDisconnectedEvent the real
/// engine emits for a failed fresh join (deferred to the room when it may retry).
class ScriptedEngine extends Engine {
  ScriptedEngine(this.script, {SignalClient? signal, this.dialSignal = false})
    : super(
        connectOptions: const ConnectOptions(),
        roomOptions: const RoomOptions(),
        signalClient: signal ?? _noNetwork(),
      );

  /// Each attempt really opens the signal socket first (a fake WebSocket), as a
  /// join that got its JoinResponse has.
  final bool dialSignal;

  final List<Object?> script;
  int attempts = 0;
  int cleanUps = 0;

  /// The server ends the attempt with Leave{DISCONNECT} before it fails (what a
  /// server refusal after the WebSocket upgrade looks like on the client).
  bool serverLeaveFirst = false;

  /// Holds the attempt with this index (0-based) until completed.
  final holds = <int, Completer<void>>{};

  @override
  Future<void> connect(
    String url,
    String token, {
    ConnectOptions? connectOptions,
    RoomOptions? roomOptions,
    FastConnectOptions? fastConnectOptions,
    RegionUrlProvider? regionUrlProvider,
  }) async {
    final i = attempts++;
    await holds[i]?.future;
    if (dialSignal) {
      await signalClient.connect(url, token, connectOptions: const ConnectOptions(), roomOptions: const RoomOptions());
    }
    final step = i < script.length ? script[i] : null;
    if (step == null) return;
    if (serverLeaveFirst) await disconnect(reason: DisconnectReason.joinFailure);
    if (!gravixDeferJoinFailure) {
      events.emit(EngineDisconnectedEvent(reason: Engine.gravixJoinFailureReason(step)));
    }
    throw step;
  }

  @override
  Future<void> cleanUp() async {
    cleanUps++;
    await super.cleanUp();
  }
}

ConnectOptions _opts({int? retries, List<Duration> delays = const [Duration(milliseconds: 10)]}) =>
    ConnectOptions(joinRetries: retries ?? ConnectOptions.defaultJoinRetries, joinRetryDelays: delays);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
    messenger.setMockMethodCallHandler(Native.channel, (call) async => null);
  });

  tearDown(() => messenger.setMockMethodCallHandler(Native.channel, null));

  ({Room room, ScriptedEngine engine, List<RoomJoinRetryEvent> retries, List<RoomDisconnectedEvent> disconnects})
  setUpRoom(List<Object?> script) {
    final engine = ScriptedEngine(script);
    final room = Room(engine: engine);
    final retries = <RoomJoinRetryEvent>[];
    final disconnects = <RoomDisconnectedEvent>[];
    room.events.on<RoomJoinRetryEvent>(retries.add);
    room.events.on<RoomDisconnectedEvent>(disconnects.add);
    return (room: room, engine: engine, retries: retries, disconnects: disconnects);
  }

  // let async event delivery and the disconnect handler's cleanup settle
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  group('defaults', () {
    test('2 retries after 0.5 s and 1.5 s; a fresh join waits 20 s for its peer connection', () {
      const o = ConnectOptions();
      expect(o.joinRetries, 2);
      expect(o.joinRetryDelay(1), const Duration(milliseconds: 500));
      expect(o.joinRetryDelay(2), const Duration(milliseconds: 1500));
      expect(o.joinRetryDelay(3), const Duration(milliseconds: 1500), reason: 'the last delay repeats');
      expect(Timeouts.defaultTimeouts.mediaConnect, const Duration(seconds: 20));
      // everything else is the 0.4.12 value
      expect(Timeouts.defaultTimeouts.connection, const Duration(seconds: 10));
      expect(Timeouts.defaultTimeouts.peerConnection, const Duration(seconds: 10));
      expect(const ConnectOptions(joinRetryDelays: []).joinRetryDelay(1), Duration.zero);
    });

    test('retryable: a media-connect failure only', () {
      expect(gravixIsJoinRetryable(MediaConnectException('pc')), isTrue);
      // a server refuses an upgraded join (room full) with a Leave and no
      // JoinResponse: the client sees the JoinResponse timeout
      expect(gravixIsJoinRetryable(ConnectException('t', reason: ConnectionErrorReason.Timeout)), isFalse);
      for (final code in [401, 403, 404, 429]) {
        expect(
          gravixIsJoinRetryable(
            ConnectException('refused', reason: ConnectionErrorReason.NotAllowed, statusCode: code),
          ),
          isFalse,
          reason: '$code',
        );
      }
      expect(
        gravixIsJoinRetryable(
          ConnectException('no internet connection', reason: ConnectionErrorReason.InternalError, statusCode: 503),
        ),
        isFalse,
      );
      expect(gravixIsJoinRetryable(CertificatePinningException('pin', host: 'h')), isFalse);
      expect(gravixIsJoinRetryable(WebSocketException('connect superseded')), isFalse);
      expect(gravixIsJoinRetryable(Exception('other')), isFalse);
    });
  });

  group('Room.connect join retry', () {
    test(
      'a media-connect failure, then success: one retry event, no disconnect event, the attempt cleaned up',
      () async {
        final t = setUpRoom([MediaConnectException('pc timeout'), null]);
        await t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts());
        await settle();
        expect(t.engine.attempts, 2);
        expect(t.retries, hasLength(1));
        expect(t.retries.single.retry, 1);
        expect(t.retries.single.maxRetries, 2);
        expect(t.retries.single.error, isA<MediaConnectException>());
        expect(t.disconnects, isEmpty, reason: 'the app is not told "disconnected" while the join is retried');
        expect(t.engine.cleanUps, greaterThanOrEqualTo(1), reason: 'the failed attempt is torn down before the retry');
        expect(t.engine.gravixDeferJoinFailure, isFalse);
        await t.room.dispose();
      },
    );

    test('the server ended the attempt with a Leave: no retry', () async {
      final first = MediaConnectException('pc');
      final t = setUpRoom([first, null]);
      t.engine.serverLeaveFirst = true;
      await expectLater(t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts()), throwsA(same(first)));
      await settle();
      expect(t.engine.attempts, 1);
      expect(t.retries, isEmpty);
      expect(t.disconnects.map((e) => e.reason), contains(DisconnectReason.joinFailure));
      await t.room.dispose();
    });

    test('a fast connect (it publishes the mic inside the join) is never retried', () async {
      final first = MediaConnectException('pc');
      final t = setUpRoom([first, null]);
      await expectLater(
        t.room.connect(
          'wss://sfu.example',
          'tok',
          connectOptions: _opts(),
          fastConnectOptions: FastConnectOptions(microphone: const TrackOption(enabled: true)),
        ),
        throwsA(same(first)),
      );
      await settle();
      expect(t.engine.attempts, 1);
      expect(t.retries, isEmpty);
      expect(t.disconnects.map((e) => e.reason), [DisconnectReason.joinFailure]);
      await t.room.dispose();
    });

    test('the failed attempt sends its leave on its own socket and closes it before the retry dials', () async {
      final sockets = <_FakeWs>[];
      final log = <String>[];
      final signal = SignalClient((uri, {options, headers, networkOptions, preconnected}) async {
        log.add('dial');
        final ws = _FakeWs(log);
        sockets.add(ws);
        return ws;
      });
      final engine = ScriptedEngine([MediaConnectException('pc'), null], signal: signal, dialSignal: true);
      final room = Room(engine: engine);
      await room.connect('wss://sfu.example', 'tok', connectOptions: _opts());
      expect(engine.attempts, 2);
      expect(sockets, hasLength(2));
      expect(log, ['dial', 'leave', 'close', 'dial'], reason: 'leave, then close, then the retry dials');
      expect(sockets.first.closed, isTrue);
      expect(sockets.last.closed, isFalse, reason: 'the retry keeps its own socket');
      await room.dispose();
    });

    test('retries exhausted: the same exception as before, exactly one joinFailure', () async {
      final last = MediaConnectException('third');
      final t = setUpRoom([MediaConnectException('first'), MediaConnectException('second'), last]);
      await expectLater(t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts()), throwsA(same(last)));
      await settle();
      expect(t.engine.attempts, 3);
      expect(t.retries.map((e) => e.retry), [1, 2]);
      expect(t.disconnects.map((e) => e.reason), [DisconnectReason.joinFailure]);
      await t.room.dispose();
    });

    test('the delays between attempts are the configured ones', () async {
      final t = setUpRoom([MediaConnectException('a'), MediaConnectException('b'), null]);
      final sw = Stopwatch()..start();
      await t.room.connect(
        'wss://sfu.example',
        'tok',
        connectOptions: _opts(delays: const [Duration(milliseconds: 100), Duration(milliseconds: 250)]),
      );
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(350));
      expect(t.retries.map((e) => e.delay.inMilliseconds), [100, 250]);
      await t.room.dispose();
    });

    for (final refusal in [
      ConnectException('no JoinResponse', reason: ConnectionErrorReason.Timeout),
      ConnectException('unauthorized', reason: ConnectionErrorReason.NotAllowed, statusCode: 401),
      ConnectException('forbidden', reason: ConnectionErrorReason.NotAllowed, statusCode: 403),
      ConnectException('no internet connection', reason: ConnectionErrorReason.InternalError, statusCode: 503),
      Exception('anything else'),
    ]) {
      test('no retry on $refusal: one attempt, the error, one joinFailure', () async {
        final t = setUpRoom([refusal, null]);
        await expectLater(t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts()), throwsA(same(refusal)));
        await settle();
        expect(t.engine.attempts, 1);
        expect(t.retries, isEmpty);
        expect(t.disconnects.map((e) => e.reason), [DisconnectReason.joinFailure]);
        await t.room.dispose();
      });
    }

    test('a refusal on the retry ends the join at once (no further attempt)', () async {
      final refusal = ConnectException('expired', reason: ConnectionErrorReason.NotAllowed, statusCode: 401);
      final t = setUpRoom([MediaConnectException('pc'), refusal, null]);
      await expectLater(t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts()), throwsA(same(refusal)));
      await settle();
      expect(t.engine.attempts, 2);
      expect(t.disconnects.map((e) => e.reason), [DisconnectReason.joinFailure]);
      await t.room.dispose();
    });

    test('joinRetries 0 = the 0.4.12 path: one attempt, the engine reports the failure itself', () async {
      final first = MediaConnectException('pc');
      final t = setUpRoom([first, null]);
      await expectLater(
        t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts(retries: 0)),
        throwsA(same(first)),
      );
      await settle();
      expect(t.engine.attempts, 1);
      expect(t.retries, isEmpty);
      expect(t.disconnects.map((e) => e.reason), [DisconnectReason.joinFailure]);
      await t.room.dispose();
    });

    test('a leave during the wait (what GravixRoomService.disconnect does) ends it at once: no retry', () async {
      final first = MediaConnectException('pc');
      final t = setUpRoom([first, null]);
      t.room.events.on<RoomJoinRetryEvent>((_) => t.room.gravixMarkLeaving());
      final sw = Stopwatch()..start();
      await expectLater(
        t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts(delays: const [Duration(seconds: 30)])),
        throwsA(same(first)),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)), reason: 'the 30 s wait is cut short');
      await settle();
      expect(t.engine.attempts, 1, reason: 'nothing is dialled after the leave');
      expect(t.disconnects.map((e) => e.reason), [DisconnectReason.joinFailure]);
      await t.room.dispose();
    });

    test('dispose during the wait: no retry, the connect fails promptly', () async {
      final first = MediaConnectException('pc');
      final t = setUpRoom([first, null]);
      t.room.events.on<RoomJoinRetryEvent>((_) => unawaited(t.room.dispose()));
      final sw = Stopwatch()..start();
      await expectLater(
        t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts(delays: const [Duration(seconds: 30)])),
        throwsA(same(first)),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(t.engine.attempts, 1);
    });

    test('Room.disconnect during the wait: no retry, the connect fails promptly', () async {
      final first = MediaConnectException('pc');
      final t = setUpRoom([first, null]);
      Future<void>? leaving;
      t.room.events.on<RoomJoinRetryEvent>((_) {
        leaving = t.room.disconnect();
      });
      final sw = Stopwatch()..start();
      await expectLater(
        t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts(delays: const [Duration(seconds: 30)])),
        throwsA(same(first)),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(t.engine.attempts, 1);
      // the leave itself completes promptly too (it waited 10 s and threw on a
      // room that was not connected up to 0.4.12)
      await leaving!.timeout(const Duration(seconds: 3));
      await t.room.dispose();
    });

    test('a leave during an attempt in flight: that attempt is the last one', () async {
      final first = MediaConnectException('pc');
      final t = setUpRoom([first, null]);
      final hold = t.engine.holds[0] = Completer<void>();
      final connecting = t.room.connect('wss://sfu.example', 'tok', connectOptions: _opts());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      t.room.gravixMarkLeaving();
      hold.complete();
      await expectLater(connecting, throwsA(same(first)));
      await settle();
      expect(t.engine.attempts, 1);
      expect(t.retries, isEmpty);
      expect(t.disconnects.map((e) => e.reason), [DisconnectReason.joinFailure]);
      await t.room.dispose();
    });
  });

  test('a join again on the same Room: the kept local participant takes the new sid', () async {
    final engine = ScriptedEngine(const []);
    final room = Room(engine: engine);
    lk_rtc.JoinResponse join(String sid) => lk_rtc.JoinResponse(
      participant: lk_models.ParticipantInfo(sid: sid, identity: 'u1'),
    );
    engine.events.emit(EngineJoinResponseEvent(response: join('PA_first')));
    await settle();
    final local = room.localParticipant;
    expect(local?.sid, 'PA_first');
    // the failed attempt's participant is gone on the server; the retry joins anew
    engine.events.emit(EngineJoinResponseEvent(response: join('PA_retry')));
    await settle();
    expect(identical(room.localParticipant, local), isTrue);
    expect(room.localParticipant?.sid, 'PA_retry');
    await room.dispose();
  });

  group('Engine', () {
    test('a failed fresh join emits joinFailure, unless the room deferred it', () async {
      for (final defer in [false, true]) {
        final engine = Engine(
          connectOptions: const ConnectOptions(),
          roomOptions: const RoomOptions(),
          signalClient: _ThrowingSignalClient(MediaConnectException('pc')),
        );
        engine.gravixDeferJoinFailure = defer;
        final seen = <EngineDisconnectedEvent>[];
        engine.events.on<EngineDisconnectedEvent>(seen.add);
        await expectLater(engine.connect('wss://sfu.example', 'tok'), throwsA(isA<MediaConnectException>()));
        await settle();
        expect(seen.map((e) => e.reason), defer ? isEmpty : [DisconnectReason.joinFailure], reason: 'defer=$defer');
        await engine.dispose();
      }
    });

    test('a fresh join waits Timeouts.mediaConnect for its peer connection (not Timeouts.connection)', () async {
      final sc = _ThrowingSignalClient(null);
      final engine = Engine(
        connectOptions: ConnectOptions(
          timeouts: Timeouts.defaultTimeouts.copyWith(
            connection: const Duration(milliseconds: 100),
            mediaConnect: const Duration(milliseconds: 600),
          ),
        ),
        roomOptions: const RoomOptions(),
        signalClient: sc,
      );
      final sw = Stopwatch()..start();
      final joining = engine.connect('wss://sfu.example', 'tok');
      // the JoinResponse arrives; the peer connection never connects
      await Future<void>.delayed(const Duration(milliseconds: 20));
      engine.events.emit(EngineJoinResponseEvent(response: lk_rtc.JoinResponse()));
      await expectLater(joining, throwsA(isA<MediaConnectException>()));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(600));
      await engine.dispose();
    });
  });
}

/// A signal client whose connect throws [error] (or succeeds when null) without
/// any network.
class _ThrowingSignalClient extends SignalClient {
  _ThrowingSignalClient(this.error) : super(GravixRtcWebSocket.connect);
  final Object? error;

  @override
  Future<void> connect(
    String uriString,
    String token, {
    required ConnectOptions connectOptions,
    required RoomOptions roomOptions,
    bool reconnect = false,
    reconnectReason,
  }) async {
    final e = error;
    if (e != null) throw e;
  }
}

/// A fake WebSocket that records the leave it is sent and its close.
class _FakeWs extends GravixRtcWebSocket {
  _FakeWs(this.log) {
    onDispose(() async {
      if (!closed) log.add('close');
      closed = true;
    });
  }
  final List<String> log;
  bool closed = false;

  @override
  void send(List<int> data) {
    if (closed) return;
    if (lk_rtc.SignalRequest.fromBuffer(data).hasLeave()) log.add('leave');
  }
}

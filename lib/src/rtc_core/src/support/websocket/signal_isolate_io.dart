// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GRAVIX (2026-10-12, opt-in): the signalling WebSocket in a background isolate.
//
// Field evidence (a production app on a mid-range Android phone, 6 ms to the SFU): a
// settled app's viewer join had first audio at 1.7 s; 3-6 s after app launch
// the same join took 4.9 s, and wsOpen over an already-open warm connection
// took 0.7-1.5 s. Every step of a join is a task on the app's UI isolate, and
// each waits for whatever the app is doing (startup work, first frames).
//
// The event-loop harness (test/perf/signal_event_loop_harness_test.dart: the
// real Room / SignalClient / dart:io dial / standby pool, a fake SFU in its own
// isolate over wss, flutter_webrtc calls modelled as one task each) counted the
// tasks with the app isolate saturated by 20 ms blocks: a viewer's path to
// media is ~18.5 tasks, ~8.5 of them the socket's (the upgrade request's TLS
// write 1, reading the warm upgrade's reply ~3.5 -- the TLS filter's round
// trips and its read events --, reading the JoinResponse 2, writing the answer
// 2); a host's is ~27, ~11 of them the socket's (+ writing the offer, reading
// the answer). Saturated by 100-300 ms blocks, the warm upgrade's reply was
// read ~1 s after the tap, past its 0.5 s bound (a fresh dial raced it:
// `standby_late`, 12 of 12).
//
// With [GravixSignalIsolateRuntime.enabled] those tasks run in a long-lived
// background isolate instead: the dial (the standby take, the bounded / hedged
// / standby-raced dial of websocket/io.dart -- the same code), TLS, WebSocket
// framing, and the standby pool itself (a warm dart:io connection cannot move
// between isolates, so the pool lives where the socket will). The app's isolate
// gets ONE task per received message (the dial's result and the JoinResponse
// arrive together) and none per sent one (SendPort.send returns at once).
// Harness, 20 ms blocks: viewer 18.5 -> 11.5 tasks (media ready 371 -> 230 ms),
// host 26.7 -> 13.6 (533 -> 271 ms); 100-300 ms blocks: viewer 3.5 -> 2.0 s,
// host 5.1 -> 2.5 s; idle and loops with gaps: unchanged.
//
// The protocol -- SignalClient's state machine, its generation guard, queue,
// ping timers, protobuf decoding, the leave on dispose -- stays on the app's
// isolate, unchanged: only the transport moved.
//
// Not moved, and why: flutter_webrtc. Its peer connections report through
// EventChannels, and messages from the platform reach the ROOT isolate only
// (BackgroundIsolateBinaryMessenger.setMessageHandler throws), so every
// method call and callback of a peer connection stays a task on the app's
// isolate -- the ~8-10 tasks left on each join path. Also on the app's
// isolate: Connectivity() and the device info in the join URL (plugins).
//
// Off unless an app turns it on (GravixSignalIsolate.enabled). Rollback is the
// same flag. Falls back to the in-isolate dial, per dial, when the app installed
// HttpOverrides or IOOverrides (they are per isolate and would not apply in the
// background isolate), when the standby connection handed in lives on this
// isolate (opened before the flag was set), or when the isolate cannot start.
import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../logger.dart';
import '../../options.dart';
import '../../proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import '../websocket.dart';
import 'io.dart';
import 'standby_io.dart';
import 'standby_types.dart';

/// The UI side's handle for a standby connection taken in the signal isolate.
/// The take itself happens there, as the first step of the dial it is handed to
/// (one task less on the app's isolate than a separate round trip); the fields
/// below are filled from the dial's result.
class GravixRemoteStandbyClient {
  GravixRemoteStandbyClient._();

  /// New sockets the taken client opened (see GravixSignalStandby.connectsOf).
  int connects = 0;
}

/// A [GravixStandbyTaken] whose take runs in the signal isolate, as part of the
/// dial it is handed to; read its fields after that dial.
class GravixPipelinedStandbyTake extends GravixStandbyTaken {
  GravixPipelinedStandbyTake._(this.url, this.token, this.wait, GravixRemoteStandbyClient handle)
    : super(outcome: 'pending', client: handle);

  final String url, token;
  final Duration wait;
  bool _resolved = false;
  String _outcome = 'pending';
  int? _ageMs, _waitedMs;
  int _connectsAtTake = 0;
  Duration? _bound;
  bool _usable = true;

  bool get resolved => _resolved;

  /// The dial it was handed to did not go to the signal isolate (an app
  /// HttpOverrides, the isolate not starting): nothing was taken there.
  void _unused() {
    if (_resolved) return;
    _resolved = true;
    _outcome = 'none';
    _usable = false;
  }

  void _resolve(List<Object?> t) {
    _resolved = true;
    _outcome = t[0] as String;
    _ageMs = t[1] as int?;
    _waitedMs = t[2] as int?;
    _connectsAtTake = t[3] as int;
    final boundUs = t[4] as int?;
    _bound = boundUs == null ? null : Duration(microseconds: boundUs);
    _usable = t[5] as bool;
    (client as GravixRemoteStandbyClient).connects = t[6] as int;
  }

  @override
  String get outcome => _outcome;
  @override
  int? get ageMs => _ageMs;
  @override
  int? get waitedMs => _waitedMs;
  @override
  int get connectsAtTake => _connectsAtTake;
  @override
  Duration? get upgradeBound => _bound;

  /// True until the dial says otherwise: the take is handed to the dial.
  @override
  bool get usable => _usable;
}

/// The app-isolate side of a socket that lives in the signal isolate.
class _IsolateWebSocket extends GravixRtcWebSocket {
  _IsolateWebSocket(this._bridge, this.id) {
    onDispose(() async {
      if (!_bridge.alive) return;
      final closed = Completer<void>();
      _bridge.closing[id] = closed;
      _bridge.cmd.send(<Object?>[_kClose, id]);
      // the background socket's close is bounded at 1 s (websocket/io.dart);
      // this only guards against an isolate that went away meanwhile
      await closed.future.timeout(const Duration(milliseconds: 1500), onTimeout: () {});
    });
  }

  final _Bridge _bridge;
  final int id;

  @override
  bool get gravixViaIsolate => true;

  @override
  void send(List<int> data) {
    if (isDisposed || !_bridge.alive) return;
    // ordered with every other command of this isolate (a leave, then the close)
    _bridge.cmd.send(<Object?>[_kSend, id, data]);
  }

  // GRAVIX (2026-10-13, network RTT): the signal isolate stamps the ping's
  // write and its pong's arrival (see _PingClock); the app isolate only reads
  // the difference, so its own delay -- a busy UI isolate right after an app's
  // launch -- is not counted as network.
  @override
  void gravixSendPing(List<int> data, int pingTimestamp) {
    if (isDisposed || !_bridge.alive) return;
    _bridge.cmd.send(<Object?>[_kSendPing, id, data, pingTimestamp]);
  }

  @override
  int? gravixPongRttMs(int pingTimestamp) {
    final p = _bridge.pongs[id];
    return p != null && p.$1 == pingTimestamp ? p.$2 : null;
  }
}

class _PendingDial {
  _PendingDial(this.take);
  final GravixPipelinedStandbyTake? take;
  final done = Completer<GravixRtcWebSocket>();
}

// commands (app -> signal isolate)
const _kDial = 0, _kSend = 1, _kClose = 2, _kSbOpen = 3, _kSbReopenAll = 4, _kSbCloseAll = 5, _kSendPing = 6;
// events (signal isolate -> app)
const _kReady = 10,
    _kDialOk = 11,
    _kDialErr = 12,
    _kData = 13,
    _kDone = 14,
    _kError = 15,
    _kClosed = 16,
    _kReply = 17,
    _kLog = 18;

class _Bridge {
  _Bridge(this.cmd, this.isolate, this.rx, this.exitRx);
  final SendPort cmd;
  final Isolate isolate;
  final RawReceivePort rx, exitRx;
  bool alive = true;
  int nextId = 1;
  final dials = <int, _PendingDial>{};

  /// Live sockets by id: their handlers (data may arrive before the dial's
  /// result is read: the handlers are known from the start).
  final handlers = <int, WebSocketEventHandlers?>{};
  final closing = <int, Completer<void>>{};
  final replies = <int, Completer<Object?>>{};

  /// GRAVIX (2026-10-13, network RTT): per socket, the last pong the signal
  /// isolate timed: (the ping's timestamp, its round trip in ms). Set before
  /// the pong's bytes reach the socket's onData.
  final pongs = <int, (int, int)>{};

  /// The signal isolate's standby pool, as of its last reply (for the
  /// synchronous GravixSignalStandby.state).
  Map<String, List<int?>> standby = const {};
}

/// GRAVIX (2026-10-12): see the file comment. Internal; the app-facing switch
/// is `GravixSignalIsolate` (lib/src/connect/gravix_signal_isolate.dart).
abstract final class GravixSignalIsolateRuntime {
  static bool _enabled = false;
  static Future<_Bridge>? _bridge;

  /// Whether new dials and the standby pool use the signal isolate. A per-isolate
  /// static: false inside the signal isolate itself, whatever the app set.
  static bool get enabled => _enabled;
  static set enabled(bool on) {
    if (on == _enabled) return;
    if (on) {
      // standby connections opened on this isolate cannot be handed to the
      // signal isolate: closed now (before the switch, so this runs here)
      unawaited(GravixSignalStandby.closeAll());
      _enabled = true;
      unawaited(warmUp());
    } else {
      _enabled = false;
      final b = _bridge;
      if (b != null) {
        unawaited(
          b.then((b) {
            if (b.alive) b.cmd.send(<Object?>[_kSbCloseAll, 0]);
          }, onError: (Object _) {}),
        );
      }
    }
  }

  /// GRAVIX (2026-10-13): the app's HttpOverrides do not keep dials off the
  /// signal isolate (`GravixSignalIsolate.ignoreHttpOverrides`). Off by default.
  static bool ignoreHttpOverrides = false;

  /// Runs first in the signal isolate (tests: trust a throwaway certificate). Must
  /// be set before the isolate starts; a closure that can be sent to an isolate.
  @visibleForTesting
  static void Function()? debugIsolateSetup;

  /// Starts the signal isolate if it is not running (resolves when it is ready).
  /// Never throws.
  static Future<void> warmUp() async {
    try {
      await _ensure();
    } catch (e) {
      logger.warning('[signal-isolate] could not start: $e');
    }
  }

  /// Stops the signal isolate (tests). Live sockets are reported closed.
  @visibleForTesting
  static Future<void> debugShutdown() async {
    final f = _bridge;
    _bridge = null;
    if (f == null) return;
    try {
      final b = await f;
      b.isolate.kill(priority: Isolate.immediate);
      _onExit(b);
    } catch (_) {}
  }

  /// A dial with [preconnected] goes on this isolate after all: a standby take
  /// that was to happen in the signal isolate did not happen.
  static void notRouted(Object? preconnected) {
    if (preconnected is GravixPipelinedStandbyTake) preconnected._unused();
  }

  /// Whether a dial with [preconnected] goes through the signal isolate.
  static bool routes(Object? preconnected) {
    if (!_enabled) return false;
    if ((io.HttpOverrides.current != null && !ignoreHttpOverrides) || io.IOOverrides.current != null) return false;
    // a standby connection of THIS isolate is used where it lives
    if (preconnected is io.HttpClient) return false;
    if (preconnected is GravixStandbyTaken && preconnected.client is io.HttpClient) return false;
    return true;
  }

  static Future<_Bridge> _ensure() {
    final existing = _bridge;
    if (existing != null) return existing;
    final f = _spawn();
    _bridge = f;
    f.then(
      (_) {},
      onError: (Object _) {
        if (identical(_bridge, f)) _bridge = null;
      },
    );
    return f;
  }

  static Future<_Bridge> _spawn() async {
    final ready = Completer<SendPort>();
    _Bridge? bridge;
    final rx = RawReceivePort();
    final exitRx = RawReceivePort();
    // an uncaught error in the signal isolate is logged; it keeps running
    // (errorsAreFatal: false) and its sockets with it
    final errorRx = RawReceivePort((Object? e) => logger.warning('[signal-isolate] uncaught: $e'));
    rx.handler = (Object? m) {
      final b = bridge;
      if (b == null) {
        if (m is List && m[0] == _kReady) ready.complete(m[1] as SendPort);
        return;
      }
      _onMessage(b, m as List<Object?>);
    };
    exitRx.handler = (Object? _) {
      final b = bridge;
      if (b != null) {
        _onExit(b);
      } else if (!ready.isCompleted) {
        ready.completeError(const WebSocketException('the signal isolate exited while starting'));
      }
      errorRx.close();
    };
    final Isolate iso;
    try {
      iso = await Isolate.spawn<List<Object?>>(
        _signalIsolateMain,
        <Object?>[rx.sendPort, debugIsolateSetup, logger.level.value],
        onExit: exitRx.sendPort,
        onError: errorRx.sendPort,
        errorsAreFatal: false,
        debugName: 'gravix-signal',
      );
    } catch (e) {
      rx.close();
      exitRx.close();
      errorRx.close();
      rethrow;
    }
    final SendPort cmd;
    try {
      cmd = await ready.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      iso.kill(priority: Isolate.immediate);
      rx.close();
      exitRx.close();
      errorRx.close();
      rethrow;
    }
    return _ready = bridge = _Bridge(cmd, iso, rx, exitRx);
  }

  static void _onExit(_Bridge b) {
    if (!b.alive) return;
    b.alive = false;
    if (identical(_ready, b)) {
      _ready = null;
      // the next use starts a new one
      _bridge = null;
    }
    b.rx.close();
    b.exitRx.close();
    logger.warning('[signal-isolate] the signal isolate went away');
    for (final d in b.dials.values) {
      if (!d.done.isCompleted) d.done.completeError(const WebSocketException('the signal isolate went away'));
    }
    b.dials.clear();
    for (final h in b.handlers.values.toList()) {
      h?.onDispose?.call();
    }
    b.handlers.clear();
    for (final c in b.closing.values) {
      if (!c.isCompleted) c.complete();
    }
    b.closing.clear();
    for (final c in b.replies.values) {
      if (!c.isCompleted) c.complete(null);
    }
    b.replies.clear();
    b.pongs.clear();
    b.standby = const {};
  }

  static void _onMessage(_Bridge b, List<Object?> m) {
    switch (m[0]) {
      case _kData:
        final id = m[1] as int;
        // a pong the signal isolate timed: [.., pingTimestamp, rttMs]
        if (m.length > 4) b.pongs[id] = (m[3] as int, m[4] as int);
        b.handlers[id]?.onData?.call(m[2]);
      case _kDialOk:
        final id = m[1] as int;
        final d = b.dials.remove(id);
        b.standby = (m[4] as Map).cast<String, List<int?>>();
        if (d == null) return;
        d.take?._resolve((m[3] as List).cast<Object?>());
        final ws = _IsolateWebSocket(b, id);
        final dial = m[2] as List?;
        if (dial != null) {
          ws.gravixDial = GravixStandbyDial(
            dial[0] as String,
            boundMs: dial[1] as int?,
            stalledAfterMs: dial[2] as int?,
            totalMs: dial[3] as int?,
          );
        }
        d.done.complete(ws);
      case _kDialErr:
        final id = m[1] as int;
        final d = b.dials.remove(id);
        b.handlers.remove(id);
        b.standby = (m[4] as Map).cast<String, List<int?>>();
        if (d == null) return;
        final t = m[3] as List?;
        if (t != null) d.take?._resolve(t.cast<Object?>());
        d.done.completeError(m[2]!);
      case _kDone:
        // the socket closed (the server, the network, or our close): as
        // websocket/io.dart reports it
        b.pongs.remove(m[1] as int);
        b.handlers.remove(m[1] as int)?.onDispose?.call();
      case _kError:
        b.handlers[m[1] as int]?.onError?.call(m[2]);
      case _kClosed:
        final id = m[1] as int;
        b.closing.remove(id)?.complete();
        // our own close is reported to the handlers too (as websocket/io.dart
        // does), by the _kDone that follows; one that never comes (a close
        // that timed out) does not keep the entry
        if (b.handlers.containsKey(id)) Timer(const Duration(seconds: 2), () => b.handlers.remove(id));
      case _kReply:
        b.standby = (m[3] as Map).cast<String, List<int?>>();
        b.replies.remove(m[1] as int)?.complete(m[2]);
      case _kLog:
        logger.log(
          Level.LEVELS.firstWhere((l) => l.value == m[1], orElse: () => Level.INFO),
          '[signal-isolate] ${m[2]}',
        );
    }
  }

  /// The dial, in the signal isolate. Same parameters and errors as
  /// GravixRtcWebSocketIO.connect.
  static Future<GravixRtcWebSocket> connect(
    Uri uri, {
    WebSocketEventHandlers? options,
    Map<String, String>? headers,
    NetworkOptions? networkOptions = const NetworkOptions(),
    Object? preconnected,
    Duration? connectTimeout,
    Duration? hedgeAfter,
    Duration? connectWithin,
    Duration? upgradeWindow,
    Duration? dialCeiling,
  }) async {
    _Bridge? b;
    try {
      b = await _ensure();
    } catch (e) {
      logger.warning('[signal-isolate] not running ($e): dialling on this isolate');
    }
    if (b == null || !b.alive) {
      notRouted(preconnected);
      return lkWebSocketConnect(
        uri,
        options: options,
        headers: headers,
        networkOptions: networkOptions,
        connectTimeout: connectTimeout,
        hedgeAfter: hedgeAfter,
        connectWithin: connectWithin,
        upgradeWindow: upgradeWindow,
        dialCeiling: dialCeiling,
      );
    }
    final id = b.nextId++;
    final take = preconnected is GravixPipelinedStandbyTake ? preconnected : null;
    final d = _PendingDial(take);
    b.dials[id] = d;
    b.handlers[id] = options;
    b.cmd.send(<Object?>[
      _kDial,
      id,
      uri.toString(),
      headers,
      networkOptions ?? const NetworkOptions(),
      take == null ? null : <Object?>[take.url, take.token, take.wait.inMicroseconds],
      connectTimeout?.inMicroseconds,
      hedgeAfter?.inMicroseconds,
      connectWithin?.inMicroseconds,
      upgradeWindow?.inMicroseconds,
      dialCeiling?.inMicroseconds,
    ]);
    return d.done.future;
  }

  // -------------------------------------------------------------------------
  // the standby pool, in the signal isolate (GravixSignalStandby routes here)

  static Future<Object?> _request(List<Object?> Function(int id) build) async {
    final b = await _ensure();
    if (!b.alive) return null;
    final id = b.nextId++;
    final c = Completer<Object?>();
    b.replies[id] = c;
    b.cmd.send(build(id));
    return c.future;
  }

  static Future<bool> standbyOpen(String url, String token, NetworkOptions? networkOptions, int? rttHintMs) async {
    try {
      final r = await _request((id) => <Object?>[_kSbOpen, id, url, token, networkOptions, rttHintMs]);
      return r == true;
    } catch (_) {
      return false;
    }
  }

  /// No round trip: the take runs in the signal isolate as the first step of the
  /// dial it is handed to.
  static GravixStandbyTaken standbyTake(String url, String token, Duration wait) =>
      GravixPipelinedStandbyTake._(url, token, wait, GravixRemoteStandbyClient._());

  static Future<void> standbyReopenAll() async {
    try {
      await _request((id) => <Object?>[_kSbReopenAll, id]);
    } catch (_) {}
  }

  static Future<void> standbyCloseAll() async {
    try {
      await _request((id) => <Object?>[_kSbCloseAll, id]);
    } catch (_) {}
  }

  /// The signal isolate's standby pool as of its last reply (empty before the
  /// isolate is up).
  static Map<String, List<int?>> get standbySnapshot => _ready?.standby ?? const {};

  /// The bridge once the isolate is up (for the synchronous reads).
  static _Bridge? _ready;
}

// ---------------------------------------------------------------------------
// the signal isolate

Future<void> _signalIsolateMain(List<Object?> args) async {
  final out = args[0] as SendPort;
  final setup = args[1] as void Function()?;
  final levelValue = args[2] as int;
  // the upgrade bound of a standby taken here (standby_types.dart)
  gravixStandbyInSignalIsolate = true;
  try {
    setup?.call();
  } catch (_) {}

  // logs: forwarded to the app isolate's logger at the level it had at start
  hierarchicalLoggingEnabled = true;
  logger.level = Level.LEVELS.firstWhere((l) => l.value == levelValue, orElse: () => Level.INFO);
  logger.onRecord.listen((r) {
    try {
      out.send(<Object?>[_kLog, r.level.value, r.message]);
    } catch (_) {}
  });

  final sockets = <int, GravixRtcWebSocketIO>{};
  final pings = _PingClock();
  final rx = RawReceivePort();
  out.send(<Object?>[_kReady, rx.sendPort]);

  rx.handler = (Object? message) {
    final m = message as List<Object?>;
    switch (m[0]) {
      case _kDial:
        unawaited(_bgDial(out, sockets, pings, m));
      case _kSend:
        sockets[m[1] as int]?.send(m[2] as List<int>);
      case _kSendPing:
        final id = m[1] as int;
        final ws = sockets[id];
        if (ws != null) {
          ws.send(m[2] as List<int>);
          pings.sent(id, m[3] as int);
        }
      case _kClose:
        final id = m[1] as int;
        pings.forget(id);
        final ws = sockets.remove(id);
        if (ws == null) {
          out.send(<Object?>[_kClosed, id]);
        } else {
          unawaited(ws.dispose().whenComplete(() => out.send(<Object?>[_kClosed, id])));
        }
      case _kSbOpen:
        final id = m[1] as int;
        unawaited(
          GravixSignalStandby.open(
            m[2] as String,
            m[3] as String,
            networkOptions: m[4] as NetworkOptions?,
            rttHintMs: m[5] as int?,
          ).then((ok) => out.send(<Object?>[_kReply, id, ok, GravixSignalStandby.snapshot()])),
        );
      case _kSbReopenAll:
        final id = m[1] as int;
        unawaited(
          GravixSignalStandby.reopenAll().whenComplete(
            () => out.send(<Object?>[_kReply, id, null, GravixSignalStandby.snapshot()]),
          ),
        );
      case _kSbCloseAll:
        final id = m[1] as int;
        unawaited(
          GravixSignalStandby.closeAll().whenComplete(
            () => out.send(<Object?>[_kReply, id, null, GravixSignalStandby.snapshot()]),
          ),
        );
    }
  };
}

Duration? _us(Object? v) => v == null ? null : Duration(microseconds: v as int);

Future<void> _bgDial(SendPort out, Map<int, GravixRtcWebSocketIO> sockets, _PingClock pings, List<Object?> m) async {
  final id = m[1] as int;
  final takeArgs = m[5] as List?;
  var taken = GravixStandbyTaken.none;
  if (takeArgs != null) {
    try {
      taken = await GravixSignalStandby.take(
        takeArgs[0] as String,
        takeArgs[1] as String,
        wait: Duration(microseconds: takeArgs[2] as int),
      );
    } catch (_) {}
  }
  List<Object?>? takeInfo() => takeArgs == null
      ? null
      : <Object?>[
          taken.outcome,
          taken.ageMs,
          taken.waitedMs,
          taken.connectsAtTake,
          taken.upgradeBound?.inMicroseconds,
          taken.usable,
          GravixSignalStandby.connectsOf(taken.client),
        ];
  try {
    final ws = await GravixRtcWebSocketIO.connect(
      Uri.parse(m[2] as String),
      options: WebSocketEventHandlers(
        onData: (dynamic data) {
          final pong = pings.pong(id, data);
          out.send(pong == null ? <Object?>[_kData, id, data] : <Object?>[_kData, id, data, pong.$1, pong.$2]);
        },
        onDispose: () {
          pings.forget(id);
          out.send(<Object?>[_kDone, id]);
        },
        onError: (dynamic e) => out.send(<Object?>[_kError, id, '$e']),
      ),
      headers: (m[3] as Map?)?.cast<String, String>(),
      networkOptions: m[4] as NetworkOptions?,
      preconnected: taken.usable ? taken : null,
      connectTimeout: _us(m[6]),
      hedgeAfter: _us(m[7]),
      connectWithin: _us(m[8]),
      upgradeWindow: _us(m[9]),
      dialCeiling: _us(m[10]),
    );
    final info = takeInfo();
    // the join is done with the taken client (as SignalClient does after a dial)
    GravixSignalStandby.release(taken.client);
    sockets[id] = ws;
    final dial = ws.gravixDial;
    out.send(<Object?>[
      _kDialOk,
      id,
      dial == null ? null : <Object?>[dial.path, dial.boundMs, dial.stalledAfterMs, dial.totalMs],
      info,
      GravixSignalStandby.snapshot(),
    ]);
  } catch (e) {
    final info = takeInfo();
    GravixSignalStandby.release(taken.client);
    Object error = e;
    try {
      out.send(<Object?>[_kDialErr, id, error, info, GravixSignalStandby.snapshot()]);
    } catch (_) {
      // not sendable as is: its text, with the type the signal client branches on
      error = e is GravixDialTimeoutException
          ? GravixDialTimeoutException('${e.message}', e.duration, noConnection: e.noConnection)
          : WebSocketException('Failed to connect', '$e');
      out.send(<Object?>[_kDialErr, id, error, info, GravixSignalStandby.snapshot()]);
    }
  }
}

/// GRAVIX (2026-10-13, network RTT): the signal isolate's timing of the pings
/// it writes ([_kSendPing]) and of their pongs, on its own monotonic clock.
///
/// Field 2026-10-13 (an Android app, ~6-10 ms to the SFU): joins tapped right
/// after the app opened read signal round trips of 221-1710 ms (the room's
/// network chip showed "999") against 10-30 ms from a settled app: the ping was
/// stamped when the app's isolate sent it and the pong when the app's isolate
/// decoded it, and the app's startup work in between counted as network. Here
/// both stamps are taken where the socket lives; this isolate is idle but for
/// signalling, so what is left is the path (and the TLS work of the frames).
class _PingClock {
  final _clock = Stopwatch()..start();

  /// Per socket: the ping's timestamp -> when its frame was written (µs).
  final _sent = <int, Map<int, int>>{};

  /// Pings that never get a pong (a dying socket) are not kept forever.
  static const _keep = 8;

  void sent(int socket, int pingTimestamp) {
    final m = _sent.putIfAbsent(socket, () => <int, int>{});
    m[pingTimestamp] = _clock.elapsedMicroseconds;
    if (m.length > _keep) m.remove(m.keys.first);
  }

  void forget(int socket) => _sent.remove(socket);

  /// When [data] is the pong (pongResp) of a ping written by [sent]: (the
  /// ping's timestamp, its round trip in ms, at least 1 -- 0 means "no pong
  /// yet" to the app). Null otherwise.
  ///
  /// A SignalResponse is one oneof, so its first bytes are that field's tag:
  /// pong_resp (field 20, length-delimited) starts with 0xA2 0x01. Only those
  /// frames are decoded; every other message passes through untouched.
  (int, int)? pong(int socket, Object? data) {
    final m = _sent[socket];
    if (m == null || m.isEmpty) return null;
    if (data is! List<int> || data.length < 2 || data[0] != 0xA2 || data[1] != 0x01) return null;
    final now = _clock.elapsedMicroseconds;
    final int ts;
    try {
      final r = lk_rtc.SignalResponse.fromBuffer(data);
      if (!r.hasPongResp()) return null;
      ts = r.pongResp.lastPingTimestamp.toInt();
    } catch (_) {
      return null;
    }
    final at = m.remove(ts);
    if (at == null) return null;
    final ms = ((now - at) / 1000).round();
    return (ts, ms < 1 ? 1 : ms);
  }
}

// Copyright 2024 LiveKit, Inc.
// Modifications Copyright 2024-2026 Gravity Compile
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:io' as io;

// `show`: the whole library would shadow dart:async's TimeoutException, which a
// bounded dial throws (the same type as the signal client's own dial timeout)
import '../../exceptions.dart' show CertificatePinningException;
import '../../extensions.dart';
import '../../logger.dart';
import '../../options.dart';
import '../http_client/io.dart';
import '../websocket.dart';
import 'standby_types.dart' show GravixStandbyDial, GravixStandbyTaken, kGravixStandbyUpgradeTimeout;

Future<GravixRtcWebSocketIO> lkWebSocketConnect(
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
}) => GravixRtcWebSocketIO.connect(
  uri,
  options: options,
  headers: headers,
  networkOptions: networkOptions,
  preconnected: preconnected,
  connectTimeout: connectTimeout,
  hedgeAfter: hedgeAfter,
  connectWithin: connectWithin,
  upgradeWindow: upgradeWindow,
  dialCeiling: dialCeiling,
);

/// GRAVIX (2026-10-11): the HTTP clients of one bounded dial; [fire] (the
/// bound passed) force-closes them, which cancels a TCP / TLS connect still in
/// progress and drops a connection whose upgrade has not been answered.
class _GravixDialAbort {
  _GravixDialAbort(this.bound, this.hedge);
  final Duration bound;

  /// GRAVIX (2026-10-11, silentHostFailFast): a connection of this dial came up
  /// (TCP, and TLS for wss): the host answers. [observed]: the dial's
  /// connections can be seen (its own clients, or a standby connection, which
  /// is up already); not through WebSocket.connect's shared client.
  bool connected = false;
  bool observed = false;

  /// GRAVIX (2026-10-11, signalUpgradeWindow): told once, when the first
  /// connection comes up.
  void Function()? onConnected;

  void markConnected() {
    if (connected) return;
    connected = true;
    onConnected?.call();
  }

  /// GRAVIX (2026-10-11): the dial's connections are raced (null: one
  /// connection, connect-timed-out at [bound])
  final GravixConnectHedge? hedge;
  final _clients = <io.HttpClient>[];
  bool fired = false;

  /// Registers [client] (closed at once when the bound already passed).
  io.HttpClient track(io.HttpClient client) {
    _clients.add(client);
    if (fired) _close(client);
    return client;
  }

  void fire() {
    fired = true;
    _clients.forEach(_close);
  }

  static void _close(io.HttpClient client) {
    try {
      client.close(force: true);
    } catch (_) {}
  }
}

class GravixRtcWebSocketIO extends GravixRtcWebSocket {
  final io.WebSocket _ws;
  final WebSocketEventHandlers? options;
  late final StreamSubscription _subscription;

  GravixRtcWebSocketIO._(this._ws, [this.options]) {
    _subscription = _ws.listen(
      (dynamic data) {
        if (isDisposed) {
          logger.warning('$objectId already disposed, ignoring received data.');
          return;
        }
        options?.onData?.call(data);
      },
      onDone: () async {
        await _subscription.cancel();
        options?.onDispose?.call();
      },
    );

    onDispose(() async {
      if (_ws.readyState != io.WebSocket.closed) {
        // GRAVIX: bounded. close() flushes queued frames (a leave) and then waits
        // for the server's close frame, which a dead connection never sends; the
        // dispose of an app going away must not hang on it.
        await _ws.close().timeout(const Duration(seconds: 1), onTimeout: () {});
      }
    });
  }

  @override
  void send(List<int> data) {
    if (_ws.readyState != io.WebSocket.open) {
      logger.fine('[$objectId] Socket not open (state: ${_ws.readyState})');
      return;
    }

    try {
      _ws.add(data);
    } catch (e) {
      logger.fine('[$objectId] send did throw $e');
    }
  }

  /// [connectTimeout] (GRAVIX, 2026-10-11): see [_bounded]; null = the dial is
  /// unbounded here (the 0.4.14 dial: the caller's timeout abandons it, its
  /// socket keeps connecting until the OS gives up). [hedgeAfter] (below
  /// [connectTimeout]): a connection not up after it gets another one in
  /// parallel, again every [hedgeAfter] (GravixConnectHedge, http_client/io.dart).
  static Future<GravixRtcWebSocketIO> connect(
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
  }) {
    if (connectTimeout == null) return _connect(uri, options, headers, networkOptions, preconnected, null);
    final hedge = hedgeAfter != null && hedgeAfter > Duration.zero && hedgeAfter < connectTimeout
        ? GravixConnectHedge(hedgeAfter)
        : null;
    return _bounded(
      connectTimeout,
      hedge,
      connectWithin != null && connectWithin > Duration.zero && connectWithin < connectTimeout ? connectWithin : null,
      upgradeWindow,
      dialCeiling,
      (abort) => _connect(uri, options, headers, networkOptions, preconnected, abort),
    );
  }

  /// The dial, bounded: past [bound] it fails with a (dart:async)
  /// TimeoutException and every connection it opened or was opening is closed.
  ///
  /// Soak 2026-10-11 02:35-02:39 (runs/s01_fix): the ISP blackholed the route to
  /// the SFUs while Wi-Fi stayed up. The signal client gave each dial up after its
  /// 10 s timeout, but the dial itself went on: `io.WebSocket.connect` uses a
  /// shared HttpClient without a connection timeout, so every SYN kept being
  /// retried until Android gave up (errno 110 at 02:38:11, :21, :34 for dials
  /// started at 02:36:02, :12, :21 -- ~133 s on the Infinix). A dial still
  /// connecting when the path came back could even open late: a server session
  /// nobody reads. Now the dial uses its own client, connect-timed-out at the
  /// socket (TCP + TLS) and force-closed at [bound] (which also covers an upgrade
  /// that is never answered). TimeoutException, not WebSocketException: the
  /// engine escalates a resume on a refused socket at once, and on dial timeouts
  /// only after two (Engine._unrecoveredResumesBeforeFull); a blackholed path
  /// must keep reading as a timeout.
  ///
  /// With a [hedge] (device recheck 2026-10-11, "Very Bad Network": a dial not
  /// through within 10 s failed the join on a path that works), the connections
  /// are raced inside the dial's client and [bound] is the whole dial's cap.
  ///
  /// Failing at a bound, the error is a [GravixDialTimeoutException] whose
  /// `noConnection` says whether any connection came up. [connectWithin]
  /// (silentHostFailFast): no connection up by then -> fail then, without
  /// waiting for [bound] (REGION-FAILOVER r552: a 30 s raced dial to a host
  /// that had answered no connection for 20 s).
  ///
  /// [upgradeWindow] (signalUpgradeWindow; RECHECK r366 / r375: TCP + TLS up at
  /// 14.3 / 24.3 s, the upgrade unanswered at the 30 s cap): when the first
  /// connection comes up, the end moves to that moment + [upgradeWindow], capped
  /// at [dialCeiling] from the start, never earlier than [bound].
  static Future<GravixRtcWebSocketIO> _bounded(
    Duration bound,
    GravixConnectHedge? hedge,
    Duration? connectWithin,
    Duration? upgradeWindow,
    Duration? dialCeiling,
    Future<GravixRtcWebSocketIO> Function(_GravixDialAbort abort) dial,
  ) {
    final abort = _GravixDialAbort(bound, hedge);
    final result = Completer<GravixRtcWebSocketIO>();
    final watch = Stopwatch()..start();
    void expire(Duration at) {
      if (result.isCompleted) return;
      logger.fine('[WebSocketIO] not connected within ${at.inMilliseconds} ms, aborting the dial');
      abort.fire();
      result.completeError(
        GravixDialTimeoutException(
          'signal dial not connected within the bound',
          at,
          noConnection: abort.observed && !abort.connected,
        ),
      );
    }

    var timer = Timer(bound, () => expire(bound));
    if (upgradeWindow != null) {
      abort.onConnected = () {
        if (result.isCompleted) return;
        final up = watch.elapsed;
        var end = up + upgradeWindow;
        if (dialCeiling != null && end > dialCeiling) end = dialCeiling;
        if (end <= bound) return;
        timer.cancel();
        logger.fine(
          '[WebSocketIO] connection up after ${up.inMilliseconds} ms: the upgrade may take until '
          '${end.inMilliseconds} ms',
        );
        timer = Timer(end - watch.elapsed, () => expire(end));
      };
    }
    final connectTimer = connectWithin == null
        ? null
        : Timer(connectWithin, () {
            if (result.isCompleted || !abort.observed || abort.connected) return;
            logger.fine(
              '[WebSocketIO] no connection within ${connectWithin.inMilliseconds} ms '
              '(the last dial to this host had none either), aborting the dial',
            );
            abort.fire();
            result.completeError(
              GravixDialTimeoutException('signal dial: no connection came up', connectWithin, noConnection: true),
            );
          });
    dial(abort).then(
      (ws) {
        timer.cancel();
        connectTimer?.cancel();
        if (result.isCompleted) {
          // opened as the bound passed: nobody will read it
          unawaited(ws.dispose());
          return;
        }
        result.complete(ws);
      },
      onError: (Object e, StackTrace st) {
        timer.cancel();
        connectTimer?.cancel();
        if (!result.isCompleted) result.completeError(e, st);
      },
    );
    return result.future;
  }

  static Future<GravixRtcWebSocketIO> _connect(
    Uri uri,
    WebSocketEventHandlers? options,
    Map<String, String>? headers,
    NetworkOptions? networkOptions,
    Object? preconnected,
    _GravixDialAbort? abort,
  ) async {
    logger.fine('[WebSocketIO] Connecting(uri: ${uri.toString()})...');
    final resolvedNetworkOptions = networkOptions ?? const NetworkOptions();
    // The standby client: its keep-alive pool holds a TLS connection to this host,
    // and the upgrade request goes over it (standby_io.dart). The caller owns and
    // releases the client. Passed as the GravixStandbyTaken (with its bound), or as
    // the bare HttpClient (then the default bound).
    io.HttpClient? warmClient;
    var bound = kGravixStandbyUpgradeTimeout;
    if (preconnected is GravixStandbyTaken) {
      final c = preconnected.client;
      if (c is io.HttpClient) warmClient = c;
      bound = preconnected.upgradeBound ?? bound;
    } else if (preconnected is io.HttpClient) {
      warmClient = preconnected;
    }
    if (warmClient != null) {
      // (bounded: the bound closes the warm connection too, its upgrade unanswered)
      abort?.track(warmClient);
      // (a standby connection is up already: never a silent host)
      abort
        ?..observed = true
        ..markConnected();
      final raced = await _raceStandby(uri, warmClient, bound, headers, resolvedNetworkOptions, options, abort);
      if (raced != null) return raced;
      // the warm connection failed outright (not an answer from the server): cold,
      // as if there had been no standby
    }
    // GRAVIX (2026-10-11): a bounded dial gets its own client instead of
    // WebSocket.connect's shared one, so the bound can close it; its socket
    // connect is timed out as well, and the app's WebSocket.userAgent still
    // applies. Not when the app installed HttpOverrides: the shared client was
    // made by whatever overrides were current at the process's first WebSocket
    // (under flutter_test: the test runner's own socket, before the binding's
    // mock), and the dial keeps it, as before -- still bounded by the signal
    // client's timeout, only its socket is left to the OS.
    final ownClient = abort != null && io.HttpOverrides.current == null;
    final useCustomClient = ownClient || (resolvedNetworkOptions.certificatePinning?.isEnabled ?? false);
    final customClient = useCustomClient
        ? createSdkIoHttpClient(
            resolvedNetworkOptions,
            hedge: abort?.hedge,
            // (silentHostFailFast: did any connection of this dial come up?)
            beforeUse: abort?.markConnected,
          )
        : null;
    if (customClient != null && abort != null) {
      abort.observed = true;
      // (raced: a single connection is not timed out on its own, the race and
      // the cap end it)
      if (abort.hedge == null) customClient.connectionTimeout = abort.bound;
      if (ownClient) customClient.userAgent = io.WebSocket.userAgent;
      abort.track(customClient);
    }
    try {
      final ws = await io.WebSocket.connect(uri.toString(), headers: headers, customClient: customClient);
      logger.fine('[WebSocketIO] Connected');
      return GravixRtcWebSocketIO._(ws, options)
        ..gravixDial = warmClient == null ? null : GravixStandbyDial('cold_after_error', boundMs: bound.inMilliseconds);
    } on CertificatePinningException {
      rethrow;
    } catch (err) {
      logger.severe('[WebSocketIO] did throw $err');
      throw WebSocketException('Failed to connect', err);
    } finally {
      customClient?.close();
    }
  }

  /// The upgrade over a standby connection, bounded, raced by a fresh dial.
  ///
  /// Field 2026-09-30 (Bangladesh vivo -> sgp1, 170 ms probe RTT): the upgrade went
  /// out over the standby connection, the SFU started the session at the tap, and
  /// no answer came back (a connection opened while the app sat behind the
  /// permission dialog). 0.4.3 waited its 2.5 s timeout, then dialled cold; the join
  /// took 7.7 s and the SFU dropped the first session 6.5 s after the tap as
  /// DUPLICATE_IDENTITY. `.timeout()` also never cancelled the stalled upgrade: had
  /// it answered late, its WebSocket (a second server session) would have been
  /// left open with nobody reading it.
  ///
  /// Now: the upgrade over the warm connection gets [bound] (3 x RTT, 0.5-1.5 s,
  /// standby_types.dart). Past it a fresh dial starts, and the two race -- but not
  /// to the server: the fresh connection's TCP + TLS run while the warm upgrade may
  /// still answer, and the moment the fresh socket is connected (before its upgrade
  /// is written) the race is decided:
  ///  - the warm upgrade already answered -> the fresh socket is destroyed; its join
  ///    never reached the server, so there is no second session;
  ///  - it did not -> the warm connection is force-closed FIRST (the SFU sees its
  ///    signal connection drop, and nothing more of it can arrive after the fresh
  ///    join), then the fresh upgrade is written.
  /// So the server never gets the fresh join and then a late warm one (which would
  /// replace the session the client keeps, as DUPLICATE_IDENTITY). A warm upgrade
  /// that still completes after it was abandoned (its 101 already on the way) is
  /// closed at once. Returns null when the warm connection failed outright (the
  /// caller dials cold); rethrows the server's own answer (401/403/404...).
  static Future<GravixRtcWebSocketIO?> _raceStandby(
    Uri uri,
    io.HttpClient warmClient,
    Duration bound,
    Map<String, String>? headers,
    NetworkOptions networkOptions,
    WebSocketEventHandlers? options,
    _GravixDialAbort? abort,
  ) async {
    final watch = Stopwatch()..start();
    var abandoned = false;
    io.WebSocket? warmWs;
    Object? warmError;
    final warmSettled = Completer<void>();
    unawaited(
      io.WebSocket.connect(uri.toString(), headers: headers, customClient: warmClient).then(
        (ws) {
          if (abandoned) {
            // answered after the fresh dial took over: a second server session,
            // closed before anything uses it
            logger.fine('[WebSocketIO] standby upgrade answered after it was abandoned, closing it');
            unawaited(ws.close(io.WebSocketStatus.normalClosure).catchError((Object _) {}));
            return;
          }
          warmWs = ws;
          if (!warmSettled.isCompleted) warmSettled.complete();
        },
        onError: (Object e) {
          warmError = e;
          if (!warmSettled.isCompleted) warmSettled.complete();
        },
      ),
    );

    GravixRtcWebSocketIO? warmResult(String path) {
      final ws = warmWs;
      if (ws == null) return null;
      logger.fine('[WebSocketIO] Connected (standby connection, $path)');
      return GravixRtcWebSocketIO._(ws, options)
        ..gravixDial = GravixStandbyDial(
          path,
          boundMs: bound.inMilliseconds,
          stalledAfterMs: path == 'standby' ? null : bound.inMilliseconds,
          totalMs: watch.elapsedMilliseconds,
        );
    }

    Never rethrowWarm(Object e) {
      if (e is CertificatePinningException) throw e;
      // the server answered the upgrade (a 401/403/404...): a cold retry gets the
      // same answer, and the caller validates it
      logger.severe('[WebSocketIO] did throw $e');
      throw WebSocketException('Failed to connect', e);
    }

    // 1) the warm upgrade alone, for up to [bound]
    await Future.any([warmSettled.future, Future<void>.delayed(bound)]);
    if (warmSettled.isCompleted) {
      final done = warmResult('standby');
      if (done != null) return done;
      final e = warmError;
      if (e is CertificatePinningException || e is io.WebSocketException) rethrowWarm(e!);
      logger.warning('[WebSocketIO] standby connection failed ($e), connecting cold');
      return null;
    }

    // 2) stalled: a fresh dial races it (decided when the fresh socket connects)
    logger.warning('[WebSocketIO] standby upgrade stalled after ${bound.inMilliseconds} ms, racing a fresh dial');
    final freshClient = createSdkIoHttpClient(
      networkOptions,
      beforeUse: () {
        abort?.markConnected();
        if (warmWs != null) throw StateError('standby upgrade answered first');
        abandoned = true;
        // closes the warm connection's socket: its pending upgrade fails at once
        try {
          warmClient.close(force: true);
        } catch (_) {}
      },
      hedge: abort?.hedge,
    );
    if (abort != null) {
      // GRAVIX (2026-10-11): the fresh dial ends at the dial's bound as well
      if (abort.hedge == null) freshClient.connectionTimeout = abort.bound;
      abort.track(freshClient);
    }
    final fresh = io.WebSocket.connect(uri.toString(), headers: headers, customClient: freshClient);
    final freshSettled = Completer<void>();
    io.WebSocket? freshWs;
    Object? freshError;
    unawaited(
      fresh.then(
        (ws) {
          freshWs = ws;
          if (!freshSettled.isCompleted) freshSettled.complete();
        },
        onError: (Object e) {
          freshError = e;
          if (!freshSettled.isCompleted) freshSettled.complete();
        },
      ),
    );
    try {
      while (true) {
        final pending = [
          if (!warmSettled.isCompleted) warmSettled.future,
          if (!freshSettled.isCompleted) freshSettled.future,
        ];
        // (Future.any of nothing never completes)
        if (pending.isNotEmpty) await Future.any(pending);
        if (!abandoned && warmWs != null) {
          // the warm upgrade won before the fresh socket was up: drop the fresh one
          // (its gate throws if its socket connects later; force-close aborts it now)
          try {
            freshClient.close(force: true);
          } catch (_) {}
          return warmResult('standby_late');
        }
        final ws = freshWs;
        if (ws != null) {
          logger.fine('[WebSocketIO] Connected (fresh dial after a stalled standby upgrade)');
          return GravixRtcWebSocketIO._(ws, options)
            ..gravixDial = GravixStandbyDial(
              'redial',
              boundMs: bound.inMilliseconds,
              stalledAfterMs: bound.inMilliseconds,
              totalMs: watch.elapsedMilliseconds,
            );
        }
        if (freshSettled.isCompleted && freshError != null) {
          final e = freshError!;
          if (e is CertificatePinningException || e is io.WebSocketException) rethrowWarm(e);
          if (abandoned || warmSettled.isCompleted) {
            // both gone
            if (warmError is io.WebSocketException) rethrowWarm(warmError!);
            logger.severe('[WebSocketIO] did throw $e');
            throw WebSocketException('Failed to connect', e);
          }
          // the fresh dial failed before its socket was up (DNS, no route): the
          // warm upgrade is all there is, the caller's connect timeout bounds it
          await warmSettled.future;
          final done = warmResult('standby_late');
          if (done != null) return done;
          rethrowWarm(warmError ?? e);
        }
        if (warmSettled.isCompleted && warmWs == null && !freshSettled.isCompleted) {
          // the warm connection failed outright (or was abandoned): the fresh dial
          // carries the join
          await freshSettled.future;
        }
      }
    } finally {
      // the fresh WebSocket (if any) is detached from its client; nothing else
      // pooled in it is needed
      try {
        freshClient.close();
      } catch (_) {}
    }
  }
}

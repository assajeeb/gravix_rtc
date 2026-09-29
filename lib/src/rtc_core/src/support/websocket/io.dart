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

import '../../exceptions.dart';
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
}) => GravixRtcWebSocketIO.connect(
  uri,
  options: options,
  headers: headers,
  networkOptions: networkOptions,
  preconnected: preconnected,
);

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

  static Future<GravixRtcWebSocketIO> connect(
    Uri uri, {
    WebSocketEventHandlers? options,
    Map<String, String>? headers,
    NetworkOptions? networkOptions = const NetworkOptions(),
    Object? preconnected,
  }) async {
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
      final raced = await _raceStandby(uri, warmClient, bound, headers, resolvedNetworkOptions, options);
      if (raced != null) return raced;
      // the warm connection failed outright (not an answer from the server): cold,
      // as if there had been no standby
    }
    final useCustomClient = resolvedNetworkOptions.certificatePinning?.isEnabled ?? false;
    final customClient = useCustomClient ? createSdkIoHttpClient(resolvedNetworkOptions) : null;
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
        if (warmWs != null) throw StateError('standby upgrade answered first');
        abandoned = true;
        // closes the warm connection's socket: its pending upgrade fails at once
        try {
          warmClient.close(force: true);
        } catch (_) {}
      },
    );
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

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
import 'standby_types.dart' show kGravixStandbyUpgradeTimeout;

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
        await _ws.close();
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
    if (preconnected is io.HttpClient) {
      // The standby client: its keep-alive pool holds a TLS connection to this
      // host, and the upgrade request goes over it (standby_io.dart). The caller
      // owns and releases the client. A pooled connection that died silently (a
      // carrier NAT) fails the upgrade: retried once below, cold, as if there had
      // been no standby.
      try {
        // A pooled connection a carrier NAT dropped silently does not fail: the
        // upgrade request goes into a black hole and dart:io waits. A warm upgrade
        // is one round trip (72-83 ms on the 2026-09-29 emulator proof), so a short
        // bound hands the join to the cold path with most of its timeout left.
        final ws = await io.WebSocket.connect(
          uri.toString(),
          headers: headers,
          customClient: preconnected,
        ).timeout(kGravixStandbyUpgradeTimeout);
        logger.fine('[WebSocketIO] Connected (standby connection)');
        return GravixRtcWebSocketIO._(ws, options);
      } on CertificatePinningException {
        rethrow;
      } on io.WebSocketException catch (err) {
        // the server answered the upgrade (a 401/403/404...): a cold retry gets
        // the same answer, and the caller validates it
        logger.severe('[WebSocketIO] did throw $err');
        throw WebSocketException('Failed to connect', err);
      } catch (err) {
        logger.warning('[WebSocketIO] standby connection failed ($err), connecting cold');
      }
    }
    final useCustomClient = resolvedNetworkOptions.certificatePinning?.isEnabled ?? false;
    final customClient = useCustomClient ? createSdkIoHttpClient(resolvedNetworkOptions) : null;
    try {
      final ws = await io.WebSocket.connect(uri.toString(), headers: headers, customClient: customClient);
      logger.fine('[WebSocketIO] Connected');
      return GravixRtcWebSocketIO._(ws, options);
    } on CertificatePinningException {
      rethrow;
    } catch (err) {
      logger.severe('[WebSocketIO] did throw $err');
      throw WebSocketException('Failed to connect', err);
    } finally {
      customClient?.close();
    }
  }
}

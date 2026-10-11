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

import 'dart:async' show TimeoutException;

import '../options.dart';
import '../support/disposable.dart';
import 'websocket/standby_types.dart' show GravixStandbyDial;
import 'websocket/io.dart' if (dart.library.js_interop) 'websocket/web.dart';

class WebSocketException implements Exception {
  final String message;
  final dynamic error;
  const WebSocketException(this.message, [this.error]);
}

typedef WebSocketOnData = Function(dynamic data);
typedef WebSocketOnError = Function(dynamic error);
typedef WebSocketOnDispose = Function();

class WebSocketEventHandlers {
  final WebSocketOnData? onData;
  final WebSocketOnError? onError;
  final WebSocketOnDispose? onDispose;

  const WebSocketEventHandlers({this.onData, this.onError, this.onDispose});
}

typedef WebSocketConnector =
    Future<GravixRtcWebSocket> Function(
      Uri uri, {
      WebSocketEventHandlers? options,
      Map<String, String>? headers,
      NetworkOptions? networkOptions,
      Object? preconnected,
    });

/// GRAVIX (2026-10-11): a [WebSocketConnector] that also takes the dial's
/// bound. The SDK's own connector ([GravixRtcWebSocket.connect]) is one; the
/// signal client hands [connectTimeout] only to a connector of this type, so a
/// connector written against [WebSocketConnector] (an app's, a test fake) keeps
/// working unchanged.
typedef GravixBoundedWebSocketConnector =
    Future<GravixRtcWebSocket> Function(
      Uri uri, {
      WebSocketEventHandlers? options,
      Map<String, String>? headers,
      NetworkOptions? networkOptions,
      Object? preconnected,
      Duration? connectTimeout,
      Duration? hedgeAfter,
      Duration? connectWithin,
      Duration? upgradeWindow,
      Duration? dialCeiling,
    });

/// GRAVIX (2026-10-11): a bounded signal dial that did not get through in time.
/// [noConnection]: no TCP (+ TLS) connection to the host came up at all -- a
/// silent host or path -- as opposed to a connection that was up and waiting
/// for the upgrade's answer (a slow one). False when it could not be seen.
class GravixDialTimeoutException extends TimeoutException {
  GravixDialTimeoutException(super.message, super.duration, {this.noConnection = false});
  final bool noConnection;
}

abstract class GravixRtcWebSocket extends Disposable {
  void send(List<int> data);

  /// GRAVIX: how this socket was dialled when a standby connection was handed in
  /// (the join timeline's `standby.path`); null otherwise.
  GravixStandbyDial? gravixDial;

  static Future<GravixRtcWebSocket> connect(
    Uri uri, {
    WebSocketEventHandlers? options,
    Map<String, String>? headers,
    NetworkOptions? networkOptions = const NetworkOptions(),
    // a standby client (standby_io.dart) whose pooled TLS connection the upgrade
    // reuses; ignored on web
    Object? preconnected,
    // GRAVIX (2026-10-11): the dial (TCP, TLS, upgrade) gives up after this with a
    // TimeoutException and its connection is closed (websocket/io.dart). Null:
    // unbounded, a connect into a blackholed path waits for the OS.
    Duration? connectTimeout,
    // GRAVIX (2026-10-11, with connectTimeout): a connection not up after this
    // gets another one in parallel, again every hedgeAfter (GravixConnectHedge);
    // null: one connection
    Duration? hedgeAfter,
    // GRAVIX (2026-10-11, silentHostFailFast, with connectTimeout): no
    // connection up (TCP + TLS) within this -> the dial fails at once
    // (GravixDialTimeoutException, noConnection); one that is up gets the rest
    // of connectTimeout for the upgrade's answer
    Duration? connectWithin,
    // GRAVIX (2026-10-11, signalUpgradeWindow, with connectTimeout): once a
    // connection is up, the dial may run until upgradeWindow after that, but not
    // past dialCeiling from its start, and never less than connectTimeout
    Duration? upgradeWindow,
    Duration? dialCeiling,
  }) => lkWebSocketConnect(
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
}

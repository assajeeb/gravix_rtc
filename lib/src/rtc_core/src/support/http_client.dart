// Copyright 2026 LiveKit, Inc.
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

import 'package:http/http.dart' as http;

import '../options.dart';
import 'http_client/io.dart' if (dart.library.js_interop) 'http_client/web.dart' as impl;

/// [connectionTimeout] (dart:io): how long the client's TCP + TLS connect may
/// take before it is aborted; null = until the OS gives up.
http.Client createSdkHttpClient(NetworkOptions networkOptions, {Duration? connectionTimeout}) =>
    impl.createSdkHttpClient(networkOptions, connectionTimeout: connectionTimeout);

/// A client to keep for several requests (keep-alive), see the io implementation.
http.Client createSdkProbeHttpClient(
  NetworkOptions networkOptions, {
  void Function()? onConnect,
  Duration? idleTimeout,
}) => impl.createSdkProbeHttpClient(networkOptions, onConnect: onConnect, idleTimeout: idleTimeout);

/// [timeout] (GRAVIX, 2026-10-11): the request gives up after it (a
/// TimeoutException) and its socket is closed -- the connect too, which is also
/// bounded at the socket ([createSdkHttpClient]'s connectionTimeout). Null = no
/// limit: a connect into a blackholed path waits for the OS (errno 110 after
/// ~31-133 s on the soak phones), and a caller's own `.timeout()` leaves that
/// socket connecting in the background.
Future<http.Response> sdkHttpGet(
  Uri uri, {
  Map<String, String>? headers,
  NetworkOptions networkOptions = const NetworkOptions(),
  Duration? timeout,
}) => _bounded(networkOptions, timeout, (client) => client.get(uri, headers: headers));

/// See [sdkHttpGet] for [timeout].
Future<http.Response> sdkHttpHead(
  Uri uri, {
  Map<String, String>? headers,
  NetworkOptions networkOptions = const NetworkOptions(),
  Duration? timeout,
}) => _bounded(networkOptions, timeout, (client) => client.head(uri, headers: headers));

Future<http.Response> _bounded(
  NetworkOptions networkOptions,
  Duration? timeout,
  Future<http.Response> Function(http.Client client) request,
) async {
  final client = createSdkHttpClient(networkOptions, connectionTimeout: timeout);
  try {
    final response = request(client);
    return await (timeout == null ? response : response.timeout(timeout));
  } finally {
    // on a timeout as well: closing the client aborts the pending connect or
    // request (IOClient.close is a forced close)
    client.close();
  }
}

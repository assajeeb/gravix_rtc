// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Emulator 2026-10-11 07:03-07:13 (REGION-FAILOVER, SIMULATED, API 34; r511 /
// r512 / r522): with 9893f75 every join failed within ~30 ms, "SocketException:
// Network is unreachable (errno = 101)", on blr1 and on every failover region;
// signalDialCap: null joined. io.WebSocket.connect rewrites ws(s):// to
// http(s):// with `port: uri.port`, which is 0 for a ws/wss url without a port,
// so the connection factory got an explicit port 0. io.HttpClient reads 0 as
// the scheme's default; the SDK's factory (_portFor, http_client/io.dart) used
// it as the port. The tests' path override redirected every connect to the
// local server whatever port it named, which hid it. Here dart:io's own
// Socket.startConnect runs; the override only records what it was asked for.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';

/// Records `host:port` of every plain TCP connect, then makes it unchanged.
final class _Observe extends IOOverrides {
  final asked = <String>[];
  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) {
    asked.add('${host is InternetAddress ? host.address : host}:$port');
    return super.socketStartConnect(host, port, sourceAddress: sourceAddress, sourcePort: sourcePort);
  }
}

void main() {
  late _Observe observe;
  setUp(() => IOOverrides.global = observe = _Observe());
  tearDown(() => IOOverrides.global = null);

  Future<Object?> dial(String url, {Duration? hedgeAfter, NetworkOptions? networkOptions}) async {
    try {
      final ws = await GravixRtcWebSocket.connect(
        Uri.parse(url),
        connectTimeout: const Duration(seconds: 3),
        hedgeAfter: hedgeAfter,
        networkOptions: networkOptions,
      );
      await ws.dispose();
      return null;
    } catch (e) {
      return e;
    }
  }

  test('a raced dial to a ws url without a port connects to port 80, as the single dial does', () async {
    // nothing listens on 127.0.0.1:80 here: refused either way; the question is
    // which port dart:io was asked to connect to
    await dial('ws://127.0.0.1/rtc?x=1');
    final single = List.of(observe.asked);
    observe.asked.clear();
    await dial('ws://127.0.0.1/rtc?x=1', hedgeAfter: const Duration(seconds: 1));
    expect(single, ['127.0.0.1:80']);
    // 9893f75: ['127.0.0.1:0']
    expect(observe.asked, ['127.0.0.1:80']);
  });

  test('an explicit port is kept', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((_) {});
        await ws.close();
      }
    });
    expect(await dial('ws://127.0.0.1:${server.port}/rtc?x=1', hedgeAfter: const Duration(seconds: 1)), isNull);
    expect(observe.asked, ['127.0.0.1:${server.port}']);
  });

  test('a pinned dial to a url without a port connects to the default port too (latent before the race)', () async {
    // certificate pinning has always put the dial through the same connection
    // factory: an app with pinning and a ws/wss url without a port dialled port 0
    const pinned = NetworkOptions(
      certificatePinning: CertificatePinningOptions(
        rules: [
          CertificatePinningRule(hosts: ['127.0.0.1'], primaryPins: ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=']),
        ],
      ),
    );
    await dial('ws://127.0.0.1/rtc?x=1', networkOptions: pinned);
    // 9893f75 / 33a1032: ['127.0.0.1:0']
    expect(observe.asked, ['127.0.0.1:80']);
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// A network path for the dial-timeout tests (soak 2026-10-11 02:35-02:39: the
// ISP blackholed the route to the SFUs while Wi-Fi stayed up). Installed as
// IOOverrides.global, it sees every plain TCP connect dart:io makes
// (Socket.startConnect: HttpClient and WebSocket.connect for http:// and ws://):
//  - up: the connect goes to the local server, whatever host it names;
//  - blackholed: the connect never completes (a SYN nobody answers) and records
//    when, if ever, the SDK aborted it (ConnectionTask.cancel). One left pending
//    is a socket the OS would only have given up on ~2 min later (errno 110).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

import 'fake_rtc.dart' show fakeJoinResponse;

class BlackholedConnect {
  BlackholedConnect(this.n, this.target, this.kind);
  final int n;
  final String target;

  /// What opened it, from the stack at the connect: `dial` (signal WebSocket),
  /// `validate` (/rtc/validate), `regions` (/settings/regions), `probe` (a
  /// reachability HEAD), `other`.
  final String kind;
  final _started = Stopwatch()..start();
  final socket = Completer<Socket>();
  Duration? cancelledAfter;
  bool get cancelled => cancelledAfter != null;

  void cancel() {
    cancelledAfter ??= _started.elapsed;
    if (!socket.isCompleted) socket.completeError(const SocketException('Connection attempt cancelled'));
  }

  @override
  String toString() => '#$n $kind${cancelled ? ' (aborted after ${cancelledAfter!.inMilliseconds} ms)' : ' (pending)'}';
}

String _kindOf(String stack) {
  if (stack.contains('fetchRegionSettings')) return 'regions';
  if (stack.contains('sdkHttpHead')) return 'probe';
  if (stack.contains('sdkHttpGet')) return 'validate';
  if (stack.contains('WebSocket')) return 'dial';
  // a parallel connection of a hedged signal dial, started from its timer
  if (stack.contains('_HedgedConnect')) return 'dial';
  return 'other';
}

/// A connect over a slow but working path ([BlackholePath.slow]): it reaches
/// the local server after [delay] (TCP + TLS taking that long).
class SlowConnect {
  SlowConnect(this.n, this.kind, this.delay);
  final int n;
  final String kind;
  final Duration delay;
  final _started = Stopwatch()..start();
  Duration? connectedAfter;
  Duration? cancelledAfter;
  bool get connected => connectedAfter != null;
  bool get cancelled => cancelledAfter != null;

  @override
  String toString() =>
      '#$n $kind slow ${delay.inMilliseconds} ms'
      '${connected ? ' (connected after ${connectedAfter!.inMilliseconds} ms)' : ''}'
      '${cancelled ? ' (aborted after ${cancelledAfter!.inMilliseconds} ms)' : ''}';
}

final class BlackholePath extends IOOverrides {
  BlackholePath(this.serverPort);

  /// Where an "up" connect goes.
  int serverPort;
  bool up = true;
  final blackholed = <BlackholedConnect>[];
  int upConnects = 0;

  /// Up but slow: a connect started while this is set reaches the server only
  /// after it (read at the connect's start; null = at once).
  Duration? slow;
  final slowConnects = <SlowConnect>[];

  /// Hosts that never answer (a dead / DROPped server) while the rest of the
  /// path is up: their connects hang like [up] = false.
  final silentHosts = <String>{};

  /// Every connect is refused at once (an answer, not a silent path).
  bool refuse = false;
  int refused = 0;

  /// `host:port` of every connect, as dart:io was asked for it (the override
  /// redirects them all to the local server, so a wrong port would otherwise go
  /// unnoticed: emulator 2026-10-11, the hedged dial asked for port 0).
  final requested = <String>[];

  List<String> get kinds => [for (final c in blackholed) c.kind];

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) {
    requested.add('${host is InternetAddress ? host.address : host}:$port');
    if (refuse) {
      refused++;
      return Future.error(const SocketException('Connection refused'));
    }
    final delay = slow;
    if (up && delay != null && !silentHosts.contains(host is InternetAddress ? host.address : '$host')) {
      upConnects++;
      final c = SlowConnect(slowConnects.length + 1, _kindOf(StackTrace.current.toString()), delay);
      slowConnects.add(c);
      final done = Completer<Socket>();
      ConnectionTask<Socket>? real;
      final timer = Timer(delay, () {
        if (c.cancelled) return;
        super.socketStartConnect(InternetAddress.loopbackIPv4, serverPort).then((task) {
          real = task;
          if (c.cancelled) task.cancel();
          task.socket.then(
            (socket) {
              if (c.cancelled || done.isCompleted) {
                socket.destroy();
                return;
              }
              c.connectedAfter = c._started.elapsed;
              done.complete(socket);
            },
            onError: (Object e, StackTrace st) {
              if (!done.isCompleted) done.completeError(e, st);
            },
          );
        });
      });
      return Future.value(
        ConnectionTask.fromSocket<Socket>(done.future, () {
          if (c.connected) return;
          c.cancelledAfter ??= c._started.elapsed;
          timer.cancel();
          real?.cancel();
          if (!done.isCompleted) done.completeError(const SocketException('Connection attempt cancelled'));
        }),
      );
    }
    final silent = silentHosts.contains(host is InternetAddress ? host.address : '$host');
    if (up && !silent) {
      upConnects++;
      return super.socketStartConnect(InternetAddress.loopbackIPv4, serverPort);
    }
    final c = BlackholedConnect(blackholed.length + 1, '$host:$port', _kindOf(StackTrace.current.toString()));
    blackholed.add(c);
    return Future.value(ConnectionTask.fromSocket<Socket>(c.socket.future, c.cancel));
  }
}

/// A signal server on 127.0.0.1: a fresh join is answered with a JoinResponse
/// (subscriber primary), a resume with a ReconnectResponse; /rtc/validate 200,
/// /settings/regions lists [regions] (default: blr1 only), anything else 200.
class LocalSignalServer {
  late HttpServer _http;
  final _open = <WebSocket>{};
  int joins = 0;
  int resumes = 0;
  int validates = 0;

  /// Upgrade requests received (answered or not yet).
  int upgrades = 0;

  /// How long the server takes to answer an upgrade (a slow path's answer).
  Duration upgradeDelay = Duration.zero;
  List<Map<String, String>> regions = [
    {'region': 'blr1', 'url': 'ws://blr1.gravixcloud.run', 'distance': '0'},
  ];

  int get port => _http.port;
  int get openSockets => _open.length;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((req) async {
      final path = req.uri.path;
      if (path == '/rtc' && WebSocketTransformer.isUpgradeRequest(req)) {
        upgrades++;
        if (upgradeDelay > Duration.zero) await Future<void>.delayed(upgradeDelay);
        final WebSocket ws;
        try {
          ws = await WebSocketTransformer.upgrade(req);
        } catch (_) {
          return; // the client gave up (closed the connection) before the answer
        }
        _open.add(ws);
        ws.listen((_) {}, onDone: () => _open.remove(ws), onError: (Object _) => _open.remove(ws));
        if (req.uri.queryParameters['reconnect'] == '1') {
          resumes++;
          ws.add(lk_rtc.SignalResponse(reconnect: lk_rtc.ReconnectResponse()).writeToBuffer());
        } else {
          joins++;
          ws.add(lk_rtc.SignalResponse(join: fakeJoinResponse(subscriberPrimary: true)).writeToBuffer());
        }
        return;
      }
      if (path == '/rtc/validate') validates++;
      if (path == '/settings/regions') req.response.write(json.encode({'regions': regions}));
      await req.response.close();
    });
  }

  Future<void> stop() async {
    for (final ws in _open.toList()) {
      await ws.close().timeout(const Duration(milliseconds: 200), onTimeout: () {});
    }
    await _http.close(force: true);
  }
}

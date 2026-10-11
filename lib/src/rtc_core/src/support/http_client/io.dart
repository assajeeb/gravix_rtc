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

import 'dart:async';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;

import '../../logger.dart';
import '../../options.dart';
import '../certificate_pinning.dart';

http.Client createSdkHttpClient(NetworkOptions networkOptions, {Duration? connectionTimeout}) =>
    http_io.IOClient(createSdkIoHttpClient(networkOptions)..connectionTimeout = connectionTimeout);

/// A client meant to be KEPT for several requests to the same host (the region
/// measurement): its keep-alive pool serves requests 2..N on the socket the first
/// one opened. [onConnect] counts the sockets it opens; [idleTimeout] how long an
/// idle socket stays pooled.
http.Client createSdkProbeHttpClient(
  NetworkOptions networkOptions, {
  void Function()? onConnect,
  Duration? idleTimeout,
}) {
  final client = createSdkIoHttpClient(networkOptions, onConnect: onConnect);
  if (idleTimeout != null) client.idleTimeout = idleTimeout;
  return http_io.IOClient(client);
}

/// [onConnect]: called for every NEW socket the client opens (not for a request
/// served from its keep-alive pool). The standby pre-connect (standby_io.dart)
/// uses it to tell whether the join's upgrade really reused its warm connection.
///
/// [beforeUse]: called once a new socket is connected (TCP, and TLS for https)
/// and BEFORE the client writes anything on it; throwing destroys the socket and
/// fails the request. The standby race (websocket/io.dart) decides there whether
/// the fresh dial still goes ahead: nothing of the fresh join has reached the
/// server at that point, so dropping it leaves no session behind.
///
/// [hedge] (GRAVIX, 2026-10-11): each connection the client needs is raced, see
/// [GravixConnectHedge]. [onConnect] then counts every socket of the race.
io.HttpClient createSdkIoHttpClient(
  NetworkOptions networkOptions, {
  void Function()? onConnect,
  void Function()? beforeUse,
  GravixConnectHedge? hedge,
}) {
  final validator = CertificatePinValidator(networkOptions.certificatePinning);
  final client = io.HttpClient();
  if (!validator.isEnabled && onConnect == null && beforeUse == null && hedge == null) {
    return client;
  }

  final _Connect plain = validator.isEnabled ? _CertificatePinningConnectionFactory(validator).connect : _plainConnect;
  final _Connect connect = hedge == null
      ? plain
      : (url, proxyHost, proxyPort) => _HedgedConnect(plain, hedge, url, proxyHost, proxyPort, onConnect).task;
  client.connectionFactory = (url, proxyHost, proxyPort) async {
    if (hedge == null) onConnect?.call();
    final task = await connect(url, proxyHost, proxyPort);
    if (beforeUse == null) return task;
    final socket = task.socket.then<io.Socket>((socket) {
      try {
        beforeUse();
      } catch (_) {
        // HttpClient never takes ownership of a socket whose future fails
        socket.destroy();
        rethrow;
      }
      return socket;
    });
    return io.ConnectionTask.fromSocket<io.Socket>(socket, task.cancel);
  };
  return client;
}

typedef _Connect = Future<io.ConnectionTask<io.Socket>> Function(Uri url, String? proxyHost, int? proxyPort);

/// GRAVIX (2026-10-11): how a connection is raced. Device recheck 2026-10-11
/// (Xiaomi, Network Link Conditioner "Very Bad Network": RTT 1-2 s, 25-35 %
/// loss): a join's signal dial that was not through within Timeouts.connection
/// failed the join -- on main 36862c4 and on every later version -- on a path
/// that works, slowly. And on a blackholed path (soak 2026-10-11) a connection
/// whose SYN went nowhere only gets the OS's SYN retries.
///
/// A connection not up (TCP, and TLS for https) [every] after it started gets
/// another one started in parallel, up to [maxConnects] in all; the FIRST to be
/// up is the client's socket, every other one is cancelled (or destroyed if it
/// comes up later). Only one socket is ever handed to the client, so its request
/// (a WebSocket upgrade: a server session) is written once. A connection that
/// fails outright (refused, unreachable, a bad certificate) is an answer: when
/// none is left pending the race fails at once, without waiting for the next
/// one. The race has no end of its own; the caller's bound closes the client,
/// which cancels it. (For https a loser whose TCP is up but whose TLS handshake
/// is still running is not interrupted by the cancel: it is destroyed when the
/// handshake ends. Nothing is ever written on a loser.)
class GravixConnectHedge {
  const GravixConnectHedge(this.every, {this.maxConnects = 4});
  final Duration every;
  final int maxConnects;
}

class _HedgedConnect {
  _HedgedConnect(this._connect, this._hedge, this._url, this._proxyHost, this._proxyPort, this._onConnect) {
    // the client always listens to the socket future; this only keeps an error
    // after the client went away from being unhandled
    unawaited(_winner.future.then((_) {}, onError: (Object _) {}));
    _start();
  }

  final _Connect _connect;
  final GravixConnectHedge _hedge;
  final Uri _url;
  final String? _proxyHost;
  final int? _proxyPort;
  final void Function()? _onConnect;
  final _winner = Completer<io.Socket>();
  final _tasks = <io.ConnectionTask<io.Socket>>[];
  var _started = 0;
  var _pending = 0;
  var _closed = false;
  Timer? _next;

  Future<io.ConnectionTask<io.Socket>> get task =>
      Future.value(io.ConnectionTask.fromSocket<io.Socket>(_winner.future, _cancel));

  bool get _over => _closed || _winner.isCompleted;

  void _start() {
    if (_over) return;
    _started++;
    _pending++;
    if (_started > 1) {
      logger.fine(
        '[http] ${_url.host}: no connection after ${(_hedge.every * (_started - 1)).inMilliseconds} ms, '
        'connecting again in parallel (#$_started)',
      );
    }
    _onConnect?.call();
    if (_started < _hedge.maxConnects) _next = Timer(_hedge.every, _start);
    Future<io.ConnectionTask<io.Socket>>.sync(() => _connect(_url, _proxyHost, _proxyPort)).then((task) {
      if (_over) {
        _pending--;
        task.socket.then((s) => s.destroy(), onError: (Object _) {});
        task.cancel();
        return;
      }
      _tasks.add(task);
      task.socket.then((socket) {
        _pending--;
        if (_over) {
          socket.destroy();
          return;
        }
        _next?.cancel();
        if (_started > 1) logger.fine('[http] ${_url.host}: up after $_started connection(s) were started');
        _winner.complete(socket);
        for (final t in _tasks) {
          if (!identical(t, task)) t.cancel();
        }
      }, onError: (Object e, StackTrace st) => _failed(e, st));
    }, onError: (Object e, StackTrace st) => _failed(e, st));
  }

  void _failed(Object e, StackTrace st) {
    _pending--;
    if (_over || _pending > 0) return;
    // every connection so far failed outright: that is the answer
    _next?.cancel();
    _winner.completeError(e, st);
  }

  void _cancel() {
    if (_closed) return;
    _closed = true;
    // (after a win the losers are cancelled already, and the winner is the
    // client's socket now)
    if (_winner.isCompleted) return;
    _next?.cancel();
    for (final t in _tasks) {
      t.cancel();
    }
    _winner.completeError(const io.SocketException('Connection attempt cancelled'));
  }
}

// What io.HttpClient does without a connectionFactory (no pinning): a plain socket
// to the proxy (the client tunnels and secures it itself), a TLS socket for https.
Future<io.ConnectionTask<io.Socket>> _plainConnect(Uri url, String? proxyHost, int? proxyPort) {
  if (proxyHost != null && proxyPort != null) return io.Socket.startConnect(proxyHost, proxyPort);
  if (url.scheme == 'https' || url.scheme == 'wss') return io.SecureSocket.startConnect(url.host, _portFor(url));
  return io.Socket.startConnect(url.host, _portFor(url));
}

class _CertificatePinningConnectionFactory {
  final CertificatePinValidator _validator;

  // rules and certificate bytes are immutable for the client's lifetime, so
  // the trust store for a host only needs to be built once
  final Map<String, io.SecurityContext?> _securityContexts = {};

  _CertificatePinningConnectionFactory(this._validator);

  Future<io.ConnectionTask<io.Socket>> connect(Uri url, String? proxyHost, int? proxyPort) async {
    final rules = _rulesFor(url);

    if (proxyHost != null || proxyPort != null) {
      if (rules.isNotEmpty) {
        throw UnsupportedError('Certificate pinning through HTTP proxies is not supported');
      }
      if (proxyHost == null || proxyPort == null) {
        throw ArgumentError('Proxy host and port must both be set');
      }
      return io.Socket.startConnect(proxyHost, proxyPort);
    }

    if (!_isTlsScheme(url.scheme)) {
      return io.Socket.startConnect(url.host, _portFor(url));
    }

    final context = _securityContexts.putIfAbsent(url.host.toLowerCase(), () => _securityContextFor(rules));
    final task = await io.SecureSocket.startConnect(url.host, _portFor(url), context: context);

    final socket = task.socket.then<io.Socket>((socket) {
      try {
        _validator.validatePeerCertificate(uri: url, certificateDer: socket.peerCertificate?.der);
      } catch (_) {
        // HttpClient never takes ownership of a socket whose future fails,
        // close it here or the TLS connection leaks
        socket.destroy();
        rethrow;
      }
      return socket;
    });

    return io.ConnectionTask.fromSocket<io.Socket>(socket, task.cancel);
  }

  List<CertificatePinningRule> _rulesFor(Uri url) {
    if (!_isTlsScheme(url.scheme)) {
      return const [];
    }
    final rules = _validator.rulesForHost(url.host).where((rule) => rule.isEnabled).toList(growable: false);
    if (rules.isEmpty) {
      logger.warning(
        'Certificate pinning is enabled but no rule matches host ${url.host}, '
        'this connection uses platform trust only',
      );
    }
    return rules;
  }

  io.SecurityContext? _securityContextFor(List<CertificatePinningRule> rules) {
    final trustedCertificates = rules
        .where((rule) => rule.hasTrustedCertificates)
        .expand((rule) => rule.trustedCertificates)
        .toList();
    if (trustedCertificates.isEmpty) {
      return null;
    }

    final context = io.SecurityContext(withTrustedRoots: false);
    for (final certificate in trustedCertificates) {
      context.setTrustedCertificatesBytes(certificatePemBytes(certificate));
    }
    return context;
  }
}

bool _isTlsScheme(String scheme) => scheme == 'https' || scheme == 'wss';

int _portFor(Uri uri) {
  // GRAVIX (2026-10-11): io.WebSocket.connect rewrites ws(s):// to http(s)://
  // with `port: uri.port`, which is 0 for a ws/wss url without a port; an
  // explicit 0 here means the scheme's default, as io.HttpClient itself reads
  // it. Emulator 2026-10-11 (API 34, r511 / r512 / r522): the raced signal dial
  // connected to port 0 and every join failed ("Network is unreachable", errno
  // 101); the standby race's fresh dial and a pinned wss dial did the same.
  if (uri.hasPort && uri.port != 0) {
    return uri.port;
  }
  return _isTlsScheme(uri.scheme) ? 443 : 80;
}

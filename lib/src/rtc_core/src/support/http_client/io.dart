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

import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;

import '../../logger.dart';
import '../../options.dart';
import '../certificate_pinning.dart';

http.Client createSdkHttpClient(NetworkOptions networkOptions) =>
    http_io.IOClient(createSdkIoHttpClient(networkOptions));

/// [onConnect]: called for every NEW socket the client opens (not for a request
/// served from its keep-alive pool). The standby pre-connect (standby_io.dart)
/// uses it to tell whether the join's upgrade really reused its warm connection.
io.HttpClient createSdkIoHttpClient(NetworkOptions networkOptions, {void Function()? onConnect}) {
  final validator = CertificatePinValidator(networkOptions.certificatePinning);
  final client = io.HttpClient();
  if (!validator.isEnabled && onConnect == null) {
    return client;
  }

  final connect = validator.isEnabled ? _CertificatePinningConnectionFactory(validator).connect : _plainConnect;
  client.connectionFactory = onConnect == null
      ? connect
      : (url, proxyHost, proxyPort) {
          onConnect();
          return connect(url, proxyHost, proxyPort);
        };
  return client;
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
  if (uri.hasPort) {
    return uri.port;
  }
  return _isTlsScheme(uri.scheme) ? 443 : 80;
}

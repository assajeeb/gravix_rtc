// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'package:http/http.dart' as http;

import '../rtc_core/src/options.dart';
import '../rtc_core/src/support/http_client.dart';
import 'gravix_region_prober.dart';

/// How long an idle probe socket stays pooled. Covers the whole sampling window
/// of one region (4 samples, each bounded by the measurement timeout, 3 s in the
/// tester); the client is closed when the region is done anyway.
const kGravixProbeIdleTimeout = Duration(seconds: 30);

/// One region's probe connection for the duration of a measurement.
///
/// Field 2026-10-01 (Bangladesh, same phone, same Wi-Fi): the Android tester
/// measured sgp1 190-265 ms / blr1 200-333 ms and flip-flopped between them; the
/// web tester measured sgp1 61 / blr1 116-122 every time. Every Dart sample went
/// through `sdkHttpGet`, which opens a client per request and closes it, so each
/// "warm" sample paid DNS + TCP + TLS + HTTP (3-4 round trips) - a handshake
/// race, not an RTT. The browser keeps its connection alive between samples.
///
/// This client is kept for all the samples of ONE region: the first request
/// opens the socket (the cold sample, dropped), requests 2..N reuse it from the
/// keep-alive pool and measure one round trip. [close] after the region.
class GravixRegionProbeClient {
  GravixRegionProbeClient({
    NetworkOptions networkOptions = const NetworkOptions(),
    Duration idleTimeout = kGravixProbeIdleTimeout,
  }) {
    _client = createSdkProbeHttpClient(networkOptions, onConnect: () => _connections++, idleTimeout: idleTimeout);
  }

  late final http.Client _client;
  int _connections = 0;
  bool _closed = false;

  /// Sockets this client opened (native only; always 0 on web, where the
  /// browser pools connections and exposes no hook). 1 after a healthy
  /// measurement of any number of samples.
  int get connections => _connections;

  bool get isClosed => _closed;

  /// [GravixRegionProber.defaultProbe] on this connection.
  Future<void> probe(String url) => _guard(() => GravixRegionProber.defaultProbe(url, client: _client));

  /// [GravixRegionProber.defaultVerifiedProbe] on this connection.
  Future<String?> verifiedProbe(String probeUrl) =>
      _guard(() => GravixRegionProber.defaultVerifiedProbe(probeUrl, client: _client));

  Future<T> _guard<T>(Future<T> Function() run) {
    if (_closed) return Future<T>.error(StateError('GravixRegionProbeClient is closed'));
    return run();
  }

  /// Closes the pooled socket(s). Requests still in flight (a timed-out sample)
  /// are aborted. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

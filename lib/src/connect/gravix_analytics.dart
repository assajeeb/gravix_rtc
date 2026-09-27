// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.
//
// Opt-in join report upload to the Gravix analytics collector
// (ANALYTICS_CONTRACT.md §2, v1, 2026-09-27): after each connect the SDK POSTs
// one small JSON body to `{collector}/v1/ingest/client`, authenticated with the
// join token the connect used. Fire-and-forget: it never delays, blocks or
// fails a join, and never throws (the same rule as the React SDK's
// reportConnection: a broken metric must not break a connection).
import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'gravix_join_timeline.dart' show kGravixSdkVersion;

/// The collector rejects bodies over 64 KB (contract §2).
const int kGravixAnalyticsMaxBody = 64 * 1024;

/// How long one upload may take before it is abandoned.
const Duration kGravixAnalyticsTimeout = Duration(seconds: 5);

/// The contract's network values: `wifi`, `cellular`, `ethernet`, `unknown`.
typedef GravixNetworkTypeReader = Future<String> Function();

/// Maps connectivity_plus results to the contract's network value. The first
/// match in wifi, cellular, ethernet order wins (a phone on Wi-Fi with mobile
/// data on reports `wifi`, the path the OS routes over).
String gravixNetworkTypeFrom(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.wifi)) return 'wifi';
  if (results.contains(ConnectivityResult.mobile)) return 'cellular';
  if (results.contains(ConnectivityResult.ethernet)) return 'ethernet';
  return 'unknown';
}

Future<String> _defaultNetworkType() async {
  try {
    return gravixNetworkTypeFrom(await Connectivity().checkConnectivity().timeout(const Duration(seconds: 1)));
  } catch (_) {
    return 'unknown';
  }
}

/// Removes anything token-like from an error message before it leaves the
/// device: `access_token=` query values, bearer values, and [token] itself.
String gravixRedactError(String message, {String? token}) {
  var s = message;
  if (token != null && token.isNotEmpty) s = s.replaceAll(token, '<redacted>');
  s = s.replaceAll(RegExp(r'access_token=[^&\s"]+'), 'access_token=<redacted>');
  s = s.replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9\-_.=]+'), 'Bearer <redacted>');
  return s.length > 500 ? s.substring(0, 500) : s;
}

/// One join, as the collector wants it (contract §2 body, minus the fields the
/// uploader fills in: `v`, `kind`, `sdk`, `sdk_version`, `network`).
@immutable
class GravixJoinAnalyticsReport {
  const GravixJoinAnalyticsReport({
    required this.connectionId,
    required this.url,
    required this.joinMs,
    required this.success,
    this.region = '',
    this.participantSid,
    this.error = '',
    this.timeline,
  });

  final String connectionId;

  /// The signalling url the join landed on (or last tried, when it failed).
  final String url;

  /// Region slug of [url] (`blr1`), empty when unknown.
  final String region;
  final String? participantSid;
  final int joinMs;
  final bool success;

  /// Why the join failed; empty on success. Already redacted.
  final String error;

  /// The `GravixJoinTimeline.toJson()` of this join, when the app recorded one.
  final Map<String, Object?>? timeline;

  GravixJoinAnalyticsReport withTimeline(Map<String, Object?>? t) => GravixJoinAnalyticsReport(
    connectionId: connectionId,
    url: url,
    joinMs: joinMs,
    success: success,
    region: region,
    participantSid: participantSid,
    error: error,
    timeline: t,
  );
}

/// Uploads join reports to a Gravix analytics collector. Opt-in: pass one as
/// `GravixRoomService(analytics: …)`, or `analyticsUrl:` to a connect.
///
/// ```dart
/// final room = GravixRoomService(analytics: GravixAnalytics(url: 'https://analytics.example.com'));
/// ```
class GravixAnalytics {
  GravixAnalytics({
    required this.url,
    http.Client? client,
    this.timeout = kGravixAnalyticsTimeout,
    GravixNetworkTypeReader? networkType,
    this.sdk = 'FLUTTER',
    this.sdkVersion = kGravixSdkVersion,
  }) : _client = client,
       _networkType = networkType ?? _defaultNetworkType;

  /// The collector's base url, e.g. `https://analytics.example.com`.
  final String url;
  final Duration timeout;
  final String sdk;
  final String sdkVersion;
  final http.Client? _client;
  final GravixNetworkTypeReader _networkType;

  /// `POST` target: `{url}/v1/ingest/client`.
  Uri get endpoint => Uri.parse('${url.replaceAll(RegExp(r'/+$'), '')}/v1/ingest/client');

  /// The contract §2 body for [report].
  Map<String, Object?> buildBody(GravixJoinAnalyticsReport report, {required String network}) => <String, Object?>{
    'v': 1,
    'kind': 'join',
    'sdk': sdk,
    'sdk_version': sdkVersion,
    'connection_id': report.connectionId,
    if (report.participantSid != null && report.participantSid!.isNotEmpty) 'participant_sid': report.participantSid,
    'region': report.region,
    'url': report.url,
    'join_ms': report.joinMs,
    'success': report.success,
    'error': report.error,
    if (report.timeline != null) 'timeline': report.timeline,
    'network': network,
  };

  /// Sends [report], authenticated with [token] (the join token). Resolves true
  /// when the collector answered 2xx; false on anything else, including a
  /// timeout. Never throws. The caller does not await it on the join path.
  Future<bool> reportJoin(GravixJoinAnalyticsReport report, {required String token}) async {
    try {
      final network = await _networkType().catchError((Object _) => 'unknown');
      var body = jsonEncode(buildBody(report, network: network));
      if (utf8.encode(body).length > kGravixAnalyticsMaxBody && report.timeline != null) {
        // The timeline is optional; the join facts are not.
        body = jsonEncode(buildBody(report.withTimeline(null), network: network));
      }
      final client = _client ?? http.Client();
      try {
        final response = await client
            .post(endpoint, headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'}, body: body)
            .timeout(timeout);
        final ok = response.statusCode >= 200 && response.statusCode < 300;
        if (!ok) debugPrint('gravix analytics: collector answered ${response.statusCode}');
        return ok;
      } finally {
        if (_client == null) client.close();
      }
    } catch (e) {
      debugPrint('gravix analytics: upload failed (${e.runtimeType})');
      return false;
    }
  }
}

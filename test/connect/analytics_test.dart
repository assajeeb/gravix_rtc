// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.

import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.sig';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    for (final name in const [
      'com.ryanheise.audio_session',
      'com.ryanheise.android_audio_manager',
      'com.ryanheise.av_audio_session',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => switch (call.method) {
          'getDevices' => <dynamic>[],
          'getMode' => 0,
          'isBluetoothScoOn' => false,
          _ => null,
        },
      );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
    );
  });

  final requests = <http.Request>[];
  MockClient collector({int status = 202}) => MockClient((req) async {
    requests.add(req);
    return http.Response('', status);
  });
  setUp(requests.clear);

  GravixAnalytics analytics(http.Client client, {Duration timeout = kGravixAnalyticsTimeout}) => GravixAnalytics(
    url: 'https://analytics.example.com/',
    client: client,
    timeout: timeout,
    networkType: () async => 'wifi',
  );

  const report = GravixJoinAnalyticsReport(
    connectionId: 'c-1',
    url: 'wss://rtc-blr1.example.com',
    region: 'blr1',
    participantSid: 'PA_x',
    joinMs: 312,
    success: true,
  );

  group('GravixAnalytics', () {
    test('POSTs the contract body to {url}/v1/ingest/client with the join token', () async {
      expect(await analytics(collector()).reportJoin(report.withTimeline({'ms': 1}), token: jwt), isTrue);
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://analytics.example.com/v1/ingest/client');
      expect(req.headers['Authorization'], 'Bearer $jwt');
      expect(req.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(req.body), {
        'v': 1,
        'kind': 'join',
        'sdk': 'FLUTTER',
        'sdk_version': kGravixSdkVersion,
        'connection_id': 'c-1',
        'participant_sid': 'PA_x',
        'region': 'blr1',
        'url': 'wss://rtc-blr1.example.com',
        'join_ms': 312,
        'success': true,
        'error': '',
        'timeline': {'ms': 1},
        'network': 'wifi',
      });
    });

    test('a non-2xx answer, a thrown client and a timeout all resolve false, never throw', () async {
      expect(await analytics(collector(status: 401)).reportJoin(report, token: jwt), isFalse);
      expect(
        await analytics(MockClient((_) async => throw http.ClientException('down'))).reportJoin(report, token: jwt),
        isFalse,
      );
      final hang = MockClient((_) => Completer<http.Response>().future);
      expect(await analytics(hang, timeout: const Duration(milliseconds: 20)).reportJoin(report, token: jwt), isFalse);
    });

    test('a timeline that would push the body over 64 KB is dropped, the join facts kept', () async {
      await analytics(collector()).reportJoin(report.withTimeline({'big': 'x' * (70 * 1024)}), token: jwt);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body.containsKey('timeline'), isFalse);
      expect(body['join_ms'], 312);
      expect(requests.single.bodyBytes.length, lessThanOrEqualTo(kGravixAnalyticsMaxBody));
    });

    test('network type mapping', () {
      expect(gravixNetworkTypeFrom([ConnectivityResult.wifi, ConnectivityResult.mobile]), 'wifi');
      expect(gravixNetworkTypeFrom([ConnectivityResult.mobile]), 'cellular');
      expect(gravixNetworkTypeFrom([ConnectivityResult.ethernet]), 'ethernet');
      expect(gravixNetworkTypeFrom([ConnectivityResult.vpn]), 'unknown');
      expect(gravixNetworkTypeFrom(const []), 'unknown');
    });

    test('errors are redacted before upload', () {
      final s = gravixRedactError('ws refused wss://h/rtc?access_token=abc.def&x=1 Bearer abc.def $jwt', token: jwt);
      expect(s, isNot(contains('abc.def')));
      expect(s, isNot(contains(jwt)));
      expect(s, contains('access_token=<redacted>'));
    });
  });

  group('GravixRoomService', () {
    test('a successful connect uploads one success report, with the join token', () async {
      final s = GravixRoomService(analytics: analytics(collector()), connectRoom: (room, url, token) async {});
      expect(await s.connect(url: 'wss://rtc.example.com', token: jwt), isTrue);
      expect(await s.debugLastAnalyticsUpload, isTrue);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['success'], isTrue);
      expect(body['url'], 'wss://rtc.example.com');
      expect(body['join_ms'], isA<int>());
      expect(requests.single.headers['Authorization'], 'Bearer $jwt');
    });

    test('a failed connect uploads a failure report with a redacted error, and still returns false', () async {
      final s = GravixRoomService(
        analytics: analytics(collector()),
        connectRoom: (room, url, token) async => throw StateError('refused $url?access_token=$token'),
      );
      expect(await s.connect(url: 'wss://rtc.example.com', token: jwt), isFalse);
      await s.debugLastAnalyticsUpload;
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['success'], isFalse);
      expect(body['error'], contains('refused'));
      expect(body['error'], isNot(contains(jwt)));
    });

    test('a collector that never answers does not delay the join', () async {
      final hang = MockClient((_) => Completer<http.Response>().future);
      final s = GravixRoomService(analytics: analytics(hang), connectRoom: (room, url, token) async {});
      final watch = Stopwatch()..start();
      expect(await s.connect(url: 'wss://rtc.example.com', token: jwt).timeout(const Duration(seconds: 2)), isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('off by default: no analytics, no upload', () async {
      final s = GravixRoomService(connectRoom: (room, url, token) async {});
      expect(s.analytics, isNull);
      await s.connect(url: 'wss://rtc.example.com', token: jwt);
      expect(s.debugLastAnalyticsUpload, isNull);
    });

    test(
      'with a join timeline, a failed join is still reported at once (the report never waits for the timeline)',
      () async {
        final s = GravixRoomService(
          analytics: analytics(collector()),
          connectRoom: (room, url, token) async => throw StateError('refused'),
        );
        await s.connect(url: 'wss://rtc.example.com', token: jwt, joinTimeline: const GravixJoinTimelineInput());
        expect(await s.debugLastAnalyticsUpload, isTrue);
        final body = jsonDecode(requests.single.body) as Map;
        expect(body['success'], isFalse);
        expect(body['connection_id'], isNotEmpty);
      },
    );

    test(
      'a successful join with a timeline is uploaded as soon as connect returns, not held for first audio',
      () async {
        final s = GravixRoomService(analytics: analytics(collector()), connectRoom: (room, url, token) async {});
        expect(
          await s.connect(url: 'wss://rtc.example.com', token: jwt, joinTimeline: const GravixJoinTimelineInput()),
          isTrue,
        );
        expect(
          s.debugLastAnalyticsUpload,
          isNotNull,
          reason: 'an app closed within the first-audio window must not lose the report',
        );
        expect(await s.debugLastAnalyticsUpload, isTrue);
        final body = jsonDecode(requests.single.body) as Map;
        expect(body['success'], isTrue);
        unawaited(s.disconnect());
        await Future<void>.delayed(Duration.zero);
        expect(requests, hasLength(1), reason: 'one report per join');
      },
    );
  });
}

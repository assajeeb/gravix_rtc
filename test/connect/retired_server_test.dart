// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-12: the SDK refuses Gravix's retired server deployment. A url naming
// one of its hosts fails fast with a typed RetiredServerException BEFORE any
// network I/O (no HTTP client is even created), wherever the url enters the
// SDK: Room.connect / prepareConnection, GravixRoomService.connect, the
// standby, a token response, the region list, the region probe, a token
// endpoint. Every host literal in this file comes from
// RetiredServerException.retiredHosts except the one pinning line.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:http/http.dart' as http;

import '../support/fake_rtc.dart';

/// Every dart:io HttpClient (package:http's IOClient, sdkHttpHead, the standby,
/// a WebSocket dial) is created through HttpOverrides: counting the creations
/// proves that nothing was sent, and throwing makes sure nothing could be.
class _NoNetwork extends HttpOverrides {
  int clients = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    throw const SocketException('test: no network in retired_server_test');
  }
}

/// A package:http client that records every request and answers 200.
class _RecordingClient extends http.BaseClient {
  final requests = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return http.StreamedResponse(Stream.value('{}'.codeUnits), 200);
  }
}

final rtcHost = RetiredServerException.retiredHosts[0];
final blrHost = RetiredServerException.retiredHosts[1];
final tokenHost = RetiredServerException.retiredHosts[2];

Matcher throwsRetired(String host) => throwsA(isA<RetiredServerException>().having((e) => e.host, 'host', host));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NoNetwork net;

  setUp(() {
    net = _NoNetwork();
    HttpOverrides.global = net;
    // GravixRoomService.connect reaches audio_session before the transport.
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
  });

  group('RetiredServerException.retiredHostOf', () {
    test('the retired hosts, pinned', () {
      expect(RetiredServerException.retiredHosts, [
        'rtc.gravixcloud.com',
        'rtc-blr1.gravixcloud.com',
        'token.gravixcloud.com',
      ]);
    });

    test('any scheme, case, port, path, trailing dot or none of them', () {
      for (final h in RetiredServerException.retiredHosts) {
        for (final url in [
          'wss://$h',
          'ws://$h:7880',
          'https://$h/v1/token',
          'http://$h/settings/regions',
          'WSS://${h.toUpperCase()}:443/rtc?access_token=x',
          'wss://$h./',
          ' wss://$h ',
          'wss://user@$h',
          h,
          '$h:443',
          '$h/rtc',
        ]) {
          expect(RetiredServerException.retiredHostOf(url), h, reason: url);
        }
      }
    });

    test('nothing else: region hosts, look-alikes, sub-domains, garbage', () {
      for (final url in [
        'wss://sgp1.example.com',
        'wss://blr1.example',
        'wss://x.$rtcHost',
        'wss://$rtcHost.evil.example',
        'wss://not$rtcHost',
        'wss://${blrHost.replaceFirst('rtc-', '')}',
        'wss://127.0.0.1:7880',
        '',
        'not a url at all',
        '://',
      ]) {
        expect(RetiredServerException.retiredHostOf(url), isNull, reason: url);
      }
    });

    test('typed, names the host, says what to do', () {
      final e = RetiredServerException(rtcHost);
      expect(e, isA<GravixRtcException>());
      expect(e.message, 'retired Gravix server ($rtcHost): use the url from your token response');
      expect(() => RetiredServerException.check('wss://$blrHost'), throwsRetired(blrHost));
      expect(() => RetiredServerException.check('wss://sgp1.example.com'), returnsNormally);
    });
  });

  group('Room', () {
    Room fakeRoom(FakeSignalServer server) {
      final engine = Engine(
        connectOptions: ConnectOptions(timeouts: fastTimeouts()),
        roomOptions: RoomOptions(reconnectPolicy: FastPolicy()),
        signalClient: SignalClient(server.connect),
        peerConnectionCreate: FakePcFactory().create,
      );
      return Room(
        engine: engine,
        roomOptions: RoomOptions(reconnectPolicy: FastPolicy()),
      );
    }

    test('connect: the typed error, no dial, no HTTP, still disconnected', () async {
      final server = FakeSignalServer()..joinResponse = (_) => fakeJoinResponse();
      final room = fakeRoom(server);
      addTearDown(room.dispose);
      await expectLater(room.connect('wss://$rtcHost', 'tok'), throwsRetired(rtcHost));
      await expectLater(room.connect('wss://${blrHost.toUpperCase()}:443', 'tok'), throwsRetired(blrHost));
      expect(server.dials, isEmpty);
      expect(net.clients, 0);
      expect(room.connectionState, ConnectionState.disconnected);
    });

    test('prepareConnection: the typed error, no HEAD, no region-list fetch', () async {
      final room = fakeRoom(FakeSignalServer());
      addTearDown(room.dispose);
      await expectLater(room.prepareConnection('wss://$rtcHost', 'tok'), throwsRetired(rtcHost));
      await expectLater(room.prepareConnection('wss://$blrHost', null), throwsRetired(blrHost));
      expect(net.clients, 0);
    });
  });

  group('GravixRoomService', () {
    test('connect: the typed error before anything runs; the service is not left joining', () async {
      final dialled = <String>[];
      final prepared = <String>[];
      final service = GravixRoomService(
        connectRoom: (room, url, token) async => dialled.add(url),
        prepareConnection: (httpUrl) async => prepared.add(httpUrl),
      );
      await expectLater(service.connect(url: 'wss://$rtcHost', token: 'jwt'), throwsRetired(rtcHost));
      expect(dialled, isEmpty);
      expect(prepared, isEmpty);
      expect(service.isJoining.value, isFalse);
      expect(net.clients, 0);
    });

    test('connect: a retired region entry is never probed nor dialled', () async {
      final probed = <String>[];
      final dialled = <String>[];
      final service = GravixRoomService(
        regionProber: GravixRegionProber(probe: (url) async => probed.add(url)),
        connectRoom: (room, url, token) async {
          dialled.add(url);
          throw StateError('test: no server');
        },
      );
      final ok = await service.connect(
        url: 'wss://sgp1.example',
        token: 'jwt',
        regionProbe: true,
        regionDecisionCache: false,
        regionEntries: [
          GravixRegionUrl(region: 'blr1', url: 'wss://$blrHost'),
          const GravixRegionUrl(region: 'sgp1', url: 'wss://sgp1.example'),
          GravixRegionUrl(region: 'old', url: 'wss://$rtcHost'),
        ],
      );
      expect(ok, isFalse);
      expect(dialled, isNotEmpty);
      for (final url in [...probed, ...dialled]) {
        expect(RetiredServerException.retiredHostOf(url), isNull, reason: url);
      }
    });

    test('standby: false, nothing opened', () async {
      final service = GravixRoomService();
      expect(await service.standby('wss://$rtcHost', 'jwt'), isFalse);
      expect(await GravixStandby.open('wss://$blrHost', 'jwt'), isFalse);
      expect(GravixStandby.state('wss://$blrHost', 'jwt').state, 'none');
      expect(net.clients, 0);
    });
  });

  group('token responses and region lists', () {
    test('a token response whose url is retired: malformed, caused by the typed error', () {
      expect(
        () => GravixJoinCredentials.fromResponse({'token': 'jwt', 'url': 'wss://$rtcHost'}),
        throwsA(
          isA<GravixTokenException>()
              .having((e) => e.reason, 'reason', GravixTokenErrorReason.malformed)
              .having((e) => e.cause, 'cause', isA<RetiredServerException>()),
        ),
      );
    });

    test('retired region entries are dropped from a token response', () {
      final response = <String, dynamic>{
        'token': 'jwt',
        'url': 'wss://sgp1.example',
        'region_urls': [
          {'region': 'sgp1', 'url': 'wss://sgp1.example'},
          {'region': 'blr1', 'url': 'wss://$blrHost'},
          'wss://$rtcHost',
        ],
      };
      final credentials = GravixJoinCredentials.fromResponse(response);
      expect([for (final e in credentials.regionEntries) e.url], ['wss://sgp1.example']);
      expect([for (final e in gravixRegionEntriesFrom(response)) e.url], ['wss://sgp1.example']);
      expect(gravixRegionUrlsFrom(response), ['wss://sgp1.example']);
    });

    test('GravixTokenProvider.endpoint on a retired host: refused at construction', () {
      expect(() => GravixTokenProvider.endpoint(Uri.parse('https://$tokenHost/v1/token')), throwsRetired(tokenHost));
    });

    test('the default region probes refuse a retired host without a request', () async {
      final client = _RecordingClient();
      await expectLater(GravixRegionProber.defaultProbe('wss://$blrHost', client: client), throwsRetired(blrHost));
      await expectLater(
        GravixRegionProber.defaultVerifiedProbe('https://$rtcHost/v1/region-probe', client: client),
        throwsRetired(rtcHost),
      );
      expect(client.requests, isEmpty);
    });
  });
}

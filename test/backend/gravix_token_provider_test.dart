// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const sgp = 'wss://rtc-sgp1.example.com';
const blr = 'wss://rtc-blr1.example.com';

/// An unsigned JWT. The provider reads `exp`/`nbf` without verifying — it has no
/// key to verify with, and the SFU is the judge of the signature anyway.
String jwt({DateTime? exp, DateTime? nbf, String sub = 'u1'}) {
  String part(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return [
    part({'alg': 'HS256', 'typ': 'JWT'}),
    part({
      'sub': sub,
      if (exp != null) 'exp': exp.millisecondsSinceEpoch ~/ 1000,
      if (nbf != null) 'nbf': nbf.millisecondsSinceEpoch ~/ 1000,
    }),
    'c2ln',
  ].join('.');
}

/// The gateway's /v1/token response, as the live auth-service emits it.
Map<String, dynamic> gatewayResponse(String token) => <String, dynamic>{
  'token': token,
  'url': sgp,
  'room': 'r1',
  'identity': 'u1',
  'region_urls': [
    {'region': 'sgp1', 'url': sgp, 'probe_url': 'https://rtc-sgp1.example.com/v1/region-probe', 'home': true},
    {'region': 'blr1', 'url': blr, 'probe_url': 'https://rtc-blr1.example.com/v1/region-probe', 'home': false},
  ],
};

const request = GravixTokenRequest(room: 'r1', identity: 'u1', name: 'Alice', canPublish: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var now = DateTime.utc(2026, 9, 19, 12);
  DateTime clock() => now;

  setUp(() => now = DateTime.utc(2026, 9, 19, 12));

  group('literal (a)', () {
    test('hands back the token, url and region entries without any I/O', () async {
      final provider = GravixTokenProvider.literal(
        token: jwt(exp: now.add(const Duration(hours: 1))),
        url: sgp,
        regionEntries: const [GravixRegionUrl(region: 'sgp1', url: sgp, probeUrl: 'https://p/1')],
        now: clock,
      );
      final c = await provider.getCredentials(request);
      expect(c.url, sgp);
      expect(c.regionEntries.single.probeUrl, 'https://p/1');
      expect(c.expiresAt, now.add(const Duration(hours: 1)));
    });

    test('an expired literal is an error, not a join that fails at the WebSocket', () async {
      final provider = GravixTokenProvider.literal(
        token: jwt(exp: now.subtract(const Duration(seconds: 1))),
        url: sgp,
        now: clock,
      );
      await expectLater(
        provider.getCredentials(request),
        throwsA(isA<GravixTokenException>().having((e) => e.reason, 'reason', GravixTokenErrorReason.expired)),
      );
    });

    test('an opaque (non-JWT) literal is taken at face value and does not throw', () async {
      final provider = GravixTokenProvider.literal(token: 'not-a-jwt', url: sgp, now: clock);
      final c = await provider.getCredentials(request);
      expect(c.token, 'not-a-jwt');
      expect(c.expiresAt, isNull);
    });
  });

  group('callback (b)', () {
    test('a gateway-shaped map becomes credentials, region_urls and probe_url intact', () async {
      final provider = GravixTokenProvider.callback(
        (r) async => gatewayResponse(jwt(exp: now.add(const Duration(hours: 1)))),
        now: clock,
      );
      final c = await provider.getCredentials(request);
      expect(c.fromCache, isFalse);
      expect(c.regionEntries.map((e) => e.region), ['sgp1', 'blr1']);
      expect(c.regionEntries.last.probeUrl, 'https://rtc-blr1.example.com/v1/region-probe');
      expect(c.raw['region_urls'], isA<List<dynamic>>(), reason: 'unmodelled fields such as "home" stay reachable');
    });

    test('a second call is served from the cache: ONE fetch, fromCache true', () async {
      var calls = 0;
      final provider = GravixTokenProvider.callback((r) async {
        calls++;
        return gatewayResponse(jwt(exp: now.add(const Duration(hours: 1))));
      }, now: clock);
      await provider.getCredentials(request);
      final again = await provider.getCredentials(request);
      expect(calls, 1);
      expect(again.fromCache, isTrue);
      expect(provider.peek(request)?.token, again.token);
    });

    test('a different request is a different cache entry', () async {
      final seen = <String>[];
      final provider = GravixTokenProvider.callback((r) async {
        seen.add(r.room);
        return gatewayResponse(jwt(exp: now.add(const Duration(hours: 1))));
      }, now: clock);
      await provider.getCredentials(request);
      await provider.getCredentials(
        const GravixTokenRequest(room: 'r2', identity: 'u1', name: 'Alice', canPublish: true),
      );
      // Same room, listener instead of host: a host token must not be reused.
      await provider.getCredentials(const GravixTokenRequest(room: 'r1', identity: 'u1', name: 'Alice'));
      expect(seen, ['r1', 'r2', 'r1']);
    });

    test('expiry-aware: refetches once the JWT exp is inside minRemainingValidity', () async {
      var calls = 0;
      final provider = GravixTokenProvider.callback((r) async {
        calls++;
        return gatewayResponse(jwt(exp: now.add(const Duration(minutes: 10))));
      }, now: clock);
      await provider.getCredentials(request);
      now = now.add(const Duration(minutes: 8, seconds: 59));
      await provider.getCredentials(request);
      expect(calls, 1, reason: '61s of life left is still usable');
      now = now.add(const Duration(seconds: 2));
      expect(provider.peek(request), isNull, reason: '59s left is not');
      expect(provider.lastKnown(request), isNotNull, reason: 'the expired entry still names the url and the regions');
      await provider.getCredentials(request);
      expect(calls, 2);
    });

    test('a token whose nbf is in the future is not served from the cache', () async {
      var calls = 0;
      final provider = GravixTokenProvider.callback((r) async {
        calls++;
        return gatewayResponse(jwt(exp: now.add(const Duration(hours: 1)), nbf: now.add(const Duration(minutes: 5))));
      }, now: clock);
      await provider.getCredentials(request);
      await provider.getCredentials(request);
      expect(calls, 2);
    });

    test('an opaque token uses expires_in, else unknownExpiryTtl, and never throws', () async {
      var calls = 0;
      var body = <String, dynamic>{'token': 'opaque-1', 'url': sgp, 'expires_in': 600};
      final provider = GravixTokenProvider.callback((r) async {
        calls++;
        return body;
      }, now: clock);
      final first = await provider.getCredentials(request);
      expect(first.expiresAt, now.add(const Duration(seconds: 600)));

      provider.invalidate();
      body = <String, dynamic>{'token': 'opaque-2', 'url': sgp};
      final second = await provider.getCredentials(request);
      expect(second.expiresAt, now.add(const Duration(minutes: 5)));
      now = now.add(const Duration(minutes: 4, seconds: 30));
      await provider.getCredentials(request);
      expect(calls, 3, reason: '30s left of a guessed 5 min is under the 60s margin');
    });

    test('concurrent callers share ONE in-flight request', () async {
      var calls = 0;
      final gate = Completer<void>();
      final provider = GravixTokenProvider.callback((r) async {
        calls++;
        await gate.future;
        return gatewayResponse(jwt(exp: now.add(const Duration(hours: 1))));
      }, now: clock);
      final a = provider.getCredentials(request);
      final b = provider.getCredentials(request);
      gate.complete();
      expect((await a).token, (await b).token);
      expect(calls, 1);
    });

    test('a failed fetch is not cached, and the next call tries again', () async {
      var calls = 0;
      final provider = GravixTokenProvider.callback((r) async {
        calls++;
        if (calls == 1) throw StateError('backend down');
        return gatewayResponse(jwt(exp: now.add(const Duration(hours: 1))));
      }, now: clock);
      await expectLater(
        provider.getCredentials(request),
        throwsA(isA<GravixTokenException>().having((e) => e.reason, 'reason', GravixTokenErrorReason.callback)),
      );
      expect(provider.peek(request), isNull);
      expect((await provider.getCredentials(request)).url, sgp);
      expect(calls, 2);
    });

    test('timeout: a callback that never answers becomes a timeout error', () async {
      final provider = GravixTokenProvider.callback(
        (r) => Completer<Object>().future,
        timeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        provider.getCredentials(request),
        throwsA(isA<GravixTokenException>().having((e) => e.reason, 'reason', GravixTokenErrorReason.timeout)),
      );
      expect(GravixTokenProvider.defaultTimeout, const Duration(seconds: 8));
    });

    test('forceRefresh bypasses a valid cache entry', () async {
      var calls = 0;
      final provider = GravixTokenProvider.callback((r) async {
        calls++;
        return gatewayResponse(jwt(exp: now.add(const Duration(hours: 1))));
      }, now: clock);
      await provider.getCredentials(request);
      final forced = await provider.getCredentials(request, forceRefresh: true);
      expect(calls, 2);
      expect(forced.fromCache, isFalse);
    });

    test('the cache is bounded (LRU)', () async {
      final provider = GravixTokenProvider.callback(
        (r) async => gatewayResponse(jwt(exp: now.add(const Duration(hours: 1)))),
        maxEntries: 2,
        now: clock,
      );
      GravixTokenRequest room(String r) => GravixTokenRequest(room: r, identity: 'u1');
      await provider.getCredentials(room('a'));
      await provider.getCredentials(room('b'));
      provider.peek(room('a')); // touch: 'b' is now the least recently used
      await provider.getCredentials(room('c'));
      expect(provider.peek(room('a')), isNotNull);
      expect(provider.peek(room('b')), isNull);
      expect(provider.peek(room('c')), isNotNull);
    });

    test('a response with no token is malformed, and the message names keys only', () async {
      final provider = GravixTokenProvider.callback(
        (r) async => <String, dynamic>{'url': sgp, 'tokn': 'secret-looking-value'},
      );
      await expectLater(
        provider.getCredentials(request),
        throwsA(
          isA<GravixTokenException>()
              .having((e) => e.reason, 'reason', GravixTokenErrorReason.malformed)
              .having((e) => e.message, 'message', isNot(contains('secret-looking-value'))),
        ),
      );
    });
  });

  group('endpoint (c)', () {
    test(
      'POSTs exactly {room, identity, name, can_publish} as JSON with the app headers - and no credential',
      () async {
        late http.Request seen;
        final provider = GravixTokenProvider.endpoint(
          Uri.parse('https://api.tenant.example/rtc/token'),
          headers: const {'Authorization': 'Bearer session-abc'},
          client: MockClient((req) async {
            seen = req;
            return http.Response(jsonEncode(gatewayResponse(jwt(exp: now.add(const Duration(hours: 1))))), 200);
          }),
          now: clock,
        );
        final c = await provider.getCredentials(request);
        expect(seen.method, 'POST');
        expect(seen.url.toString(), 'https://api.tenant.example/rtc/token');
        expect(seen.headers['Content-Type'], startsWith('application/json'));
        expect(seen.headers['Authorization'], 'Bearer session-abc');
        expect(jsonDecode(seen.body), {'room': 'r1', 'identity': 'u1', 'name': 'Alice', 'can_publish': true});
        expect(seen.body, isNot(contains('api_secret')));
        expect(seen.body, isNot(contains('api_key')));
        expect(c.regionEntries.length, 2);
      },
    );

    test('unwraps a Parse Cloud Function {result: …} envelope', () async {
      final provider = GravixTokenProvider.endpoint(
        Uri.parse('https://parse.tenant.example/parse/functions/gravixToken'),
        client: MockClient(
          (req) async =>
              http.Response(jsonEncode({'result': gatewayResponse(jwt(exp: now.add(const Duration(hours: 1))))}), 200),
        ),
        now: clock,
      );
      final c = await provider.getCredentials(request);
      expect(c.url, sgp);
      expect(c.regionEntries.map((e) => e.region), ['sgp1', 'blr1']);
    });

    test('accepts the upstream token-source response shape', () async {
      final provider = GravixTokenProvider.endpoint(
        Uri.parse('https://api.tenant.example/token'),
        client: MockClient(
          (req) async => http.Response(jsonEncode({'participant_token': 'opaque', 'server_url': sgp}), 200),
        ),
      );
      final c = await provider.getCredentials(request);
      expect(c.token, 'opaque');
      expect(c.url, sgp);
      expect(c.regionEntries, isEmpty);
    });

    test('a non-2xx answer is an http error carrying the status and not the body', () async {
      final provider = GravixTokenProvider.endpoint(
        Uri.parse('https://api.tenant.example/token'),
        client: MockClient((req) async => http.Response('{"error":"internal detail"}', 403)),
      );
      await expectLater(
        provider.getCredentials(request),
        throwsA(
          isA<GravixTokenException>()
              .having((e) => e.reason, 'reason', GravixTokenErrorReason.http)
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', isNot(contains('internal detail'))),
        ),
      );
    });

    test('timeout: an endpoint that stalls becomes a timeout error', () async {
      final provider = GravixTokenProvider.endpoint(
        Uri.parse('https://api.tenant.example/token'),
        timeout: const Duration(milliseconds: 30),
        client: MockClient((req) => Completer<http.Response>().future),
      );
      await expectLater(
        provider.getCredentials(request),
        throwsA(isA<GravixTokenException>().having((e) => e.reason, 'reason', GravixTokenErrorReason.timeout)),
      );
    });

    test('a body that is not JSON is malformed', () async {
      final provider = GravixTokenProvider.endpoint(
        Uri.parse('https://api.tenant.example/token'),
        client: MockClient((req) async => http.Response('<html>502</html>', 200)),
      );
      await expectLater(
        provider.getCredentials(request),
        throwsA(isA<GravixTokenException>().having((e) => e.reason, 'reason', GravixTokenErrorReason.malformed)),
      );
    });
  });

  group('upstream TokenSource interop', () {
    test('the provider IS a TokenSourceConfigurable', () async {
      final TokenSourceConfigurable source = GravixTokenProvider.callback((r) async {
        expect(r.room, 'r9');
        expect(r.identity, 'u9');
        expect(r.canPublish, isFalse, reason: 'the upstream options have no publish flag');
        return gatewayResponse('opaque');
      });
      final response = await source.fetch(const TokenRequestOptions(roomName: 'r9', participantIdentity: 'u9'));
      expect(response.serverUrl, sgp);
      expect(response.participantToken, 'opaque');
    });

    test('fromTokenSource adapts an upstream source (no region list, by construction)', () async {
      final upstream = CustomTokenSource((options) async {
        expect(options.roomName, 'r1');
        expect(options.participantIdentity, 'u1');
        return TokenSourceResponse(
          serverUrl: sgp,
          participantToken: jwt(exp: now.add(const Duration(hours: 1))),
        );
      });
      final provider = GravixTokenProvider.fromTokenSource(upstream, now: clock);
      final c = await provider.getCredentials(request);
      expect(c.url, sgp);
      expect(c.regionEntries, isEmpty);
      expect(() => GravixTokenProvider.fromTokenSource('nope'), throwsArgumentError);
    });
  });

  group('GravixRoomService.connectWithTokenProvider', () {
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

    test(
      'region_urls and probe_url flow from the provider into the probe race; a cached token costs no request',
      () async {
        var tokenRequests = 0;
        final provider = GravixTokenProvider.callback((r) async {
          tokenRequests++;
          return gatewayResponse(jwt(exp: DateTime.now().add(const Duration(hours: 1))));
        });
        // What a room-list screen does: fetch before the tap.
        await provider.getCredentials(request);
        expect(tokenRequests, 1);

        final probed = <String>[];
        final connected = <String>[];
        final service = GravixRoomService(
          regionProber: GravixRegionProber(
            verifiedProbe: (probeUrl) async {
              probed.add(probeUrl);
              if (!probeUrl.contains('blr1')) await Future<void>.delayed(const Duration(milliseconds: 40));
              return probeUrl.contains('blr1') ? 'blr1' : 'sgp1';
            },
          ),
          regionDecisionCache: GravixRegionDecisionCache(),
          connectRoom: (room, url, token) async => connected.add(url),
        );
        final ok = await service.connectWithTokenProvider(tokenProvider: provider, request: request, regionProbe: true);

        expect(ok, isTrue);
        expect(tokenRequests, 1, reason: 'the tap must not pay for a token it already has');
        expect(
          probed,
          contains('https://rtc-blr1.example.com/v1/region-probe'),
          reason: 'probe_url survived the provider',
        );
        expect(connected, [blr], reason: 'the race ran on the provider\'s region entries and blr won');
        expect(service.regionReport.value?.chosenRegion, 'blr1', reason: 'the region slug survived too');
        // Not disposed: the seam never opened a transport, and tearing down a Room
        // that has none waits out a 10s engine timeout for nothing.
      },
    );

    test('a token error returns false, like connect(), with the reason on lastTokenError', () async {
      final service = GravixRoomService(
        connectRoom: (room, url, token) async => fail('must not connect without a token'),
      );
      final ok = await service.connectWithTokenProvider(
        tokenProvider: GravixTokenProvider.callback((r) async => throw StateError('down')),
        request: request,
      );
      expect(ok, isFalse);
      expect(service.lastTokenError?.reason, GravixTokenErrorReason.callback);
      await service.dispose();
    });
  });
}

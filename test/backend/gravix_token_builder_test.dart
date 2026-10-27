// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

/// The fixture is generated from the npm package's build (gravix-rtc-token
/// 0.1.3, `createTokenSync` with `Date.now` fixed), so these are byte-parity
/// checks against the JS signer, not against a copy of this one.
final Map<String, dynamic> _vectors =
    jsonDecode(File('test/fixtures/token_vectors.json').readAsStringSync()) as Map<String, dynamic>;

GravixTokenOptions _options(Map<String, dynamic> o) => GravixTokenOptions(
  room: o['room'] as String,
  identity: o['identity'] as String,
  name: o['name'] as String?,
  metadata: o['metadata'] as String?,
  attributes: (o['attributes'] as Map?)?.cast<String, String>(),
  ttl: o['ttlSeconds'] == null ? kGravixTokenDefaultTtl : Duration(seconds: o['ttlSeconds'] as int),
  canPublish: o['canPublish'] as bool? ?? true,
  canSubscribe: o['canSubscribe'] as bool? ?? true,
  canPublishData: o['canPublishData'] as bool? ?? true,
  canUpdateOwnMetadata: o['canUpdateOwnMetadata'] as bool? ?? true,
  canPublishSources: (o['canPublishSources'] as List?)?.cast<String>(),
  hidden: o['hidden'] as bool? ?? false,
  roomAdmin: o['roomAdmin'] as bool? ?? false,
);

Map<String, dynamic> _payload(String token) =>
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1])))) as Map<String, dynamic>;

void main() {
  final appId = _vectors['appId'] as String;
  final cert = _vectors['appCertificate'] as String;
  final fixed = DateTime.fromMillisecondsSinceEpoch(_vectors['nowMs'] as int);

  group('GravixTokenBuilder: byte parity with the npm package', () {
    for (final e in (_vectors['cases'] as Map<String, dynamic>).entries) {
      test(e.key, () {
        final c = e.value as Map<String, dynamic>;
        final token = GravixTokenBuilder.create(
          appId,
          cert,
          _options(c['options'] as Map<String, dynamic>),
          now: () => fixed,
        );
        expect(token, c['token']);
      });
    }
  });

  group('GravixTokenBuilder', () {
    test('signature is HS256 over header.payload with the certificate', () {
      final t = GravixTokenBuilder.create(appId, cert, const GravixTokenOptions(room: 'r', identity: 'u'));
      final parts = t.split('.');
      final sig = Hmac(sha256, utf8.encode(cert)).convert(utf8.encode('${parts[0]}.${parts[1]}')).bytes;
      expect(parts[2], base64Url.encode(sig).replaceAll('=', ''));
      expect(t.contains('='), isFalse);
    });

    test('claims: issuer, prefixed room, expiry from ttl', () {
      final p = _payload(
        GravixTokenBuilder.create(
          appId,
          cert,
          const GravixTokenOptions(room: 'r', identity: 'u', ttl: Duration(minutes: 15)),
          now: () => fixed,
        ),
      );
      expect(p['iss'], appId);
      expect(p['sub'], 'u');
      expect((p['video'] as Map)['room'], '${appId}_r');
      expect((p['exp'] as int) - (p['iat'] as int), 900);
    });

    test('refuses what the server would refuse', () {
      void bad(String id, String c, GravixTokenOptions o) =>
          expect(() => GravixTokenBuilder.create(id, c, o), throwsA(isA<GravixTokenBuildException>()));
      const ok = GravixTokenOptions(room: 'r', identity: 'u');
      bad('', cert, ok);
      bad('APP_x', cert, ok);
      bad(appId, 'short', ok);
      bad(appId, cert, const GravixTokenOptions(room: '', identity: 'u'));
      bad(appId, cert, const GravixTokenOptions(room: 'r', identity: ''));
      bad(appId, cert, const GravixTokenOptions(room: 'r', identity: 'u', ttl: Duration.zero));
      bad(appId, cert, const GravixTokenOptions(room: 'r', identity: 'u', ttl: Duration(hours: 25)));
    });

    test('the error message never carries the certificate', () {
      try {
        GravixTokenBuilder.create('', cert, const GravixTokenOptions(room: 'r', identity: 'u'));
      } on GravixTokenBuildException catch (e) {
        expect(e.toString().contains(cert), isFalse);
      }
    });

    test('roomName / displayName', () {
      expect(GravixTokenBuilder.roomName('APP', 'r'), 'APP_r');
      expect(GravixTokenBuilder.roomName('APP', 'APP_r'), 'APP_r');
      expect(GravixTokenBuilder.displayName('APP', 'APP_r'), 'r');
      expect(GravixTokenBuilder.displayName('APP', 'r'), 'r');
    });
  });

  group('GravixTokenProvider.local', () {
    test('signs on the device, caches, no network', () async {
      var t = fixed;
      final provider = GravixTokenProvider.local(
        appId: appId,
        appCertificate: cert,
        url: 'wss://rtc-sgp1.example.com',
        now: () => t,
      );
      const req = GravixTokenRequest(room: 'r1', identity: 'u1', name: 'Ann', canPublish: true);
      final a = await provider.getCredentials(req);
      expect(a.url, 'wss://rtc-sgp1.example.com');
      expect(a.fromCache, isFalse);
      expect(a.expiresAt!.isAtSameMomentAs(fixed.add(kGravixTokenDefaultTtl)), isTrue);
      final p = _payload(a.token);
      expect(p['name'], 'Ann');
      expect((p['video'] as Map)['canPublish'], isTrue);
      t = fixed.add(const Duration(minutes: 1));
      final b = await provider.getCredentials(req);
      expect(b.fromCache, isTrue);
      expect(b.token, a.token);
    });

    test('listener by default (GravixTokenRequest.canPublish is false)', () async {
      final provider = GravixTokenProvider.local(appId: appId, appCertificate: cert, url: 'wss://x.example.com');
      final c = await provider.getCredentials(const GravixTokenRequest(room: 'r', identity: 'u'));
      expect((_payload(c.token)['video'] as Map)['canPublish'], isFalse);
    });

    test('options hook sets the grant', () async {
      final provider = GravixTokenProvider.local(
        appId: appId,
        appCertificate: cert,
        url: 'wss://x.example.com',
        options: (r) => GravixTokenOptions(room: r.room, identity: r.identity, roomAdmin: true, hidden: true),
      );
      final v =
          _payload((await provider.getCredentials(const GravixTokenRequest(room: 'r', identity: 'u'))).token)['video']
              as Map;
      expect(v['roomAdmin'], isTrue);
      expect(v['hidden'], isTrue);
    });

    test('a bad certificate is a GravixTokenException, without the certificate in it', () async {
      final provider = GravixTokenProvider.local(
        appId: appId,
        appCertificate: 'short-secret',
        url: 'wss://x.example.com',
      );
      await expectLater(
        provider.getCredentials(const GravixTokenRequest(room: 'r', identity: 'u')),
        throwsA(
          isA<GravixTokenException>()
              .having((e) => e.reason, 'reason', GravixTokenErrorReason.callback)
              .having((e) => e.toString().contains('short-secret'), 'leaks cert', isFalse),
        ),
      );
    });

    test('region entries pass through', () async {
      const e = GravixRegionUrl(region: 'sgp1', url: 'wss://rtc-sgp1.example.com');
      final provider = GravixTokenProvider.local(
        appId: appId,
        appCertificate: cert,
        url: e.url,
        regionEntries: const [e],
      );
      final c = await provider.getCredentials(const GravixTokenRequest(room: 'r', identity: 'u'));
      expect(c.regionEntries.single.region, 'sgp1');
    });
  });
}

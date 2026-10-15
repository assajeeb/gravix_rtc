// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join: the apps reused a prefetched join token only while it was
// younger than half its lifetime and than 5 minutes, with at least 90 s left
// (a token prefetched for a card that stays on screen must not be the one a
// join presents a minute before it expires). GravixTokenReuse makes that rule a
// provider option; without it the provider keeps its 0.4.18 rule (>= 60 s left).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const sgp = 'wss://rtc-sgp1.example.com';

String jwt({required DateTime exp, String sub = 'u1'}) {
  String part(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return [
    part({'alg': 'HS256', 'typ': 'JWT'}),
    part({'sub': sub, 'exp': exp.millisecondsSinceEpoch ~/ 1000}),
    'c2ln',
  ].join('.');
}

const request = GravixTokenRequest(room: 'r1', identity: 'u1');

void main() {
  final t0 = DateTime.utc(2026, 10, 15, 12);

  group('GravixTokenReuse.allows', () {
    const rule = GravixTokenReuse.fastJoin;
    test('a 15-min token: reused for 5 min (the cap), not after', () {
      final exp = t0.add(const Duration(minutes: 15));
      expect(rule.allows(fetchedAt: t0, expiresAt: exp, now: t0.add(const Duration(minutes: 4, seconds: 59))), isTrue);
      expect(rule.allows(fetchedAt: t0, expiresAt: exp, now: t0.add(const Duration(minutes: 5))), isFalse);
    });
    test('a 6-min token: reused for half its lifetime (3 min)', () {
      final exp = t0.add(const Duration(minutes: 6));
      expect(rule.allows(fetchedAt: t0, expiresAt: exp, now: t0.add(const Duration(minutes: 2, seconds: 59))), isTrue);
      expect(rule.allows(fetchedAt: t0, expiresAt: exp, now: t0.add(const Duration(minutes: 3))), isFalse);
    });
    test('never with less than 90 s left', () {
      final exp = t0.add(const Duration(seconds: 100));
      expect(rule.allows(fetchedAt: t0, expiresAt: exp, now: t0.add(const Duration(seconds: 9))), isTrue);
      expect(rule.allows(fetchedAt: t0, expiresAt: exp, now: t0.add(const Duration(seconds: 11))), isFalse);
    });
    test('unknown expiry: the age cap alone', () {
      expect(rule.allows(fetchedAt: t0, now: t0.add(const Duration(minutes: 4))), isTrue);
      expect(rule.allows(fetchedAt: t0, now: t0.add(const Duration(minutes: 5))), isFalse);
    });
    test('the default rule is the 0.4.18 one: >= 60 s left, no age cap', () {
      const d = GravixTokenReuse();
      final exp = t0.add(const Duration(hours: 1));
      expect(d.allows(fetchedAt: t0, expiresAt: exp, now: t0.add(const Duration(minutes: 58, seconds: 59))), isTrue);
      expect(d.allows(fetchedAt: t0, expiresAt: exp, now: t0.add(const Duration(minutes: 59, seconds: 1))), isFalse);
    });
  });

  group('GravixTokenProvider(reuse:)', () {
    test('with fastJoin a 15-min token is fetched again after 5 min', () async {
      var now = t0;
      var fetches = 0;
      final p = GravixTokenProvider.callback(
        (r) async {
          fetches++;
          return {'token': jwt(exp: now.add(const Duration(minutes: 15))), 'url': sgp};
        },
        reuse: GravixTokenReuse.fastJoin,
        now: () => now,
      );
      await p.getCredentials(request);
      now = t0.add(const Duration(minutes: 4));
      expect((await p.getCredentials(request)).fromCache, isTrue);
      now = t0.add(const Duration(minutes: 5, seconds: 1));
      expect((await p.getCredentials(request)).fromCache, isFalse);
      expect(fetches, 2);
    });

    test('without reuse: the token is kept until 60 s before its expiry (unchanged)', () async {
      var now = t0;
      var fetches = 0;
      final p = GravixTokenProvider.callback((r) async {
        fetches++;
        return {'token': jwt(exp: t0.add(const Duration(minutes: 15))), 'url': sgp};
      }, now: () => now);
      await p.getCredentials(request);
      now = t0.add(const Duration(minutes: 13, seconds: 59));
      expect((await p.getCredentials(request)).fromCache, isTrue);
      expect(fetches, 1);
    });
  });
}

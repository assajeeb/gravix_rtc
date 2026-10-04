// Region selection with hysteresis and the room's home region (2026-10-05).
//
// Field test 2026-10-04: the owner's phone (Bangladesh, sgp1 and blr1 a few ms
// apart) moved between the two across four sessions in 15 minutes, and one audio
// room went cross-region (host sgp1, viewer blr1). A Saudi tester's sessions moved
// from doh1 to nyc1 after they turned on a VPN exiting in Canada. The pure rules
// run the shared fixture (test/fixtures/region_selection_cases.json, same file in
// the React SDK); the rest drives gravixMeasureRegions end to end.
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/backend/gravix_token_provider.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_region_selection.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';

final _fixture =
    json.decode(File('test/fixtures/region_selection_cases.json').readAsStringSync()) as Map<String, dynamic>;

const sgp = GravixRegionUrl(region: 'sgp1', url: 'wss://sgp1.example.test');
const blr = GravixRegionUrl(region: 'blr1', url: 'wss://blr1.example.test');
const fra = GravixRegionUrl(region: 'fra1', url: 'wss://fra1.example.test');
const doh = GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example.test');
const nyc = GravixRegionUrl(region: 'nyc1', url: 'wss://nyc1.example.test');

/// Each region answers in a fixed warm time (the dropped cold sample is +300 ms);
/// absent from [ms] = fails.
GravixRegionSampler fixed(Map<String, int> ms) {
  final seen = <String>{};
  return (GravixRegionUrl r) async {
    final v = ms[r.region];
    if (v == null) return null;
    return Duration(milliseconds: v + (seen.add(r.region) ? 300 : 0));
  };
}

Future<String?> _wifi() async => 'wifi';
Future<String?> _cellular() async => 'cellular';

/// One measurement on the 'app' list, keyed by [net] (default wifi).
Future<GravixRegionMeasurementResult> measure(
  Map<String, int> ms, {
  List<GravixRegionUrl> regions = const [sgp, blr, fra],
  GravixRegionNetworkReader net = _wifi,
}) => gravixMeasureRegions(regionUrls: regions, sampler: fixed(ms), networkType: net, networkKey: net);

void main() {
  setUp(gravixClearRegionMeasurement);

  group('shared fixture: selection', () {
    for (final c in [for (final c in _fixture['select'] as List) Map<String, dynamic>.from(c as Map)]) {
      test(c['name'] as String, () {
        final samples = [
          for (final s in c['samples'] as List)
            GravixRegionSample(
              region: s['region'] as String,
              status: s['status'] as String,
              rttMs: s['rtt_ms'] as int?,
            ),
        ];
        final out = gravixSelectRegion(
          samples,
          anchor: c['anchor'] as String?,
          challenger: GravixRegionChallenger.fromJson(c['challenger']),
          anchorKnown: c['anchorKnown'] as bool? ?? true,
        );
        final ex = c['expect'] as Map?;
        if (ex == null) {
          expect(out, isNull);
          return;
        }
        expect(out?.region, ex['region']);
        expect(out?.reason.name, ex['reason']);
        expect(out?.challenger?.toJson(), ex['challenger']);
      });
    }
  });

  group('shared fixture: home-region margin', () {
    for (final c in [for (final c in _fixture['home'] as List) Map<String, dynamic>.from(c as Map)]) {
      test(c['name'] as String, () {
        expect(gravixHomeRegionWithinMargin(homeMs: c['homeMs'] as int, fastestMs: c['fastestMs'] as int), c['expect']);
      });
    }
  });

  group('hysteresis across measurements', () {
    test('BD field case: sgp1/blr1 noise never moves the user (6 runs)', () async {
      final first = await measure({'sgp1': 60, 'blr1': 56, 'fra1': 186});
      expect(first.best?.region, 'blr1');
      // sgp1 ahead by 2-12 ms in every later run: noise, not a reason to move.
      for (final ms in [
        {'sgp1': 54, 'blr1': 58},
        {'sgp1': 50, 'blr1': 62},
        {'sgp1': 56, 'blr1': 57},
        {'sgp1': 48, 'blr1': 60},
        {'sgp1': 55, 'blr1': 58},
      ]) {
        final r = await measure({...ms, 'fra1': 186});
        expect(r.best?.region, 'blr1', reason: '$ms');
        expect(r.selectReason, GravixRegionSelectReason.kept);
        expect(gravixPickMeasuredRegion(blr.url, [sgp, blr, fra])?.region, 'blr1');
      }
    });

    test('the anchor outlives the 10-minute answer TTL (it used to be forgotten)', () async {
      // shortlist_ttl_s = 1 ms: the answer is stale at once; the anchor is not.
      Future<GravixRegionMeasurementResult> run(Map<String, int> ms) => gravixMeasureRegions(
        regionsUrl: 'https://console.example.test/v1/regions',
        fetchDirectory: (_) async => GravixRegionDirectory.fromJson({
          'regions': [
            for (final r in [sgp, blr]) {'region': r.region, 'url': r.url},
          ],
          'shortlist_ttl_s': 0.001,
        }),
        sampler: fixed(ms),
        store: GravixMemoryRegionListStore(),
        networkType: _wifi,
      );
      expect((await run({'sgp1': 60, 'blr1': 56})).best?.region, 'blr1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final again = await run({'sgp1': 50, 'blr1': 58});
      expect(again.best?.region, 'blr1');
      expect(again.selectReason, GravixRegionSelectReason.kept);
    });

    test('a clearly better region needs two consecutive wins; a lost run resets the count', () async {
      await measure({'doh1': 190, 'fra1': 120}, regions: const [doh, fra]); // anchor fra1
      final w1 = await measure({'doh1': 45, 'fra1': 120}, regions: const [doh, fra]);
      expect(w1.best?.region, 'fra1');
      expect(w1.selectReason, GravixRegionSelectReason.confirming);
      final lost = await measure({'doh1': 110, 'fra1': 120}, regions: const [doh, fra]);
      expect(lost.best?.region, 'fra1');
      expect(lost.selectReason, GravixRegionSelectReason.kept);
      final w2 = await measure({'doh1': 45, 'fra1': 120}, regions: const [doh, fra]);
      expect(w2.selectReason, GravixRegionSelectReason.confirming, reason: 'the count restarted');
      final w3 = await measure({'doh1': 46, 'fra1': 121}, regions: const [doh, fra]);
      expect(w3.best?.region, 'doh1');
      expect(w3.selectReason, GravixRegionSelectReason.switched);
      expect(gravixPickMeasuredRegion(fra.url, [doh, fra])?.region, 'doh1');
    });

    test('a failed anchor moves at once', () async {
      await measure({'sgp1': 70, 'blr1': 56});
      final r = await measure({'sgp1': 60}); // blr1 fails
      expect(r.best?.region, 'sgp1');
      expect(r.selectReason, GravixRegionSelectReason.anchorFailed);
    });

    test('networks keep their own anchors (VPN on and off cache apart)', () async {
      Future<String?> vpn() async => 'cellular+vpn';
      final plain = await measure({'doh1': 45, 'nyc1': 187}, regions: const [doh, nyc], net: _cellular);
      expect(plain.best?.region, 'doh1');
      final via = await measure({'doh1': 320, 'nyc1': 280}, regions: const [doh, nyc], net: vpn);
      expect(via.best?.region, 'nyc1', reason: 'through the VPN the packets leave from Canada');
      expect(via.selectReason, GravixRegionSelectReason.fastest, reason: 'no anchor on the VPN network yet');
      final back = await measure({'doh1': 50, 'nyc1': 190}, regions: const [doh, nyc], net: _cellular);
      expect(back.best?.region, 'doh1');
      expect(back.selectReason, GravixRegionSelectReason.fastest, reason: 'the plain network kept doh1');
    });

    test('the region cache key adds +vpn while a VPN is up', () {
      expect(gravixRegionNetworkKeyFrom([ConnectivityResult.mobile]), 'cellular');
      expect(gravixRegionNetworkKeyFrom([ConnectivityResult.mobile, ConnectivityResult.vpn]), 'cellular+vpn');
      expect(gravixRegionNetworkKeyFrom([ConnectivityResult.wifi, ConnectivityResult.vpn]), 'wifi+vpn');
      expect(gravixRegionNetworkKeyFrom([ConnectivityResult.vpn]), 'unknown+vpn');
    });
  });

  group('budget', () {
    Future<Duration?> budgetFor(GravixRegionNetworkReader net, {Duration? explicit, num? gateway}) async {
      final r = await gravixMeasureRegions(
        regionsUrl: 'https://console.example.test/v1/regions',
        fetchDirectory: (_) async => GravixRegionDirectory.fromJson({
          'regions': [
            {'region': 'sgp1', 'url': sgp.url},
          ],
          'probe_budget_ms': ?gateway,
        }),
        sampler: fixed({'sgp1': 50}),
        store: GravixMemoryRegionListStore(),
        networkType: net,
        budget: explicit,
      );
      return r.budget;
    }

    test('cellular: 3 s is a floor under the gateway\'s 1.5 s (it used to replace it)', () async {
      expect(await budgetFor(_cellular, gateway: 1500), const Duration(seconds: 3));
      expect(await budgetFor(_cellular, gateway: 4000), const Duration(seconds: 4));
      expect(await budgetFor(_cellular), const Duration(seconds: 3));
    });

    test('wifi keeps the gateway budget; an explicit budget always wins', () async {
      expect(await budgetFor(_wifi, gateway: 1500), const Duration(milliseconds: 1500));
      expect(await budgetFor(_wifi), const Duration(milliseconds: 1500));
      expect(
        await budgetFor(_cellular, gateway: 1500, explicit: const Duration(milliseconds: 800)),
        const Duration(milliseconds: 800),
      );
    });
  });

  group('the cached answer at start-up', () {
    test('carries every measured region, so the pinned rule can still keep the pinned one', () async {
      final store = GravixMemoryRegionListStore();
      Future<GravixRegionMeasurementResult> run(Map<String, int> ms) => gravixMeasureRegions(
        regionsUrl: 'https://console.example.test/v1/regions',
        fetchDirectory: (_) async => GravixRegionDirectory.fromJson({
          'regions': [
            for (final r in [sgp, blr, fra]) {'region': r.region, 'url': r.url},
          ],
        }),
        sampler: fixed(ms),
        store: store,
        networkType: _wifi,
      );
      await run({'sgp1': 56, 'blr1': 58, 'fra1': 186});
      // A new process: only the store remains. Nothing answers this time, so the
      // answer stays the one seeded from the store.
      gravixClearRegionMeasurement();
      await run({});
      final held = gravixRegionMeasurement()!;
      expect(held.bestSource, GravixRegionBestSource.cache);
      expect(held.regions.map((r) => r.region), ['sgp1', 'blr1', 'fra1']);
      // pinned blr1 (2 ms slower) is kept; with only the best seeded it was not.
      expect(gravixPickMeasuredRegion(blr.url, [sgp, blr, fra])?.region, 'blr1');
    });
  });

  group('home region (viewers)', () {
    setUp(() async {
      gravixClearRegionMeasurement();
      await measure({'sgp1': 56, 'blr1': 70, 'fra1': 186});
    });

    test('within the margin of the fastest: the home region', () {
      final p = gravixPickRegion(sgp.url, [sgp, blr, fra], homeRegion: 'blr1');
      expect(p?.entry.region, 'blr1');
      expect(p?.reason, GravixRegionPickReason.home);
    });

    test('beyond the margin: the viewer\'s own pick, even when the home url is pinned', () {
      final p = gravixPickRegion(fra.url, [sgp, blr, fra], homeRegion: 'fra1');
      expect(p?.entry.region, 'sgp1');
      expect(p?.reason, GravixRegionPickReason.measured);
    });

    test('home not measured, or not offered: as if none were given', () {
      expect(gravixPickRegion(blr.url, [sgp, blr, fra], homeRegion: 'nyc1')?.reason, GravixRegionPickReason.pinned);
      expect(gravixPickRegion(sgp.url, [sgp, fra], homeRegion: 'blr1')?.entry.region, 'sgp1');
    });

    test('no home region: unchanged behaviour', () {
      expect(gravixPickMeasuredRegion(sgp.url, [sgp, blr, fra])?.region, 'sgp1');
    });

    test('token responses: home_region parsed, garbage ignored', () {
      expect(gravixHomeRegionFrom({'home_region': 'blr1'}), 'blr1');
      expect(gravixHomeRegionFrom({'home_region': 'wss://x'}), isNull);
      expect(gravixHomeRegionFrom({'home_region': 5}), isNull);
      expect(gravixHomeRegionFrom(null), isNull);
      final creds = GravixJoinCredentials.fromResponse({
        'token': 'a.b.c',
        'url': blr.url,
        'home_region': 'blr1',
        'region_urls': [
          {'region': 'blr1', 'url': blr.url},
        ],
      });
      expect(creds.homeRegion, 'blr1');
    });
  });
}

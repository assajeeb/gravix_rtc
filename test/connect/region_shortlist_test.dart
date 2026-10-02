// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.
//
// Owner 2026-10-02: region measurement that scales to 20-50 servers in 10-20
// regions -- gateway shortlist, est_rtt_ms, rotating exploration, a total budget,
// early exit, per-network cache. The fixture is shared with the React SDK
// (test/fixtures/region_shortlist_cases.json): same fixture, same choice.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_analytics.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';

const _regionsUrl = 'https://gw.example.test/v1/regions';
final _fixture =
    json.decode(File('test/fixtures/region_shortlist_cases.json').readAsStringSync()) as Map<String, dynamic>;
List<Map<String, dynamic>> _list(String name) => [
  for (final r in (_fixture['lists'] as Map)[name] as List) Map<String, dynamic>.from(r as Map),
];
List<GravixRegionUrl> _entries(String name) => GravixRegionDirectory.fromJson({'regions': _list(name)}).regions;

Future<String?> _unknown() async => 'unknown';

/// Samples from a table: rtt[region][i] (last value repeats); null/absent = failure.
({GravixRegionSampler sampler, List<String> calls}) _table(
  Map<String, List<int?>?> rtt, {
  Duration delay = Duration.zero,
}) {
  final seen = <String, int>{};
  final calls = <String>[];
  return (
    sampler: (GravixRegionUrl r) async {
      calls.add(r.region);
      final i = seen[r.region] ?? 0;
      seen[r.region] = i + 1;
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final list = rtt[r.region];
      if (list == null) return null;
      final v = list[i < list.length ? i : list.length - 1];
      return v == null ? null : Duration(milliseconds: v);
    },
    calls: calls,
  );
}

GravixRegionDirectoryFetcher _serve(Map<String, Object?> body) =>
    (_) async => GravixRegionDirectory.fromJson(json.decode(json.encode(body)));

String _stateKey(String net) => 'gravix.regionState:$_regionsUrl:$net';

Future<Duration?> _hangs() => Completer<Duration?>().future;

void main() {
  setUp(gravixClearRegionMeasurement);

  group('parity fixture (same file in the React SDK)', () {
    for (final c in [for (final c in _fixture['cases'] as List) Map<String, dynamic>.from(c as Map)]) {
      test(c['name'] as String, () async {
        final store = GravixMemoryRegionListStore();
        final cache = c['cache'] as Map?;
        if (cache != null) {
          store.write(
            _stateKey('unknown'),
            json.encode({'known': cache['known'], 'cursor': cache['cursor'], 'measuredAtMs': 0, 'ttlMs': 1}),
          );
        }
        final response = Map<String, Object?>.from(c['response'] as Map);
        response['regions'] = _list(response['regions'] as String);
        final rtt = <String, List<int?>?>{
          for (final e in (c['rtt'] as Map).entries)
            e.key as String: e.value == null ? null : [for (final v in e.value as List) v as int?],
        };
        final t = _table(rtt);
        final result = await gravixMeasureRegions(
          regionsUrl: _regionsUrl,
          fetchDirectory: _serve(response),
          sampler: t.sampler,
          store: store,
          currentRegion: cache?['current'] as String?,
          budget: const Duration(seconds: 10),
          networkType: _unknown,
        );
        final ex = Map<String, dynamic>.from(c['expect'] as Map);
        expect(result.mode?.name, ex['mode']);
        final probed = ex['probed'] as List?;
        if (probed != null) {
          expect(t.calls.toSet(), {for (final p in probed) (p as List)[0]});
          final sources = {for (final r in result.regions) r.region: r.source.name};
          for (final p in probed) {
            expect(sources[(p as List)[0]], p[1], reason: 'source of ${p[0]}');
          }
          final plan = gravixPlanRegionCandidates(
            GravixRegionDirectory.fromJson(response),
            state: cache == null
                ? null
                : GravixRegionPlanState(
                    known: List<String>.from(cache['known'] as List),
                    cursor: cache['cursor'] as int,
                  ),
            currentRegion: cache?['current'] as String?,
          );
          expect([
            for (final p in plan.candidates) [p.entry.region, p.source.name],
          ], probed);
        }
        if (c['probedCount'] != null) expect(t.calls.toSet(), hasLength(c['probedCount']));
        expect(result.best?.region, ex['best']);
        expect(result.bestSource?.name, ex['bestSource']);
        final saved = json.decode(store.read(_stateKey('unknown'))!) as Map;
        if (ex['known'] != null) expect(saved['known'], ex['known']);
        if (ex['cursor'] != null) expect(saved['cursor'], ex['cursor']);
      });
    }

    for (final c in [for (final c in _fixture['earlyExit'] as List) Map<String, dynamic>.from(c as Map)]) {
      test('early exit: ${c['name']}', () {
        final states = [
          for (final s in c['states'] as List)
            GravixMeasureProgress(warm: List<int>.from((s as Map)['warm'] as List), done: s['done'] as bool),
        ];
        expect(gravixShouldStopMeasuring(states), c['expect']);
      });
    }

    test('network ids are hashed the same way in both SDKs (FNV-1a 32)', () {
      expect(gravixHashNetworkId('Home-WiFi 5G ✓'), '2a4558bb');
      expect(gravixRegionNetworkKey('wifi', 'Home-WiFi 5G ✓'), 'wifi:2a4558bb');
      expect(gravixRegionNetworkKey('cellular'), 'cellular');
    });
  });

  group('scale: 50 regions', () {
    test('a shortlist of 3 out of 50 probes only those (+ the held region), within the budget', () async {
      final fifty = _list('fifty');
      final t = _table({
        for (var i = 0; i < 50; i++) fifty[i]['region'] as String: [150, 40 + i, 40 + i],
      }, delay: const Duration(milliseconds: 30));
      final sw = Stopwatch()..start();
      final result = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: _serve({
          'regions': fifty,
          'shortlist': ['r07', 'r03', 'r21'],
          'probe_budget_ms': 1500,
        }),
        sampler: t.sampler,
        currentRegion: 'r40',
        store: GravixMemoryRegionListStore(),
        networkType: _unknown,
      );
      expect(t.calls.toSet(), {'r07', 'r03', 'r21', 'r40'});
      expect(result.budget, const Duration(milliseconds: 1500));
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(result.best?.region, 'r03');
    });

    test(
      'no shortlist: the first run is concurrency-capped and budget-bounded; later runs explore in rotation',
      () async {
        final store = GravixMemoryRegionListStore();
        var inFlight = 0;
        var maxInFlight = 0;
        final probedPerRun = <Set<String>>[];
        for (var run = 0; run < 3; run++) {
          final probed = <String>{};
          final sw = Stopwatch()..start();
          final result = await gravixMeasureRegions(
            regionsUrl: _regionsUrl,
            fetchDirectory: _serve({'regions': _list('fifty')}),
            store: store,
            budget: const Duration(milliseconds: 400),
            networkType: _unknown,
            sampler: (r) async {
              probed.add(r.region);
              inFlight++;
              if (inFlight > maxInFlight) maxInFlight = inFlight;
              await Future<void>.delayed(const Duration(milliseconds: 40));
              inFlight--;
              return Duration(milliseconds: 100 + int.parse(r.region.substring(1)));
            },
          );
          expect(sw.elapsed, lessThan(const Duration(milliseconds: 400 + 150)));
          probedPerRun.add(probed);
          if (run == 0) {
            expect(result.mode, GravixRegionPlanMode.all);
            expect(maxInFlight, kGravixMeasureConcurrency);
            expect(probed.length, lessThan(50));
            expect(result.budgetHit, isTrue);
            expect(
              result.regions.any((r) => r.state == GravixRegionMeasurementStatus.unmeasured && r.budgetHit),
              isTrue,
            );
          } else {
            expect(result.mode, GravixRegionPlanMode.explore);
            expect(probed, hasLength(4));
          }
          // let the cut-off samples of this run drain before the next one counts
          await Future<void>.delayed(const Duration(milliseconds: 60));
          inFlight = 0;
        }
        expect(probedPerRun[1].difference(probedPerRun[2]), isNotEmpty, reason: 'exploration moves on');
        expect(probedPerRun[1].intersection(probedPerRun[2]).length, greaterThanOrEqualTo(2));
      },
    );

    test('with est_rtt_ms and no shortlist: the 3 lowest', () async {
      final t = _table({
        'r31': [100, 40],
        'r30': [100, 35],
        'r32': [100, 80],
      });
      final result = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: _serve({'regions': _list('fiftyEst')}),
        sampler: t.sampler,
        store: GravixMemoryRegionListStore(),
        budget: const Duration(seconds: 2),
        networkType: _unknown,
      );
      expect(t.calls.toSet(), {'r31', 'r30', 'r32'});
      expect(result.mode, GravixRegionPlanMode.est);
    });
  });

  group('time: early exit and the budget', () {
    final abc = [
      for (final n in ['a', 'b', 'c']) GravixRegionUrl(region: n, url: 'wss://$n.example.test'),
    ];

    test('stops as soon as every region has a warm sample and the best clearly wins', () async {
      final t = _table({
        'a': [100, 50, 50],
        'b': [100, 200, 200],
        'c': [100, 300, 300],
      }, delay: const Duration(milliseconds: 50));
      final sw = Stopwatch()..start();
      final result = await gravixMeasureRegions(
        regionUrls: abc,
        sampler: t.sampler,
        budget: const Duration(seconds: 5),
        networkType: _unknown,
      );
      expect(result.earlyExit, isTrue);
      expect(result.budgetHit, isFalse);
      expect(result.best?.region, 'a');
      expect([for (final r in result.regions) r.samplesMs.length], [2, 2, 2]);
      expect(
        sw.elapsed,
        lessThan(const Duration(milliseconds: 200)),
      ); // the sample counts prove the exit; this only bounds it
    });

    test('a close race samples to the end (no early exit)', () async {
      final t = _table({
        'a': [100, 50, 50],
        'b': [100, 60, 60],
      });
      final result = await gravixMeasureRegions(
        regionUrls: abc.take(2).toList(),
        sampler: t.sampler,
        budget: const Duration(seconds: 5),
        networkType: _unknown,
      );
      expect(result.earlyExit, isFalse);
      expect(t.calls, hasLength(6));
    });

    test('budget expiry: returns the best so far; a region still silent is unmeasured, not failed', () async {
      final regions = [
        for (final n in ['fast', 'slow', 'dead']) GravixRegionUrl(region: n, url: 'wss://$n.example.test'),
      ];
      final sw = Stopwatch()..start();
      final result = await gravixMeasureRegions(
        regionUrls: regions,
        budget: const Duration(milliseconds: 300),
        networkType: _unknown,
        sampler: (r) async => switch (r.region) {
          'fast' => const Duration(milliseconds: 60),
          'dead' => null,
          _ => await _hangs(),
        },
      );
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 290)));
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 450)));
      expect(result.budgetHit, isTrue);
      expect(result.best?.region, 'fast');
      final by = {for (final r in result.regions) r.region: r};
      expect(by['slow']!.state, GravixRegionMeasurementStatus.unmeasured);
      expect(by['slow']!.budgetHit, isTrue);
      expect(by['slow']!.rttMs, isNull);
      expect(by['dead']!.state, GravixRegionMeasurementStatus.failed);
      expect(by['dead']!.budgetHit, isFalse);
      expect(by['fast']!.rttMs, 60);
    });

    test('the default budget: 1500 ms, 3000 ms on cellular; the gateway and the app can set it', () async {
      final one = [abc.first];
      GravixRegionSampler s() => _table({
        'a': [10, 10],
      }).sampler;
      expect(
        (await gravixMeasureRegions(regionUrls: one, sampler: s(), networkType: _unknown)).budget,
        kGravixMeasureBudget,
      );
      gravixClearRegionMeasurement();
      expect(
        (await gravixMeasureRegions(regionUrls: one, sampler: s(), networkType: () async => 'cellular')).budget,
        kGravixMeasureBudgetCellular,
      );
      final gw = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: _serve({
          'regions': [
            {'region': 'a', 'url': 'wss://a.example.test'},
          ],
          'probe_budget_ms': 800,
        }),
        sampler: s(),
        store: GravixMemoryRegionListStore(),
        networkType: _unknown,
      );
      expect(gw.budget, const Duration(milliseconds: 800));
      expect(
        (await gravixMeasureRegions(
          regionUrls: one,
          sampler: s(),
          budget: const Duration(milliseconds: 250),
          networkType: _unknown,
        )).budget,
        const Duration(milliseconds: 250),
      );
    });
  });

  group('fallbacks never move a join', () {
    final fifty = _entries('fifty');

    test('nothing measured: the guess is shortlist[0], the join keeps the token region', () async {
      final result = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: _serve({
          'regions': _list('fifty'),
          'shortlist': ['r07', 'r03'],
        }),
        sampler: _table({}).sampler,
        store: GravixMemoryRegionListStore(),
        networkType: _unknown,
      );
      expect(result.bestSource, GravixRegionBestSource.shortlist);
      expect(gravixRegionMeasurement()?.best?.region, 'r07');
      expect(gravixPickMeasuredRegion('wss://r03.example.test', fifty), isNull);
    });

    test('a guess never replaces a fresh measured answer for the same network', () async {
      final store = GravixMemoryRegionListStore();
      final serve = _serve({
        'regions': _list('fifty'),
        'shortlist': ['r07', 'r03'],
      });
      await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: serve,
        store: store,
        networkType: _unknown,
        sampler: _table({
          'r03': [90, 40],
        }).sampler,
      );
      expect(gravixRegionMeasurement()?.best?.region, 'r03');
      final second = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: serve,
        store: store,
        networkType: _unknown,
        sampler: _table({}).sampler,
      );
      expect(second.bestSource, GravixRegionBestSource.shortlist);
      expect(gravixRegionMeasurement()?.best?.region, 'r03');
      expect(gravixPickMeasuredRegion('wss://r07.example.test', fifty)?.region, 'r03');
    });
  });

  group('old gateways (regions[] only)', () {
    test('5 regions: all probed, as before; the report says mode all', () async {
      final t = _table({
        'sgp1': [190, 61, 64],
        'blr1': [210, 118, 120],
        'fra1': [500, 180],
        'nyc1': [780, 250],
        'ams3': [520, 190],
      });
      final result = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: _serve({'regions': _list('five')}),
        sampler: t.sampler,
        store: GravixMemoryRegionListStore(),
        networkType: _unknown,
      );
      expect(t.calls.toSet(), {'sgp1', 'blr1', 'fra1', 'nyc1', 'ams3'});
      expect(result.mode, GravixRegionPlanMode.all);
      expect(result.best?.region, 'sgp1');
      final report = gravixRegionsMeasuredReport(result)!;
      expect({for (final r in report['regions'] as List) (r as Map)['source']}, {'all'});
    });

    test('the pre-shortlist fetchList hook still works', () async {
      final t = _table({
        'blr1': [100, 50],
      });
      final result = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchList: (_) async => const [GravixRegionUrl(region: 'blr1', url: 'wss://blr1')],
        sampler: t.sampler,
        store: GravixMemoryRegionListStore(),
        networkType: _unknown,
      );
      expect(result.best?.region, 'blr1');
      expect(result.mode, GravixRegionPlanMode.all);
    });

    test('a saved pre-shortlist list ({regions} only) still loads', () async {
      final store = GravixMemoryRegionListStore();
      store.write('gravix.regions:$_regionsUrl', json.encode({'regions': _list('five')}));
      final result = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: (_) async => throw const SocketException('offline'),
        store: store,
        sampler: _table({
          'sgp1': [1, 1],
        }).sampler,
        networkType: _unknown,
      );
      expect(result.regions, hasLength(5));
    });
  });

  group('per-network cache', () {
    test('a known network has its answer at once, while the new measurement runs', () async {
      final store = GravixMemoryRegionListStore();
      final serve = _serve({'regions': _list('five')});
      var net = 'wifi:aaaa';
      Future<String?> key() async => net;
      await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: serve,
        store: store,
        networkKey: key,
        networkType: _unknown,
        sampler: _table({
          'sgp1': [100, 40],
          'blr1': [100, 200],
          'fra1': [100, 300],
          'nyc1': [100, 300],
          'ams3': [100, 300],
        }).sampler,
      );
      net = 'cellular';
      await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: serve,
        store: store,
        networkKey: key,
        networkType: _unknown,
        sampler: _table({
          'sgp1': [100, 200],
          'blr1': [100, 50],
          'fra1': [100, 300],
          'nyc1': [100, 300],
          'ams3': [100, 300],
        }).sampler,
      );
      expect(gravixRegionMeasurement()?.best?.region, 'blr1');

      net = 'wifi:aaaa';
      final pending = gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: serve,
        store: store,
        networkKey: key,
        networkType: _unknown,
        budget: const Duration(milliseconds: 200),
        sampler: (_) => _hangs(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // back on the Wi-Fi: its cached answer, before the new run has a number
      expect(gravixRegionMeasurement()?.bestSource, GravixRegionBestSource.cache);
      expect(gravixRegionMeasurement()?.best?.region, 'sgp1');
      expect(gravixPickMeasuredRegion('wss://sgp1.example.test', _entries('five'))?.region, 'sgp1');
      await pending;
      expect(gravixRegionMeasurement()?.best?.region, 'sgp1', reason: 'nothing measured: the cached answer stands');
    });

    test('the TTL comes from shortlist_ttl_s', () async {
      final result = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: _serve({'regions': _list('five'), 'shortlist_ttl_s': 60}),
        store: GravixMemoryRegionListStore(),
        networkType: _unknown,
        sampler: _table({
          'sgp1': [10, 10],
        }).sampler,
      );
      expect(result.ttl, const Duration(seconds: 60));
      expect(gravixRegionMeasurement(now: result.measuredAt.add(const Duration(seconds: 59))), isNotNull);
      expect(gravixRegionMeasurement(now: result.measuredAt.add(const Duration(seconds: 61))), isNull);
    });
  });

  group('reports', () {
    test('regions_measured: samples, conns, source, budget_hit per probed region', () async {
      final result = await gravixMeasureRegions(
        regionsUrl: _regionsUrl,
        fetchDirectory: _serve({
          'regions': _list('fifty'),
          'shortlist': ['r07', 'r03'],
        }),
        store: GravixMemoryRegionListStore(),
        networkType: _unknown,
        currentRegion: 'r40',
        sampler: _table({
          'r07': [300, 90, 95],
          'r03': [250, 60, 62],
        }).sampler,
      );
      final report = gravixRegionsMeasuredReport(result)!;
      expect(report['mode'], 'shortlist');
      expect(report['best'], 'r03');
      final regions = [for (final r in report['regions'] as List) Map<String, Object?>.from(r as Map)];
      expect(regions, hasLength(3));
      expect(regions.firstWhere((r) => r['region'] == 'r03'), {
        'region': 'r03',
        'rtt_ms': 60,
        'status': 'ok',
        'samples_ms': [250, 60, 62],
        'conns': null, // a stateless sampler: no connection count
        'source': 'shortlist',
        'budget_hit': false,
      });
      expect(regions.firstWhere((r) => r['region'] == 'r40')['source'], 'cache');

      final body = GravixAnalytics(url: 'https://a.example.test').buildBody(
        GravixJoinAnalyticsReport(
          connectionId: 'c',
          url: 'wss://r03.example.test',
          joinMs: 1,
          success: true,
          regionsMeasured: report,
        ),
        network: 'wifi',
      );
      expect(body['regions_measured'], same(report));
      expect(json.decode(json.encode(body))['regions_measured']['regions'], hasLength(3));
    });

    test('no report from a cached answer alone (nothing was sampled)', () {
      expect(gravixRegionsMeasuredReport(), isNull);
    });
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// S1 ordering (gravixOrderFailoverRegions), with the field numbers of
// 2026-10-09 (Bangladesh: sgp1 61 ms, blr1 ~120 ms, doh1 ~260 ms measured;
// blr1's `/settings/regions` = [doh1, sgp1, blr1]).
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_failover.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';

typedef R = ({String region, String url});

void main() {
  setUp(gravixClearRegionMeasurement);

  R r(String region) => (region: region, url: 'wss://$region.gravixcloud.run');
  List<String> order(List<R> c) =>
      gravixOrderFailoverRegions<R>(c, regionOf: (e) => e.region, urlOf: (e) => e.url).map((e) => e.region).toList();

  Future<void> measure(Map<String, int?> rtts) => gravixMeasureRegions(
    regionUrls: [for (final k in rtts.keys) GravixRegionUrl(region: k, url: 'wss://$k.gravixcloud.run')],
    sampler: (g) async => rtts[g.region] == null ? null : Duration(milliseconds: rtts[g.region]!),
  );

  test('near-only cap: max(2 x best, best + 100 ms)', () {
    expect(gravixNearOnlyCapMs(61), 161);
    expect(gravixNearOnlyCapMs(150), 300);
    expect(gravixNearOnlyCapMs(0), 100);
  });

  test('field case: from blr1, sgp1 first, doh1 only after it', () async {
    await measure({'sgp1': 61, 'blr1': 120, 'doh1': 260});
    expect(order([r('doh1'), r('sgp1')]), ['sgp1', 'doh1']);
  });

  test('the cap is taken against the best REMAINING candidate', () async {
    // sgp1 (the best) failed already; blr1 120 is now the best: doh1 260 > 240 still far
    await measure({'sgp1': 61, 'blr1': 120, 'doh1': 260});
    expect(order([r('doh1'), r('blr1')]), ['blr1', 'doh1']);
    // with only a far one left it is still offered: the server list is the last resort
    expect(order([r('doh1')]), ['doh1']);
  });

  test('unmeasured regions after the near ones, before the far ones; failed ones last', () async {
    await measure({'sgp1': 61, 'doh1': 260, 'fra1': null});
    expect(order([r('fra1'), r('doh1'), r('ams1'), r('sgp1')]), ['sgp1', 'ams1', 'doh1', 'fra1']);
  });

  test('no fresh measurement: the server order unchanged', () {
    expect(order([r('doh1'), r('sgp1'), r('blr1')]), ['doh1', 'sgp1', 'blr1']);
  });

  test('url matching: a candidate is found by its url when the slugs differ', () async {
    await measure({'sgp1': 61, 'doh1': 260});
    final c = <R>[
      (region: 'gulf', url: 'wss://doh1.gravixcloud.run/'),
      (region: 'asia', url: 'WSS://SGP1.gravixcloud.run'),
    ];
    expect(order(c), ['asia', 'gulf']);
  });

  test('gravixRegionOfUrl: known list first, then the measurement', () async {
    await measure({'sgp1': 61});
    expect(gravixRegionOfUrl('wss://sgp1.gravixcloud.run/'), 'sgp1');
    expect(
      gravixRegionOfUrl(
        'wss://x.example',
        known: const [GravixRegionUrl(region: 'x1', url: 'wss://x.example')],
      ),
      'x1',
    );
    expect(gravixRegionOfUrl('wss://nowhere.example'), isNull);
  });
}

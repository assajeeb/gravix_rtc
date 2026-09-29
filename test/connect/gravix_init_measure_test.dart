import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';

// Parity with React 0.4.0/0.5.0 (2026-09-27): the SDK measures the regions when the
// app starts and joins the fastest directly -- no probe on the join path -- also
// with a token minted by the app's own backend, which carries no region list.

const blr = GravixRegionUrl(region: 'blr1', url: 'wss://rtc-blr1.example.com');
const sgp = GravixRegionUrl(region: 'sgp1', url: 'wss://rtc-sgp1.example.com');
const nyc = GravixRegionUrl(region: 'nyc1', url: 'wss://rtc-nyc1.example.com');

/// A sampler where each region answers in a fixed time; the first sample of each
/// region is slower (DNS+TCP+TLS) and must be dropped.
GravixRegionSampler fixed(Map<String, int> ms, {Set<String> down = const {}}) {
  final seen = <String>{};
  return (GravixRegionUrl r) async {
    if (down.contains(r.region)) return null;
    final first = seen.add(r.region);
    return Duration(milliseconds: ms[r.region]! + (first ? 500 : 0));
  };
}

void main() {
  setUp(gravixClearRegionMeasurement);

  test('drops the first sample, keeps the minimum, fastest first', () async {
    final result = await gravixMeasureRegions(
      regionUrls: [blr, sgp, nyc],
      sampler: fixed({'blr1': 330, 'sgp1': 360, 'nyc1': 120}),
    );
    expect(result.best?.region, 'nyc1');
    expect(result.best?.rttMs, 120);
    expect(result.regions.map((r) => r.region), ['nyc1', 'blr1', 'sgp1']);
  });

  test('a region that does not answer is marked unreachable and sorted last', () async {
    final result = await gravixMeasureRegions(
      regionUrls: [blr, sgp],
      sampler: fixed({'blr1': 40, 'sgp1': 90}, down: {'blr1'}),
    );
    expect(result.best?.region, 'sgp1');
    expect(result.regions.last.region, 'blr1');
    expect(result.regions.last.ok, isFalse);
  });

  test('the held region stays unless a rival is clearly faster (no flapping)', () async {
    await gravixMeasureRegions(regionUrls: [blr, sgp], sampler: fixed({'blr1': 100, 'sgp1': 120}));
    final again = await gravixMeasureRegions(regionUrls: [blr, sgp], sampler: fixed({'blr1': 110, 'sgp1': 100}));
    expect(again.best?.region, 'blr1', reason: '10 ms is noise, not a reason to move');
  });

  test('picks the fastest measured region the room offers', () async {
    await gravixMeasureRegions(regionUrls: [blr, sgp, nyc], sampler: fixed({'blr1': 330, 'sgp1': 360, 'nyc1': 120}));
    expect(gravixPickMeasuredRegion(blr.url, [blr, sgp])?.region, 'blr1');
    expect(gravixPickMeasuredRegion(blr.url, [blr, sgp, nyc])?.region, 'nyc1');
  });

  test('the pinned (token) region is kept unless the pick is clearly faster (field 2026-09-30)', () async {
    // first measurement of the process: nothing held, blr1 is the raw best
    await gravixMeasureRegions(regionUrls: [blr, sgp], sampler: fixed({'blr1': 167, 'sgp1': 180}));
    expect(gravixPickMeasuredRegion(sgp.url, [blr, sgp])?.region, 'sgp1', reason: '13 ms is noise');
    expect(gravixPickMeasuredRegion(blr.url, [blr, sgp])?.region, 'blr1');
  });

  test('the pinned region clearly slower, or not answering: the measured pick', () async {
    await gravixMeasureRegions(regionUrls: [blr, sgp], sampler: fixed({'blr1': 100, 'sgp1': 180}));
    expect(gravixPickMeasuredRegion(sgp.url, [blr, sgp])?.region, 'blr1', reason: '80 ms and 44 % faster');
    await gravixMeasureRegions(
      regionUrls: [blr, sgp],
      sampler: fixed({'blr1': 100, 'sgp1': 90}, down: {'sgp1'}),
    );
    expect(gravixPickMeasuredRegion(sgp.url, [blr, sgp])?.region, 'blr1');
  });

  test('nothing measured, or stale: no pick', () async {
    expect(gravixPickMeasuredRegion(blr.url, [blr, sgp]), isNull);
    await gravixMeasureRegions(regionUrls: [blr], sampler: fixed({'blr1': 50}));
    final later = DateTime.now().add(const Duration(minutes: 11));
    expect(gravixPickMeasuredRegion(blr.url, [blr], now: later), isNull);
  });

  test('a token with no region list: the measured regions are the candidates', () async {
    await gravixMeasureRegions(regionUrls: [blr, sgp, nyc], sampler: fixed({'blr1': 330, 'sgp1': 360, 'nyc1': 120}));
    final candidates = gravixMeasuredCandidates(blr.url);
    expect(candidates.map((c) => c.region), ['nyc1', 'blr1', 'sgp1']);
    expect(gravixPickMeasuredRegion(blr.url, candidates)?.region, 'nyc1');
    expect(
      gravixMeasuredCandidates('wss://my-own-server.example.org'),
      isEmpty,
      reason: 'never redirect a url outside the measured set',
    );
  });

  test('a failed list fetch uses the last list this device saw', () async {
    final store = GravixMemoryRegionListStore();
    var fail = false;
    Future<List<GravixRegionUrl>> fetchList(String url) async {
      if (fail) throw StateError('offline');
      return [blr, sgp];
    }

    final first = await gravixMeasureRegions(
      regionsUrl: 'https://console.example.com/v1/regions',
      fetchList: fetchList,
      store: store,
      sampler: fixed({'blr1': 40, 'sgp1': 90}),
    );
    expect(first.regions.length, 2);
    fail = true;
    final second = await gravixMeasureRegions(
      regionsUrl: 'https://console.example.com/v1/regions',
      fetchList: fetchList,
      store: store,
      sampler: fixed({'blr1': 40, 'sgp1': 90}),
    );
    expect(second.regions.length, 2);
    expect(second.error, isNull);
  });

  test('never throws: no list and nothing saved gives an empty result with the error', () async {
    final r = await gravixMeasureRegions(
      regionsUrl: 'https://x.example.com/v1/regions',
      fetchList: (_) async => throw StateError('offline'),
      sampler: fixed({}),
    );
    expect(r.best, isNull);
    expect(r.error, contains('offline'));
  });
}

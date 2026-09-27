// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:shared_preferences/shared_preferences.dart';

const regionsUrl = 'https://console.example.com/v1/regions';
const key = 'gravix.regions:$regionsUrl';
const blr = GravixRegionUrl(region: 'blr1', url: 'wss://rtc-blr1.example.com');
const sgp = GravixRegionUrl(region: 'sgp1', url: 'wss://rtc-sgp1.example.com');

Future<Duration?> fast(GravixRegionUrl r) async => Duration(milliseconds: r.region == 'blr1' ? 20 : 80);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    gravixClearRegionMeasurement();
    gravixResetDefaultRegionListStore();
  });

  test('GravixSharedPrefsRegionListStore round-trips through shared preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final a = await GravixSharedPrefsRegionListStore.create();
    expect(a.read(key), isNull);
    a.write(key, '{"regions":[]}');
    await Future<void>.delayed(Duration.zero);
    // A second instance (≈ the next launch) sees it.
    final prefs = await SharedPreferences.getInstance();
    expect(GravixSharedPrefsRegionListStore(prefs).read(key), '{"regions":[]}');
  });

  test('a non-string value under the key reads as absent', () async {
    SharedPreferences.setMockInitialValues({key: 7});
    expect((await GravixSharedPrefsRegionListStore.create()).read(key), isNull);
  });

  test('start-up measurement persists the fetched list by default', () async {
    SharedPreferences.setMockInitialValues({});
    final h = gravixStartRegionMeasurement(
      regionsUrl: regionsUrl,
      refresh: Duration.zero,
      watchNetwork: false,
      sampler: fast,
      fetchList: (_) async => const [blr, sgp],
    );
    expect((await h.ready).best?.region, 'blr1');
    h.stop();
    await Future<void>.delayed(Duration.zero);
    final saved = (await SharedPreferences.getInstance()).getString(key);
    expect(saved, isNotNull);
    expect((jsonDecode(saved!) as Map)['regions'], hasLength(2));
  });

  test('a cold start with the gateway down measures the list saved by an earlier launch', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode({
        'regions': [
          {'region': 'blr1', 'url': blr.url},
          {'region': 'sgp1', 'url': sgp.url},
        ],
      }),
    });
    final h = gravixStartRegionMeasurement(
      regionsUrl: regionsUrl,
      refresh: Duration.zero,
      watchNetwork: false,
      sampler: fast,
      fetchList: (_) async => throw StateError('gateway unreachable'),
    );
    final result = await h.ready;
    h.stop();
    expect(result.error, isNull);
    expect(result.best?.region, 'blr1');
  });

  test('an explicit store still wins over the default', () async {
    SharedPreferences.setMockInitialValues({});
    final mem = GravixMemoryRegionListStore();
    final h = gravixStartRegionMeasurement(
      regionsUrl: regionsUrl,
      refresh: Duration.zero,
      watchNetwork: false,
      store: mem,
      sampler: fast,
      fetchList: (_) async => const [blr],
    );
    await h.ready;
    h.stop();
    expect(mem.read(key), isNotNull);
    expect((await SharedPreferences.getInstance()).getString(key), isNull);
  });
}

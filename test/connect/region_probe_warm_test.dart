// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_probe_client.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';

/// Field 2026-10-01 (Bangladesh, one phone, one Wi-Fi): Android tester 0.3.4
/// measured sgp1 190-265 / blr1 200-333 ms and flip-flopped between them, while
/// the web tester on the same phone measured sgp1 61 / blr1 116-122 every time.
/// `sdkHttpGet` opened and closed a client per request, so every "warm" sample
/// paid DNS + TCP + TLS + HTTP again (3-4 RTT). These tests pin the fix: one
/// keep-alive connection per region for the whole measurement, regions measured
/// in parallel.

/// A local "region": answers the probe endpoint with its name and counts the
/// TCP connections it was asked on (remote ports seen).
class _Region {
  _Region(this.name, {this.delay = Duration.zero, this.answerAs});
  final String name;
  final Duration delay;
  final String? answerAs;
  late final HttpServer server;
  final ports = <int>{};
  final methods = <String>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      ports.add(req.connectionInfo!.remotePort);
      methods.add(req.method);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      req.response.headers.contentType = ContentType.json;
      req.response.write(json.encode({'region': answerAs ?? name}));
      await req.response.close();
    });
  }

  GravixRegionUrl get entry => GravixRegionUrl(
    region: name,
    url: 'ws://127.0.0.1:${server.port}',
    probeUrl: 'http://127.0.0.1:${server.port}/probe',
  );

  GravixRegionUrl get headOnly => GravixRegionUrl(region: name, url: 'ws://127.0.0.1:${server.port}');

  Future<void> stop() => server.close(force: true);
}

Future<_Region> _region(String name, {Duration delay = Duration.zero, String? answerAs}) async {
  final r = _Region(name, delay: delay, answerAs: answerAs);
  await r.start();
  addTearDown(r.stop);
  return r;
}

void main() {
  setUp(gravixClearRegionMeasurement);

  group('connection reuse', () {
    test('the default measurement opens ONE connection per region for all its samples', () async {
      final blr = await _region('blr1');
      final sgp = await _region('sgp1');
      final result = await gravixMeasureRegions(regionUrls: [blr.entry, sgp.entry]);
      expect(blr.methods, hasLength(kGravixMeasureSamples));
      expect(sgp.methods, hasLength(kGravixMeasureSamples));
      expect(blr.ports, hasLength(1), reason: 'samples 2..N must reuse the first sample\'s connection');
      expect(sgp.ports, hasLength(1));
      for (final r in result.regions) {
        expect(r.ok, isTrue);
        expect(r.connections, 1, reason: 'the client-side count agrees with the server');
      }
    });

    test('the HEAD path (no probe endpoint) reuses its connection too', () async {
      final blr = await _region('blr1');
      final result = await gravixMeasureRegions(regionUrls: [blr.headOnly]);
      expect(blr.methods, everyElement('HEAD'));
      // a lone region stops at its first warm sample (early exit, 2026-10-02):
      // nothing to compare it with
      expect(blr.methods.length, inInclusiveRange(2, kGravixMeasureSamples));
      expect(blr.ports, hasLength(1));
      expect(result.regions.single.connections, 1);
    });

    test('GravixRegionProbeClient: N requests, one socket; closed means closed', () async {
      final blr = await _region('blr1');
      final client = GravixRegionProbeClient();
      for (var i = 0; i < 5; i++) {
        expect(await client.verifiedProbe(blr.entry.probeUrl!), 'blr1');
      }
      expect(client.connections, 1);
      expect(blr.ports, hasLength(1));
      client.close();
      expect(client.isClosed, isTrue);
      await expectLater(client.verifiedProbe(blr.entry.probeUrl!), throwsA(anything));
    });

    test('each region gets its own client, closed once the region is measured', () async {
      final blr = await _region('blr1');
      final sgp = await _region('sgp1');
      final clients = <GravixRegionProbeClient>[];
      await gravixMeasureRegions(
        regionUrls: [blr.entry, sgp.entry],
        samplerFor: (client) {
          clients.add(client);
          return gravixDefaultRegionSampler(client);
        },
      );
      expect(clients, hasLength(2));
      expect(clients.toSet(), hasLength(2));
      expect(clients.every((c) => c.isClosed), isTrue);
    });

    test('a region answering as another region still never wins (verified probe kept)', () async {
      final blr = await _region('blr1', answerAs: 'fra1');
      final sgp = await _region('sgp1');
      final result = await gravixMeasureRegions(regionUrls: [blr.entry, sgp.entry]);
      expect(result.best?.region, 'sgp1');
      final b = result.regions.firstWhere((r) => r.region == 'blr1');
      expect(b.ok, isFalse);
      // a failed FIRST request is retried once (a lost SYN on a lossy link), then
      // the region stops (2026-10-02, parity with React)
      expect(blr.methods, hasLength(2), reason: 'a region stops at its first failure after the one retry');
    });

    test('a timed-out sample fails the region within the timeout', () async {
      final slow = await _region('nyc1', delay: const Duration(seconds: 3));
      final fast = await _region('sgp1');
      final sw = Stopwatch()..start();
      final result = await gravixMeasureRegions(regionUrls: [slow.entry, fast.entry]);
      expect(sw.elapsed, lessThan(kGravixMeasureTimeout + const Duration(milliseconds: 800)));
      expect(result.regions.firstWhere((r) => r.region == 'nyc1').ok, isFalse);
      expect(result.best?.region, 'sgp1');
    });
  });

  group('sample selection', () {
    test('cold first sample dropped, RTT = minimum of the warm ones, samplesMs kept', () async {
      final calls = <String, int>{};
      final result = await gravixMeasureRegions(
        regionUrls: const [
          GravixRegionUrl(region: 'blr1', url: 'wss://blr1'),
          GravixRegionUrl(region: 'sgp1', url: 'wss://sgp1'),
        ],
        samplerFor: (client) => (r) async {
          final i = calls[r.region] = (calls[r.region] ?? 0) + 1;
          const plan = {
            // close enough (20 ms) that the early exit does not cut the samples
            'blr1': [480, 90, 85],
            'sgp1': [300, 70, 64],
          };
          return Duration(milliseconds: plan[r.region]![i - 1]);
        },
      );
      expect(result.best?.region, 'sgp1');
      final s = result.regions.firstWhere((r) => r.region == 'sgp1');
      expect(s.samplesMs, [300, 70, 64]);
      expect(s.rttMs, 64, reason: 'not the cold 300');
      final b = result.regions.firstWhere((r) => r.region == 'blr1');
      expect(b.samplesMs, [480, 90, 85]);
      expect(b.rttMs, 85);
    });

    test('field 2026-10-01 shape: cold-inflated numbers no longer decide, warm ones do', () async {
      // blr1's cold handshake happened to be faster than sgp1's; the warm round
      // trips say sgp1. Old code (every sample cold) picked blr1 on ~200 vs ~265.
      final calls = <String, int>{};
      final result = await gravixMeasureRegions(
        regionUrls: const [
          GravixRegionUrl(region: 'blr1', url: 'wss://blr1'),
          GravixRegionUrl(region: 'sgp1', url: 'wss://sgp1'),
        ],
        samplerFor: (client) => (r) async {
          final i = calls[r.region] = (calls[r.region] ?? 0) + 1;
          const plan = {
            'blr1': [212, 118, 116, 121],
            'sgp1': [265, 63, 61, 66],
          };
          return Duration(milliseconds: plan[r.region]![i - 1]);
        },
      );
      expect(result.best?.region, 'sgp1');
      // 63 vs 118 after one warm sample each: a clear win, so the measurement
      // stopped there (early exit, 2026-10-02) instead of taking 61 next
      expect(result.best?.rttMs, 63);
      expect(result.earlyExit, isTrue);
    });
  });

  group('parallelism', () {
    test('regions are measured at the same time; samples within a region never overlap', () async {
      final inFlight = <String, int>{};
      var maxRegionsInFlight = 0;
      var maxPerRegion = 0;
      final regions = [
        for (final n in ['blr1', 'sgp1', 'fra1', 'nyc1', 'doh1']) GravixRegionUrl(region: n, url: 'wss://$n'),
      ];
      final result = await gravixMeasureRegions(
        regionUrls: regions,
        samplerFor: (client) => (r) async {
          inFlight[r.region] = (inFlight[r.region] ?? 0) + 1;
          maxPerRegion = [maxPerRegion, inFlight[r.region]!].reduce((a, b) => a > b ? a : b);
          final active = inFlight.values.where((v) => v > 0).length;
          if (active > maxRegionsInFlight) maxRegionsInFlight = active;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          inFlight[r.region] = inFlight[r.region]! - 1;
          return const Duration(milliseconds: 40);
        },
      );
      expect(maxRegionsInFlight, regions.length);
      expect(maxPerRegion, 1);
      expect(result.regions.every((r) => r.ok), isTrue);
    });

    test('total time is the slowest region, not the sum (5 regions x 3 samples x 100 ms)', () async {
      final regions = [
        for (final n in ['blr1', 'sgp1', 'fra1', 'nyc1', 'doh1']) GravixRegionUrl(region: n, url: 'wss://$n'),
      ];
      final result = await gravixMeasureRegions(
        regionUrls: regions,
        samplerFor: (client) => (r) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return const Duration(milliseconds: 100);
        },
      );
      // sequential = 1.5 s; parallel = ~0.3 s (equal RTTs: no early exit)
      expect(result.elapsed, isNotNull);
      expect(result.elapsed!, lessThan(const Duration(milliseconds: 1000)));
      expect(result.elapsed!, greaterThanOrEqualTo(const Duration(milliseconds: 300)));
    });

    test('real sockets: 3 local regions in parallel, one connection each', () async {
      final rs = [
        for (final n in ['blr1', 'sgp1', 'fra1']) await _region(n, delay: const Duration(milliseconds: 60)),
      ];
      final result = await gravixMeasureRegions(regionUrls: [for (final r in rs) r.entry]);
      for (final r in rs) {
        expect(r.ports, hasLength(1), reason: r.name);
      }
      // sequential would be 3 x 4 x 60 = 720 ms at the least
      expect(result.elapsed!, lessThan(const Duration(milliseconds: 600)));
    });
  });
}

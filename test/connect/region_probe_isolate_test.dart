// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart' show GravixRegionLog;
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_region_sampler_isolate.dart';

/// 0.9.1 (field 2026-11-08, Tuki app, Redmi, same Wi-Fi, cold starts): dac1 is 5-20 ms
/// away (ICE RTT), but start-up measurements read dac1 64 / 10 / 7 / 54 / 85 / 120 ms,
/// once the order flipped (blr1 61 / sgp1 77 / dac1 85), once every region timed out at
/// the 1.5 s budget. The stopwatch ran on the app's isolate, busy with start-up: each
/// sample included the wait for the event loop. These tests block the test's isolate
/// in 300 ms chunks, like a start-up does, while a region answers at once.

/// A "region" served from ITS OWN isolate, so a blocked test isolate does not
/// delay the answers (only the measurement may be delayed by it).
class _IsolateRegion {
  _IsolateRegion(this.name);
  final String name;
  late final Isolate _iso;
  late final int port;

  static Future<_IsolateRegion> start(String name) async {
    final r = _IsolateRegion(name);
    final rx = ReceivePort();
    r._iso = await Isolate.spawn<List<Object>>(_serve, [rx.sendPort, name]);
    r.port = await rx.first as int;
    addTearDown(() => r._iso.kill(priority: Isolate.immediate));
    return r;
  }

  GravixRegionUrl get entry =>
      GravixRegionUrl(region: name, url: 'ws://127.0.0.1:$port', probeUrl: 'http://127.0.0.1:$port/probe');
}

Future<void> _serve(List<Object> args) async {
  final reply = args[0] as SendPort;
  final name = args[1] as String;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.headers.contentType = ContentType.json;
    req.response.write(json.encode({'region': name}));
    await req.response.close();
  });
  reply.send(server.port);
}

/// A region on the test's isolate: [delay] before each answer; counts requests.
class _Region {
  _Region(this.name, {this.delay = Duration.zero, this.answerAs});
  final String name;
  final Duration delay;
  final String? answerAs;
  late final HttpServer server;
  final methods = <String>[];
  var closedEarly = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      methods.add(req.method);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      try {
        req.response.headers.contentType = ContentType.json;
        req.response.write(json.encode({'region': answerAs ?? name}));
        await req.response.close();
      } catch (_) {
        closedEarly++;
      }
    });
  }

  GravixRegionUrl get entry => GravixRegionUrl(
    region: name,
    url: 'ws://127.0.0.1:${server.port}',
    probeUrl: 'http://127.0.0.1:${server.port}/probe',
  );

  Future<void> stop() => server.close(force: true);
}

Future<_Region> _region(String name, {Duration delay = Duration.zero, String? answerAs}) async {
  final r = _Region(name, delay: delay, answerAs: answerAs);
  await r.start();
  addTearDown(r.stop);
  return r;
}

/// Runs [run] while this isolate is blocked in [chunk] busy loops, one event-loop
/// turn between them, until it completes.
Future<T> _underJank<T>(Future<T> Function() run, {Duration chunk = const Duration(milliseconds: 300)}) async {
  var done = false;
  final f = run().whenComplete(() => done = true);
  final total = Stopwatch()..start();
  while (!done && total.elapsed < const Duration(seconds: 10)) {
    final sw = Stopwatch()..start();
    while (sw.elapsed < chunk) {}
    await Future<void>.delayed(Duration.zero);
  }
  return f;
}

/// The helper isolate exits just after the run returns (its exit is an event).
Future<void> _isolatesGone() async {
  final sw = Stopwatch()..start();
  while (GravixRegionMeasureIsolate.debugLiveRuns > 0 && sw.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(GravixRegionMeasureIsolate.debugLiveRuns, 0, reason: 'the helper isolate exits after its run');
}

void main() {
  final lines = <String>[];
  setUp(() {
    gravixClearRegionMeasurement();
    lines.clear();
    GravixRegionLog.sink = lines.add;
  });
  tearDown(() {
    GravixRegionLog.sink = null;
    GravixRegionMeasureIsolate.enabled = true;
    GravixRegionMeasureIsolate.debugSpawnError = null;
  });

  test('a busy app isolate does not inflate the default measurement (isolate) but does on the main path', () async {
    final dac = await _IsolateRegion.start('dac1');
    final sgp = await _IsolateRegion.start('sgp1');
    final regions = [dac.entry, sgp.entry];

    final iso = await _underJank(() => gravixMeasureRegions(regionUrls: regions, budget: const Duration(seconds: 3)));
    gravixClearRegionMeasurement();
    GravixRegionMeasureIsolate.enabled = false; // the 0.9.0 sampler (and the rollback)
    final main = await _underJank(() => gravixMeasureRegions(regionUrls: regions, budget: const Duration(seconds: 3)));

    String show(GravixRegionMeasurementResult r) =>
        r.regions.map((m) => '${m.region}=${m.rttMs} ${m.samplesMs}').join(', ');
    // ignore: avoid_print
    print('under 300 ms jank: isolate ${show(iso)} | main ${show(main)}');

    expect(iso.budgetHit, isFalse);
    for (final m in iso.regions) {
      expect(m.ok, isTrue, reason: m.region);
      expect(m.rttMs, lessThan(50), reason: 'isolate ${m.region}: ${m.samplesMs}');
      expect(m.connections, 1, reason: 'the warm samples reuse the cold sample\'s connection');
    }
    expect(lines.where((l) => l.contains(' sample ') && l.endsWith('via=isolate')), hasLength(2), reason: '$lines');

    // The old path: every sample waits for the blocked isolate.
    final mainRtts = [
      for (final m in main.regions)
        if (m.ok) m.rttMs!,
    ];
    expect(
      main.regions.every((m) => !m.ok) || mainRtts.reduce((a, b) => a > b ? a : b) >= 100,
      isTrue,
      reason: 'main path ${show(main)}',
    );
    expect(lines.where((l) => l.contains(' sample ') && l.contains('via=main')), isNotEmpty);
  });

  group('isolate sampler', () {
    test('logs one sample line per region and a select line', () async {
      final blr = await _region('blr1');
      final sgp = await _region('sgp1');
      final result = await gravixMeasureRegions(regionUrls: [blr.entry, sgp.entry]);
      expect(result.best, isNotNull);
      final samples = lines.where((l) => l.startsWith('[GravixRegion] sample ')).toList();
      expect(samples, hasLength(2), reason: '$lines');
      for (final l in samples) {
        expect(l, matches(RegExp(r'^\[GravixRegion\] sample region=(blr1|sgp1) warm=\[\d+,\d+\] cold=\d+ status=ok')));
        expect(l, endsWith('via=isolate'));
      }
      expect(lines.where((l) => l.startsWith('[GravixRegion] select -> ')), hasLength(1), reason: '$lines');
    });

    test('a region naming another region is not measured (verification kept)', () async {
      final blr = await _region('blr1', answerAs: 'sgp1');
      final result = await gravixMeasureRegions(regionUrls: [blr.entry]);
      final m = result.regions.single;
      expect(m.ok, isFalse);
      expect(m.state, GravixRegionMeasurementStatus.failed);
      expect(m.retried, isTrue, reason: 'a first failure is asked again, as on the main path');
    });

    test('budget cut: a slow region is unmeasured, the run ends at the budget, logs say so', () async {
      final slow = await _region('fra1', delay: const Duration(seconds: 2));
      final sw = Stopwatch()..start();
      final result = await gravixMeasureRegions(regionUrls: [slow.entry], budget: const Duration(milliseconds: 400));
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1200)));
      expect(result.budgetHit, isTrue);
      expect(result.regions.single.state, GravixRegionMeasurementStatus.unmeasured);
      expect(result.regions.single.budgetHit, isTrue);
      expect(
        lines.where((l) => l.startsWith('[GravixRegion] sample region=fra1 warm=[] cold=- status=unmeasured')),
        hasLength(1),
        reason: '$lines',
      );
      final select = lines.where((l) => l.startsWith('[GravixRegion] select -> ')).toList();
      expect(select, hasLength(1), reason: '$lines');
      expect(select.single, contains('why=budget'));
    });

    test('early stop cancels the slower region: no request after the run ends', () async {
      final fast = await _region('dac1');
      final slow = await _region('fra1', delay: const Duration(milliseconds: 150));
      final result = await gravixMeasureRegions(
        regionUrls: [fast.entry, slow.entry],
        budget: const Duration(seconds: 3),
      );
      expect(result.earlyExit, isTrue);
      expect(result.best?.region, 'dac1');
      // A request the isolate had sent before the stop reached it may still land; after
      // the isolate is gone nothing more does.
      await _isolatesGone();
      final after = slow.methods.length;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(slow.methods.length, after, reason: 'the helper isolate stopped sampling at the end of the run');
      expect(after, lessThanOrEqualTo(kGravixMeasureSamples));
    });

    test('the helper isolate is gone after every run', () async {
      final blr = await _region('blr1');
      for (var i = 0; i < 3; i++) {
        gravixClearRegionMeasurement();
        await gravixMeasureRegions(regionUrls: [blr.entry]);
      }
      await _isolatesGone();
    });

    test('an isolate that cannot start: the main-isolate sampler measures, and says why', () async {
      GravixRegionMeasureIsolate.debugSpawnError = StateError('no isolates here');
      final blr = await _region('blr1');
      final result = await gravixMeasureRegions(regionUrls: [blr.entry]);
      expect(result.best?.region, 'blr1');
      expect(result.regions.single.ok, isTrue);
      expect(result.regions.single.connections, 1);
      expect(
        lines.where((l) => l.startsWith('[GravixRegion] sampler via=main cause=isolate-failed')),
        hasLength(1),
        reason: '$lines',
      );
      expect(
        lines.where((l) => l.startsWith('[GravixRegion] sample region=blr1') && l.endsWith('via=main')),
        hasLength(1),
      );
    });

    test('an injected samplerFor keeps the main isolate (test and app seam)', () async {
      final blr = await _region('blr1');
      var made = 0;
      final result = await gravixMeasureRegions(
        regionUrls: [blr.entry],
        samplerFor: (c) {
          made++;
          return gravixDefaultRegionSampler(c);
        },
      );
      expect(made, 1);
      expect(result.regions.single.ok, isTrue);
      expect(lines.where((l) => l.contains(' sample ') && l.endsWith('via=main')), hasLength(1));
    });

    test('a select line is logged when nothing answered', () async {
      final dead = GravixRegionUrl(region: 'x1', url: 'ws://127.0.0.1:1', probeUrl: 'http://127.0.0.1:1/probe');
      final result = await gravixMeasureRegions(regionUrls: [dead], budget: const Duration(milliseconds: 800));
      expect(result.best?.ok ?? false, isFalse);
      expect(lines.where((l) => l.startsWith('[GravixRegion] select -> ')), hasLength(1), reason: '$lines');
    });
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Owner rule (2026-10-10): no fix may add meaningful CPU or slow the join. The
// 0.4.15 recovery work on the client's hot paths, measured on this machine:
//  - the stall watch runs once per receiver-stats poll (every 2 s per track);
//  - the failover ordering runs only after a failed connect;
//  - the connected-region lookup runs once per connect / rejoin.
// Bounds are generous (CI machines vary); the printed numbers go in the report.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_failover.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_media_watchdog.dart';
import 'package:gravix_rtc/src/rtc_core/src/gravix_recovery_options.dart';

double _usPerOp(int n, void Function(int i) op) {
  for (var i = 0; i < n ~/ 10; i++) {
    op(i); // warm up
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    op(i);
  }
  sw.stop();
  return sw.elapsedMicroseconds / n;
}

void main() {
  test('stall watch: one stats sample (20 subscribed tracks)', () {
    var t = DateTime(2026);
    final w = GravixVideoStallWatch(options: const GravixRecoveryOptions(), clock: () => t);
    final us = _usPerOp(200000, (i) {
      t = t.add(const Duration(milliseconds: 100));
      w.sample('TR_${i % 20}', video: i.isEven, eligible: true, packetsReceived: i, framesDecoded: i);
    });
    // ignore: avoid_print
    print('RESULT stall_watch_sample_us=${us.toStringAsFixed(3)}');
    expect(us, lessThan(50));
  });

  test('failover ordering of 50 regions with a fresh measurement', () async {
    final regions = [for (var i = 0; i < 50; i++) GravixRegionUrl(region: 'r$i', url: 'wss://r$i.gravixcloud.run')];
    await gravixMeasureRegions(
      regionUrls: regions,
      sampler: (r) async => Duration(milliseconds: 20 + regions.indexOf(r) * 7),
    );
    final us = _usPerOp(
      2000,
      (_) => gravixOrderFailoverRegions(regions, regionOf: (e) => e.region, urlOf: (e) => e.url),
    );
    final lookup = _usPerOp(20000, (i) => gravixRegionOfUrl('wss://r${i % 50}.gravixcloud.run/'));
    // ignore: avoid_print
    print('RESULT failover_order_50_us=${us.toStringAsFixed(1)} region_lookup_us=${lookup.toStringAsFixed(2)}');
    expect(us, lessThan(5000));
    expect(lookup, lessThan(500));
  });
}

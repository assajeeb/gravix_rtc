// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// S1, field 2026-10-09 (Pakhi, a viewer in Bangladesh): a failed full reconnect
// on blr1 moved the session to doh1 (284 ms) for the rest of its life, because
// the core's cloud failover dialled the first untried entry of the SFU's
// `/settings/regions` (the other regions in configuration order: doh1 first).
// The app's start-up measurement had sgp1 at ~61 ms.
//
// Now (GravixRecoveryOptions.measuredRegionFailover / retrySameUrlFirst): the
// failed url is retried once with a short dial, then the regions go in measured
// order with the near-only cap; the server's order is the last resort.
import 'dart:async';
import 'dart:io' show HttpClient, HttpOverrides, SecurityContext, SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:fixnum/fixnum.dart';

import '../support/fake_rtc.dart';

/// The unreachable host's validate request fails like a dead path (the test
/// binding would answer every request 400, which reads as a refusal).
class _Offline extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw const SocketException('offline');
}

const blr = 'wss://blr1.gravixcloud.run';
const sgp = 'wss://sgp1.gravixcloud.run';
const doh = 'wss://doh1.gravixcloud.run';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    gravixClearRegionMeasurement();
    HttpOverrides.global = _Offline();
  });
  tearDown(() => HttpOverrides.global = null);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late Engine engine;
  tearDown(() async => engine.dispose());

  Future<void> measure() => gravixMeasureRegions(
    regionUrls: const [
      GravixRegionUrl(region: 'sgp1', url: sgp),
      GravixRegionUrl(region: 'blr1', url: blr),
      GravixRegionUrl(region: 'doh1', url: doh),
    ],
    sampler: (r) async => Duration(milliseconds: const {'sgp1': 61, 'blr1': 120, 'doh1': 260}[r.region]!),
  );

  // blr1's `/settings/regions`: the other regions in configuration order (doh1,
  // the canary, first), its own region last
  RegionUrlProvider provider() => RegionUrlProvider(url: blr, token: 'tok')
    ..setServerReportedRegions(
      lk_rtc.RegionSettings(
        regions: [
          lk_rtc.RegionInfo(region: 'doh1', url: doh, distance: Int64(0)),
          lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(1)),
          lk_rtc.RegionInfo(region: 'blr1', url: blr, distance: Int64(2)),
        ],
      ),
    );

  Future<void> connectThenBreakBlr({RoomOptions? roomOptions, Future<void> Function(Uri)? blrDial}) async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(
      server,
      pcs,
      url: blr,
      connection: const Duration(seconds: 1),
      roomOptions: roomOptions,
    );
    engine.setRegionUrlProvider(provider());
    // (0.4.15 F6, failoverNeedsEvidence: blr1 is down, the other regions answer
    // their probe -- the evidence a move needs)
    engine.gravixReachabilityProbe = (url, t) async => !url.contains('blr1');
    // blr1 is unreachable from now on; the other regions answer
    server.onDial = (u) async {
      if (u.host.startsWith('blr1')) {
        if (blrDial != null) return blrDial(u);
        throw WebSocketException('Failed to connect', 'blr1 unreachable');
      }
    };
    autoConnectPcs(pcs);
  }

  List<String> hosts(int from) => [for (final u in server.dials.skip(from)) u.host.split('.').first];

  test('a failed full reconnect goes to the nearest measured region, not the server list head', () async {
    await measure();
    await connectThenBreakBlr();
    final from = server.dials.length;
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => hosts(from).any((h) => h != 'blr1')), isTrue);
    expect(hosts(from).firstWhere((h) => h != 'blr1'), 'sgp1', reason: 'base: doh1 (server order)');
    expect(engine.url, sgp);
  });

  test('the failed url is retried once, with the short dial timeout, before another region', () async {
    await measure();
    final dialAt = <DateTime>[];
    await connectThenBreakBlr(
      roomOptions: RoomOptions(
        reconnectPolicy: FastPolicy(),
        recovery: const GravixRecoveryOptions(sameUrlRetryDialTimeout: Duration(milliseconds: 200)),
      ),
      // blr1's dial hangs (a black-holed path) until the timeout cuts it
      blrDial: (u) async {
        dialAt.add(DateTime.now());
        await Completer<void>().future;
      },
    );
    final from = server.dials.length;
    final t0 = DateTime.now();
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => hosts(from).any((h) => h != 'blr1'), timeout: const Duration(seconds: 6)), isTrue);
    final seq = hosts(from);
    final firstOther = seq.indexWhere((h) => h != 'blr1');
    expect(seq.sublist(0, firstOther), ['blr1', 'blr1'], reason: 'one normal attempt, one short retry');
    // the retry gave up after ~200 ms, not the 1 s connection timeout
    final otherAt = DateTime.now();
    expect(dialAt.length, 2);
    expect(otherAt.difference(dialAt[1]).inMilliseconds, lessThan(800));
    expect(dialAt[1].difference(t0).inMilliseconds, greaterThanOrEqualTo(900), reason: 'first attempt: full 1 s');
  });

  test('without a fresh measurement the server order is kept (the last resort)', () async {
    await connectThenBreakBlr();
    final from = server.dials.length;
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => hosts(from).any((h) => h != 'blr1')), isTrue);
    expect(hosts(from).firstWhere((h) => h != 'blr1'), 'doh1');
  });

  test('measuredRegionFailover / retrySameUrlFirst off: the 0.4.14 order, no retry', () async {
    await measure();
    await connectThenBreakBlr(
      roomOptions: RoomOptions(
        reconnectPolicy: FastPolicy(),
        recovery: const GravixRecoveryOptions(measuredRegionFailover: false, retrySameUrlFirst: false),
      ),
    );
    final from = server.dials.length;
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => hosts(from).any((h) => h != 'blr1')), isTrue);
    final seq = hosts(from);
    expect(seq.sublist(0, seq.indexWhere((h) => h != 'blr1')), ['blr1']);
    expect(seq.firstWhere((h) => h != 'blr1'), 'doh1');
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// REGION-FAILOVER, emulator 2026-10-11 (SIMULATED, API 34, blr1 DROPped, r552 /
// r554): cc30276 + the region-list fallback moved a viewer to sgp1 only 74.7 /
// 74.1 s after the stall: two resumes (10 s connect timeouts each) -> 24.6 s;
// the full reconnect's dial raced up to its 30 s cap (signalDialCap) and then
// a 10 s /rtc/validate to the same silent host -> 66.6 s; the same-url retry ->
// 71.6 s; F6 probes; sgp1 at 74.7 s. Every dial to blr1 failed with no TCP
// connection at all; a slow path has its connection up and waits on the
// upgrade's answer.
//
// Scaled: Timeouts.connection 300 ms, signalDialCap 900 ms, same-url retry
// 200 ms; the F6 probe is injected (answers at once). Only the base API is used.
@TestOn('vm')
library;

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/reconnect_policy.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';

import '../support/blackhole_path.dart';
import '../support/fake_rtc.dart';

class _KeepTrying extends ReconnectPolicy {
  @override
  int? nextRetryDelayInMs(ReconnectContext context) => 10;
}

const blr = 'ws://blr1.gravixcloud.run';
const sgp = 'ws://sgp1.gravixcloud.run';
const bound = Duration(milliseconds: 300);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalSignalServer server;
  late BlackholePath path;
  Engine? engine;

  setUp(() async {
    installRecoveryChannelMocks();
    HttpOverrides.global = null;
    server = LocalSignalServer();
    await server.start();
    path = BlackholePath(server.port);
    IOOverrides.global = path;
  });

  tearDown(() async {
    await engine?.dispose();
    engine = null;
    IOOverrides.global = null;
    expect(path.requested.where((r) => r.endsWith(':0')), isEmpty, reason: '${path.requested}');
    await server.stop();
  });

  Future<Engine> onBlr1({GravixRecoveryOptions? recovery}) async {
    final pcs = FakePcFactory();
    autoConnectPcs(pcs);
    final e = Engine(
      connectOptions: ConnectOptions(
        timeouts: fastTimeouts(connection: bound, peerConnection: const Duration(seconds: 2)),
      ),
      roomOptions: RoomOptions(
        reconnectPolicy: _KeepTrying(),
        recovery:
            recovery ??
            const GravixRecoveryOptions(
              sameUrlRetryDialTimeout: Duration(milliseconds: 200),
              signalDialCap: Duration(milliseconds: 900),
            ),
      ),
      signalClient: FakeConnectivitySignalClient(GravixRtcWebSocket.connect),
      peerConnectionCreate: pcs.create,
    );
    await e.connect(blr, 'tok');
    e.setRegionUrlProvider(
      RegionUrlProvider(url: blr, token: 'tok')..setServerReportedRegions(
        lk_rtc.RegionSettings(
          regions: [
            lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(0)),
            lk_rtc.RegionInfo(region: 'blr1', url: blr, distance: Int64(1)),
          ],
        ),
      ),
    );
    // F6 evidence: blr1 does not answer, sgp1 does
    e.gravixReachabilityProbe = (url, t) async => !url.contains('blr1');
    return e;
  }

  Future<int> failoverMs() async {
    final restarted = <EngineRestartedEvent>[];
    final e = engine!;
    final listener = e.createListener()..on<EngineRestartedEvent>(restarted.add);
    addTearDown(listener.dispose);
    path.silentHosts.add('blr1.gravixcloud.run');
    final watch = Stopwatch()..start();
    expect(e.gravixRequestResume('blr1 silent'), isTrue);
    final moved = await eventually(() => restarted.isNotEmpty && e.url == sgp, timeout: const Duration(seconds: 6));
    expect(moved, isTrue, reason: '${path.blackholed}');
    return watch.elapsedMilliseconds;
  }

  test('blr1 silent (no TCP), sgp1 up: the session fails over without a raced dial or a validate to blr1', () async {
    engine = await onBlr1();
    final ms = await failoverMs();
    // ignore: avoid_print
    print('RESULT silent_host_failover_ms=$ms (bound ${bound.inMilliseconds} ms) steps=${path.blackholed}');
    // c2bce0e: 2 x 300 resumes + 900 raced dial + 300 validate + 200 retry + 200
    // validate = ~2.3 s; now 2 x 300 + 300 + 200 = ~1.2 s (field: ~74 s -> ~40 s)
    expect(ms, lessThan(1800));
    expect(path.kinds, isNot(contains('validate')), reason: 'a host that never connected is not asked to validate');
  });

  test('silentHostFailFast: false = the cc30276 path (raced to the cap, validated)', () async {
    engine = await onBlr1(
      recovery: const GravixRecoveryOptions(
        sameUrlRetryDialTimeout: Duration(milliseconds: 200),
        signalDialCap: Duration(milliseconds: 900),
        silentHostFailFast: false,
      ),
    );
    final ms = await failoverMs();
    expect(ms, greaterThan(2000));
    expect(path.kinds, contains('validate'));
  });

  group('signal client', () {
    final options = RoomOptions(recovery: const GravixRecoveryOptions(signalDialCap: Duration(milliseconds: 900)));
    ConnectOptions connectOptions() => ConnectOptions(timeouts: fastTimeouts(connection: bound));

    Future<SignalClient> afterSilentResume() async {
      engine = null;
      final sc = SignalClient(GravixRtcWebSocket.connect);
      addTearDown(sc.dispose);
      path.silentHosts.add('blr1.gravixcloud.run');
      await expectLater(
        sc.connect(blr, 'tok', connectOptions: connectOptions(), roomOptions: options, reconnect: true),
        throwsA(isA<GravixDialTimeoutException>().having((e) => e.noConnection, 'noConnection', isTrue)),
      );
      return sc;
    }

    test(
      'the host is still silent: the fresh dial fails at the dial timeout, not the cap, and is not validated',
      () async {
        final sc = await afterSilentResume();
        final watch = Stopwatch()..start();
        await expectLater(
          sc.connect(blr, 'tok', connectOptions: connectOptions(), roomOptions: options),
          throwsA(isA<GravixDialTimeoutException>()),
        );
        expect(watch.elapsedMilliseconds, lessThan(bound.inMilliseconds + 250));
        expect(path.kinds, ['dial', 'dial'], reason: 'no race, no validate');
      },
    );

    test(
      'the host answers again but slowly (connection up, upgrade answered after the dial timeout): it joins',
      () async {
        final sc = await afterSilentResume();
        path.silentHosts.clear();
        server.upgradeDelay = const Duration(milliseconds: 450);
        // the connection comes up at once; the upgrade keeps the cap (900 ms)
        await sc.connect(blr, 'tok', connectOptions: connectOptions(), roomOptions: options);
        expect(sc.connectionState.name, 'connected');
      },
    );
  });
}

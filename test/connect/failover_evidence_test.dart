// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// F6 (device test 2026-10-10, r127 / r149: Wi-Fi flapping 2 s off / 3 s on,
// viewer on blr1): the full reconnect at blr1 failed (MediaConnectException:
// the peer connection could not connect while the PHONE's Wi-Fi was off), the
// same-url retry landed in the next off phase too, and the session moved to
// sgp1 for good with the host relayed. blr1 never failed.
//
// Now (failoverNeedsEvidence) the session url is left only with evidence that
// the region failed: no connectivity change / offline reading since the attempt
// began, the session url does not answer a probe, and the other region does.
// Otherwise the same url is retried (through the normal reconnect back-off and
// the F3 network wait).
import 'dart:io' show HttpClient, HttpOverrides, SecurityContext, SocketException;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

/// The dial-failure validation request fails like a dead path (the test binding
/// answers every request 400, which reads as a refusal).
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
  late FakeConnectivitySignalClient signal;
  late Engine engine;
  tearDown(() async => engine.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';
  List<String> freshHosts(int from) => [
    for (final u in server.dials.skip(from))
      if (!isResume(u)) u.host.split('.').first,
  ];

  Future<void> onBlr1() async {
    await gravixMeasureRegions(
      regionUrls: const [
        GravixRegionUrl(region: 'sgp1', url: sgp),
        GravixRegionUrl(region: 'blr1', url: blr),
        GravixRegionUrl(region: 'doh1', url: doh),
      ],
      sampler: (r) async => Duration(milliseconds: const {'sgp1': 61, 'blr1': 120, 'doh1': 260}[r.region]!),
    );
    server = FakeSignalServer();
    signal = FakeConnectivitySignalClient(server.connect);
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(
      server,
      pcs,
      url: blr,
      subscriberPrimary: true,
      signalClient: signal,
      connection: const Duration(milliseconds: 800),
      // (a full reconnect waits mediaConnect since fullReconnectMediaConnect)
      mediaConnect: const Duration(milliseconds: 800),
    );
    engine.setRegionUrlProvider(
      RegionUrlProvider(url: blr, token: 'tok')..setServerReportedRegions(
        lk_rtc.RegionSettings(
          regions: [
            lk_rtc.RegionInfo(region: 'doh1', url: doh, distance: Int64(0)),
            lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(1)),
            lk_rtc.RegionInfo(region: 'blr1', url: blr, distance: Int64(2)),
          ],
        ),
      ),
    );
  }

  test('the phone\'s network flapped during the attempt: the session stays on its url', () async {
    await onBlr1();
    // every server answers its probe: nothing points at blr1
    engine.gravixReachabilityProbe = (url, t) async => true;
    final from = server.dials.length;
    // the joins are accepted but the peer connections never connect (Wi-Fi off
    // phases), and the connectivity reading flips during the attempt
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    await settle(300);
    signal.events.emit(
      const SignalConnectivityChangedEvent(oldState: [ConnectivityResult.none], state: [ConnectivityResult.wifi]),
    );
    await settle(2500); // the attempt and its same-url retry time out (0.8 s each)
    expect(freshHosts(from).where((h) => h != 'blr1'), isEmpty, reason: 'base: moved to sgp1 after the same-url retry');
    expect(freshHosts(from).length, greaterThanOrEqualTo(2), reason: 'blr1 retried');
    // the network settles: the next attempt on blr1 succeeds
    autoConnectPcs(pcs);
    expect(await eventually(() => engine.url == blr && engine.connectionState.name == 'connected'), isTrue);
  });

  test('ICE failed but blr1 answers its probe (no evidence against the region): stay on blr1', () async {
    await onBlr1();
    engine.gravixReachabilityProbe = (url, t) async => true;
    final from = server.dials.length;
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    await settle(2500);
    expect(freshHosts(from).where((h) => h != 'blr1'), isEmpty, reason: 'base: moved to sgp1');
    autoConnectPcs(pcs);
  });

  test('evidence: blr1 unreachable, sgp1 answers, the network was steady -> fail over to sgp1', () async {
    await onBlr1();
    engine.gravixReachabilityProbe = (url, t) async => !url.contains('blr1');
    server.onDial = (u) async {
      if (u.host.startsWith('blr1')) throw WebSocketException('Failed to connect', 'blr1 unreachable');
    };
    autoConnectPcs(pcs);
    final from = server.dials.length;
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => freshHosts(from).contains('sgp1'), timeout: const Duration(seconds: 5)), isTrue);
    expect(freshHosts(from).contains('doh1'), isFalse);
  });

  test('blr1 and sgp1 both unreachable (the phone is offline): stay on blr1', () async {
    await onBlr1();
    engine.gravixReachabilityProbe = (url, t) async => false;
    server.onDial = (u) async {
      if (u.host.startsWith('blr1')) throw WebSocketException('Failed to connect', 'network unreachable');
    };
    final from = server.dials.length;
    await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    await settle(1500);
    expect(freshHosts(from).where((h) => h != 'blr1'), isEmpty, reason: 'base: moved to sgp1');
    server.onDial = null;
    autoConnectPcs(pcs);
  });
}

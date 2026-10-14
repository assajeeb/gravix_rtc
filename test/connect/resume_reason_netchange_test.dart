// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-14, device run (an Android host, Wi-Fi off ~14 s): the SFU took the
// outage for "UDP blocked" and preferred ICE/TCP for that identity (5 min, every
// rejoin renews it); every later session on that path ran over TCP and degraded
// to seconds of RTT. One server trigger is a resume whose reason says a peer
// connection failed (RR_PUBLISHER_FAILED / RR_SUBSCRIBER_FAILED) on a connection
// younger than 90 s. After the phone's own network changed, the peer
// connection failing is the network's doing, not UDP's: the resume now says
// RR_SIGNAL_DISCONNECTED (GravixRecoveryOptions.resumeReasonNetworkWindow).
// A peer connection failing on a steady network still says RR_*_FAILED.

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late FakeConnectivitySignalClient signal;
  late Engine engine;
  tearDown(() async => engine.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';

  Future<void> start({GravixRecoveryOptions recovery = const GravixRecoveryOptions()}) async {
    server = FakeSignalServer();
    signal = FakeConnectivitySignalClient(server.connect);
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(
      server,
      pcs,
      signalClient: signal,
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
    engine.gravixReachabilityProbe = (url, timeout) async => false;
    autoConnectPcs(pcs);
  }

  /// The reconnect_reason of the first resume dial from [from] on.
  Future<int?> resumeReason(int from) async {
    expect(
      await eventually(() => server.dials.skip(from).any(isResume), timeout: const Duration(seconds: 4)),
      isTrue,
      reason: 'a resume was dialled',
    );
    final u = server.dials.skip(from).firstWhere(isResume);
    final r = u.queryParameters['reconnect_reason'];
    return r == null ? null : int.parse(r);
  }

  void netChange(List<ConnectivityResult> from, List<ConnectivityResult> to) =>
      signal.events.emit(SignalConnectivityChangedEvent(oldState: from, state: to));

  final signalDisconnected = lk_models.ReconnectReason.RR_SIGNAL_DISCONNECTED.value;
  final publisherFailed = lk_models.ReconnectReason.RR_PUBLISHER_FAILED.value;
  final subscriberFailed = lk_models.ReconnectReason.RR_SUBSCRIBER_FAILED.value;

  test('a steady network: the publisher connection drops -> the resume says RR_PUBLISHER_FAILED', () async {
    await start();
    final from = server.dials.length;
    pcs.publisher.disconnect();
    expect(await resumeReason(from), publisherFailed);
  });

  test('a steady network: the subscriber connection drops -> RR_SUBSCRIBER_FAILED', () async {
    await start();
    final from = server.dials.length;
    pcs.subscriber.disconnect();
    expect(await resumeReason(from), subscriberFailed);
  });

  test('Wi-Fi off, then back: the connection that dropped meanwhile resumes with RR_SIGNAL_DISCONNECTED', () async {
    await start();
    final from = server.dials.length;
    signal.online = false;
    netChange([ConnectivityResult.wifi], [ConnectivityResult.none]);
    pcs.publisher.disconnect();
    await settle(100);
    signal.online = true;
    netChange([ConnectivityResult.none], [ConnectivityResult.wifi]);
    expect(await resumeReason(from), signalDisconnected);
  });

  test('a handover (Wi-Fi -> mobile) shortly before the drop counts as a network change', () async {
    await start();
    final from = server.dials.length;
    netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
    await settle(50);
    pcs.subscriber.disconnect();
    expect(await resumeReason(from), signalDisconnected);
  });

  test('a network change longer ago than the window: RR_*_FAILED as before', () async {
    await start(recovery: const GravixRecoveryOptions(resumeReasonNetworkWindow: Duration(milliseconds: 100)));
    netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
    await settle(300);
    final from = server.dials.length;
    pcs.publisher.disconnect();
    expect(await resumeReason(from), publisherFailed);
  });

  test('a same-type connectivity repeat is not a network change', () async {
    await start();
    netChange([ConnectivityResult.wifi], [ConnectivityResult.wifi]);
    final from = server.dials.length;
    pcs.publisher.disconnect();
    expect(await resumeReason(from), publisherFailed);
  });

  test('off (resumeReasonNetworkWindow: Duration.zero): RR_*_FAILED even after a network change', () async {
    await start(recovery: const GravixRecoveryOptions(resumeReasonNetworkWindow: Duration.zero));
    final from = server.dials.length;
    netChange([ConnectivityResult.wifi], [ConnectivityResult.mobile]);
    pcs.publisher.disconnect();
    expect(await resumeReason(from), publisherFailed);
  });

  test('the default is on (30 s); legacy turns it off', () {
    expect(const GravixRecoveryOptions().resumeReasonNetworkWindow, const Duration(seconds: 30));
    expect(GravixRecoveryOptions.legacy.resumeReasonNetworkWindow, Duration.zero);
    expect(
      const GravixRecoveryOptions().copyWith(resumeReasonNetworkWindow: Duration.zero).resumeReasonNetworkWindow,
      Duration.zero,
    );
  });

  test(
    'a resume the engine requested for stalled media after a network change says RR_SIGNAL_DISCONNECTED too',
    () async {
      await start();
      var resumed = 0;
      engine.events.on<EngineResumedEvent>((_) => resumed++);
      final from = server.dials.length;
      netChange([ConnectivityResult.mobile], [ConnectivityResult.wifi]);
      expect(engine.gravixRequestResume('test', uplink: true), isTrue);
      expect(await resumeReason(from), signalDisconnected);
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 4)), isTrue);
    },
  );
}

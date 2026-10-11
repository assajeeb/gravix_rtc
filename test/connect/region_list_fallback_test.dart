// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// EMU-OLD 2026-10-11 (SIMULATED, rooted API 34 emulator, 8470448): with blr1
// dead (iptables REJECT or DROP for 120-150 s) the session never failed over:
// 0 of 9 runs. Every full reconnect ended with
//   attemptReconnect: full reconnect failed: ClientException ... Connection
//   refused ... uri=https://blr1.gravixcloud.run/settings/regions
// The failover asks RegionUrlProvider for the next region; the list fetched at
// connect was older than its 5 s cache, so the provider fetched it again FROM
// THE DEAD HOST, and that error escaped restartConnection before the failover
// (or the F6 guard) ran. With REJECT the session ended reconnectAttemptsExceeded
// after ~97 s, with sgp1 up the whole time.
//
// Now (GravixRecoveryOptions.lastGoodRegionList): a failed fetch falls back to
// the last list the provider had (fetched at connect, or reported by the
// server), however old. The F6 guard still decides whether the session may
// leave its url.
import 'dart:async';
import 'dart:io' show HttpClient, HttpOverrides, SecurityContext, SocketException;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/exceptions.dart' show ConnectException, ConnectionErrorReason;
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/logger.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

/// Every HTTP request fails like a dead path: the region list fetch, the dial
/// failure's /rtc/validate. (The test binding would answer 400 = a refusal.)
class _Offline extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw const SocketException('Connection refused');
}

/// A provider whose fetch the test scripts ([fail] = what the fetch throws).
class _ScriptedProvider extends RegionUrlProvider {
  _ScriptedProvider() : super(url: blr, token: 'tok');
  Object? fail;
  lk_rtc.RegionSettings? answer;
  int fetches = 0;

  /// The fetch never answers (a silently dropping host, no timeout given).
  bool hang = false;
  @override
  Future<lk_rtc.RegionSettings> fetchRegionSettings({Duration? timeout}) async {
    fetches++;
    if (hang) await Completer<void>().future;
    if (fail != null) throw fail!;
    lastUpdateAt = DateTime.timestamp().millisecondsSinceEpoch;
    return answer!;
  }
}

const blr = 'wss://blr1.gravixcloud.run';
const sgp = 'wss://sgp1.gravixcloud.run';
const doh = 'wss://doh1.gravixcloud.run';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final logs = <String>[];
  StreamSubscription<Object?>? logSub;
  setUp(() {
    installRecoveryChannelMocks();
    gravixClearRegionMeasurement();
    HttpOverrides.global = _Offline();
    logs.clear();
    logSub = logger.onRecord.listen((r) => logs.add(r.message));
  });
  tearDown(() async {
    HttpOverrides.global = null;
    await logSub?.cancel();
  });

  // the Bangladesh viewer's start-up measurement (field 2026-10-09)
  Future<void> measure() => gravixMeasureRegions(
    regionUrls: const [
      GravixRegionUrl(region: 'sgp1', url: sgp),
      GravixRegionUrl(region: 'blr1', url: blr),
      GravixRegionUrl(region: 'doh1', url: doh),
    ],
    sampler: (r) async => Duration(milliseconds: const {'sgp1': 61, 'blr1': 120, 'doh1': 260}[r.region]!),
  );

  /// blr1's `/settings/regions` as fetched at connect, [age] ago: the other
  /// regions in configuration order (doh1 first), its own region last.
  RegionUrlProvider listFetchedAtConnect({Duration age = const Duration(minutes: 1)}) {
    final p = RegionUrlProvider(url: blr, token: 'tok')
      ..setServerReportedRegions(
        lk_rtc.RegionSettings(
          regions: [
            lk_rtc.RegionInfo(region: 'doh1', url: doh, distance: Int64(0)),
            lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(1)),
            lk_rtc.RegionInfo(region: 'blr1', url: blr, distance: Int64(2)),
          ],
        ),
      );
    // older than the provider's 5 s cache: the failover asks blr1 for it again
    p.lastUpdateAt -= age.inMilliseconds;
    return p;
  }

  late FakeSignalServer server;
  late FakePcFactory pcs;

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';
  List<String> freshHosts(int from) => [
    for (final u in server.dials.skip(from))
      if (!isResume(u)) u.host.split('.').first,
  ];

  group('room on blr1, blr1 dies (refused), sgp1 up', () {
    Room? room;
    tearDown(() async {
      await room?.dispose();
      room = null;
    });

    Future<Room> roomOnBlr1() async {
      server = FakeSignalServer();
      pcs = FakePcFactory();
      // each region names itself in its JoinResponse
      server.joinResponse = (u) => fakeJoinResponse(subscriberPrimary: true, serverRegion: u.host.split('.').first);
      final r = room = await connectedFakeRoom(server, pcs, url: blr, subscriberPrimary: true);
      expect(r.connectedRegion, 'blr1');
      return r;
    }

    void blr1Dies(Room r) {
      // the evidence F6 needs: blr1 does not answer, the other regions do
      r.engine.gravixReachabilityProbe = (url, t) async => !url.contains('blr1');
      server.onDial = (u) async {
        if (u.host.startsWith('blr1')) throw WebSocketException('Failed to connect', 'Connection refused');
      };
    }

    test('a list fetched at connect: fails over to the NEAR region (sgp1), RoomConnectedUrlChangedEvent', () async {
      await measure();
      final r = await roomOnBlr1();
      r.engine.setRegionUrlProvider(listFetchedAtConnect());
      final changes = <RoomConnectedUrlChangedEvent>[];
      final disconnects = <RoomDisconnectedEvent>[];
      r.events.on<RoomConnectedUrlChangedEvent>(changes.add);
      r.events.on<RoomDisconnectedEvent>(disconnects.add);
      blr1Dies(r);
      final from = server.dials.length;

      await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);

      expect(
        await eventually(() => changes.isNotEmpty || disconnects.isNotEmpty, timeout: const Duration(seconds: 6)),
        isTrue,
      );
      expect(disconnects, isEmpty, reason: 'base: the region list fetch from the dead blr1 ended every attempt');
      expect(changes.single.url, sgp);
      expect(changes.single.region, 'sgp1');
      expect(changes.single.previousUrl, blr);
      expect(changes.single.previousRegion, 'blr1');
      expect(changes.single.reason, RoomConnectedUrlChangeReason.rejoin);
      expect(freshHosts(from).firstWhere((h) => h != 'blr1'), 'sgp1', reason: 'near first, not the list head doh1');
      expect(freshHosts(from), isNot(contains('doh1')));
      expect(r.connectedUrl, sgp);
      expect(r.connectedRegion, 'sgp1');
      expect(r.connectionState, ConnectionState.connected);
      expect(logs.any((m) => m.contains('/settings/regions') && m.contains('last good list')), isTrue);
    });

    test('lastGoodRegionList off: the 0.4.14 behaviour, the list fetch error ends every attempt on blr1', () async {
      await measure();
      server = FakeSignalServer();
      pcs = FakePcFactory();
      server.joinResponse = (u) => fakeJoinResponse(subscriberPrimary: true, serverRegion: u.host.split('.').first);
      final r = room = await connectedFakeRoom(
        server,
        pcs,
        url: blr,
        subscriberPrimary: true,
        roomOptions: RoomOptions(
          reconnectPolicy: FastPolicy(),
          recovery: const GravixRecoveryOptions(lastGoodRegionList: false),
        ),
      );
      r.engine.setRegionUrlProvider(listFetchedAtConnect());
      final changes = <RoomConnectedUrlChangedEvent>[];
      final disconnects = <RoomDisconnectedEvent>[];
      r.events.on<RoomConnectedUrlChangedEvent>(changes.add);
      r.events.on<RoomDisconnectedEvent>(disconnects.add);
      blr1Dies(r);
      final from = server.dials.length;

      await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);

      expect(await eventually(() => disconnects.isNotEmpty, timeout: const Duration(seconds: 8)), isTrue);
      expect(disconnects.single.reason, DisconnectReason.reconnectAttemptsExceeded);
      expect(changes, isEmpty);
      expect(freshHosts(from).where((h) => h != 'blr1'), isEmpty);
      expect(logs.any((m) => m.contains('last good list')), isFalse);
    });

    test('no list (the connect-time fetch failed too): the old behaviour, the session ends on blr1', () async {
      await measure();
      final r = await roomOnBlr1(); // its own provider: the connect-time fetch failed (offline)
      final changes = <RoomConnectedUrlChangedEvent>[];
      final disconnects = <RoomDisconnectedEvent>[];
      r.events.on<RoomConnectedUrlChangedEvent>(changes.add);
      r.events.on<RoomDisconnectedEvent>(disconnects.add);
      blr1Dies(r);
      final from = server.dials.length;

      await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);

      expect(await eventually(() => disconnects.isNotEmpty, timeout: const Duration(seconds: 8)), isTrue);
      expect(disconnects.single.reason, DisconnectReason.reconnectAttemptsExceeded);
      expect(changes, isEmpty);
      expect(freshHosts(from).where((h) => h != 'blr1'), isEmpty);
      expect(logs.any((m) => m.contains('last good list')), isFalse);
    });
  });

  group('engine on doh1 (moved there earlier), doh1 dies, the list host blr1 does not answer either', () {
    late Engine engine;
    tearDown(() async => engine.dispose());

    test('the list fetch to blr1 fails -> the kept list -> sgp1 (the fallback inside restartConnection)', () async {
      await measure();
      server = FakeSignalServer();
      pcs = FakePcFactory();
      engine = await connectedFakeEngine(server, pcs, url: doh, subscriberPrimary: true);
      // the provider still points at blr1 (the url the app passed); its list is a minute old
      engine.setRegionUrlProvider(listFetchedAtConnect());
      engine.gravixReachabilityProbe = (url, t) async => url.contains('sgp1');
      server.onDial = (u) async {
        if (!u.host.startsWith('sgp1')) throw WebSocketException('Failed to connect', 'Connection refused');
      };
      autoConnectPcs(pcs);
      final from = server.dials.length;

      await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);

      expect(await eventually(() => engine.url == sgp && engine.connectionState.name == 'connected'), isTrue);
      expect(freshHosts(from).firstWhere((h) => h != 'doh1'), 'sgp1');
      expect(
        logs.any((m) => m.contains('blr1.gravixcloud.run/settings/regions failed') && m.contains('last good list')),
        isTrue,
        reason: 'the list host is not the url that failed: asked, failed, the kept list used',
      );
    });
  });

  group('engine on blr1, the phone\'s network flaps, blr1 alive (F6 guard)', () {
    late FakeConnectivitySignalClient signal;
    late Engine engine;
    tearDown(() async => engine.dispose());

    Future<void> onBlr1() async {
      await measure();
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
      engine.setRegionUrlProvider(listFetchedAtConnect());
    }

    test('connectivity changed during the attempt: the guard keeps the session on blr1', () async {
      await onBlr1();
      engine.gravixReachabilityProbe = (url, t) async => true;
      final from = server.dials.length;
      // the joins are accepted but the peer connections never connect (Wi-Fi
      // off phases), and the connectivity reading flips during the attempt
      await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      await settle(300);
      signal.events.emit(
        const SignalConnectivityChangedEvent(oldState: [ConnectivityResult.none], state: [ConnectivityResult.wifi]),
      );
      await settle(2500);
      expect(freshHosts(from).where((h) => h != 'blr1'), isEmpty);
      expect(
        logs.any((m) => m.contains('nothing shows the region failed') && m.contains('staying on it')),
        isTrue,
        reason: 'the F6 guard decided (base: the region list fetch failed before the guard ran)',
      );
      autoConnectPcs(pcs);
      expect(await eventually(() => engine.url == blr && engine.connectionState.name == 'connected'), isTrue);
    });

    test('ICE failed but blr1 answers its probe: the guard keeps the session on blr1', () async {
      await onBlr1();
      engine.gravixReachabilityProbe = (url, t) async => true;
      final from = server.dials.length;
      await engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      await settle(2500);
      expect(freshHosts(from).where((h) => h != 'blr1'), isEmpty);
      expect(logs.any((m) => m.contains('staying on it')), isTrue);
      autoConnectPcs(pcs);
      expect(await eventually(() => engine.url == blr && engine.connectionState.name == 'connected'), isTrue);
    });
  });

  group('RegionUrlProvider.getNextBestRegionUrl', () {
    lk_rtc.RegionSettings list(List<String> regions) => lk_rtc.RegionSettings(
      regions: [
        for (final (i, r) in regions.indexed)
          lk_rtc.RegionInfo(region: r, url: 'wss://$r.gravixcloud.run', distance: Int64(i)),
      ],
    );

    _ScriptedProvider kept() {
      final p = _ScriptedProvider()..setServerReportedRegions(list(['doh1', 'sgp1', 'blr1']));
      p.lastUpdateAt -= const Duration(minutes: 30).inMilliseconds; // a long session
      return p;
    }

    test('fetch refused / timed out: the kept list, near first, the failed url last', () async {
      await measure();
      for (final error in [
        const SocketException('Connection refused'),
        TimeoutException('region list', const Duration(seconds: 10)), // DROP: the bounded fetch gave up
        ConnectException(
          'Could not fetch region settings: 503',
          reason: ConnectionErrorReason.InternalError,
          statusCode: 503,
        ),
      ]) {
        // the session had moved to doh1 and doh1 failed; the list host blr1 does not answer either
        final p = kept()..fail = error;
        Future<String?> next() => p.getNextBestRegionUrl(currentUrl: doh, measuredOrder: true, lastGoodFallback: true);
        expect(await next(), sgp, reason: '$error');
        expect(await next(), blr, reason: 'measured 120 ms: near (cap 161 ms)');
        expect(await next(), doh);
        expect(await next(), isNull);
        expect(p.fetches, 4, reason: 'the list host is not the url that failed: it is asked every time');
      }
    });

    test('the list host IS the url that just failed: the kept list at once, no fetch', () async {
      // EMU r504 (SIMULATED, blr1 DROP): the fetch to the blr1 that had just timed out twice waited its full
      // 10 s bound before the fallback; failover at 64.8 s, of which 10 s was this fetch
      await measure();
      final p = kept()..hang = true;
      final next = await p
          .getNextBestRegionUrl(currentUrl: blr, measuredOrder: true, lastGoodFallback: true, currentUrlFailed: true)
          .timeout(const Duration(seconds: 2));
      expect(next, sgp);
      expect(p.fetches, 0);
      expect(logs.any((m) => m.contains('just failed') && m.contains('last good list')), isTrue);
    });

    test('not a failure at that url (e.g. a refusal), or nothing kept: the list host is still asked', () async {
      final refused = kept()..fail = const SocketException('Connection refused');
      expect(await refused.getNextBestRegionUrl(currentUrl: blr, lastGoodFallback: true), doh);
      expect(refused.fetches, 1);
      final empty = _ScriptedProvider()..answer = list(['sgp1', 'blr1']);
      expect(await empty.getNextBestRegionUrl(currentUrl: blr, lastGoodFallback: true, currentUrlFailed: true), sgp);
      expect(empty.fetches, 1);
    });

    test('off (the default parameter): the fetch error escapes, as before', () async {
      final p = kept()..fail = const SocketException('Connection refused');
      await expectLater(p.getNextBestRegionUrl(currentUrl: blr, measuredOrder: true), throwsA(isA<SocketException>()));
    });

    test('a refusal (401) is the token, not the region: it still escapes', () async {
      final p = kept()
        ..fail = ConnectException(
          'Could not fetch region settings',
          reason: ConnectionErrorReason.NotAllowed,
          statusCode: 401,
        );
      await expectLater(
        p.getNextBestRegionUrl(currentUrl: blr, measuredOrder: true, lastGoodFallback: true),
        throwsA(isA<ConnectException>()),
      );
    });

    test('nothing kept: the fetch error escapes', () async {
      final p = _ScriptedProvider()..fail = const SocketException('Connection refused');
      await expectLater(
        p.getNextBestRegionUrl(currentUrl: blr, lastGoodFallback: true),
        throwsA(isA<SocketException>()),
      );
    });

    test('a fetch that works replaces the kept list', () async {
      final p = kept()..answer = list(['fra1', 'blr1']);
      expect(await p.getNextBestRegionUrl(currentUrl: blr, lastGoodFallback: true), 'wss://fra1.gravixcloud.run');
      expect(p.fetches, 1);
    });
  });
}

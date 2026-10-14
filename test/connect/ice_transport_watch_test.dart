// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-14, device run (an Android host after a ~14 s Wi-Fi outage): the
// sessions that followed ran over ICE/TCP (the SFU's per-identity preference),
// their round trip grew from 1 s to 4-16 s and nothing in the app could tell
// why. And 8 full rejoins in 2 minutes: each rejoin's new peer connection went
// checking -> FAILED -> connected within ~0.1-1.7 s (its first TCP checks fail
// at once), and that transient FAILED asked for yet another full rejoin.
//
// Now:
//  * Room.selectedTransport (udp / tcp / relay, from each connection's selected
//    candidate pair) and RoomIceTransportChangedEvent;
//  * RoomSlowTcpTransportEvent once a TCP session's round trip stays above
//    GravixRecoveryOptions.slowTcpRtt (1 s) for slowTcpFor (10 s);
//  * a connection that never connected and reports FAILED gets
//    freshPeerFailedGrace (3 s) to connect before it asks for a reconnect.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_ice_transport.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

const _failed = rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed;

/// A connection's stats with its selected pair on [protocol] ([type]: the local
/// candidate's type) and a round trip of [rtt] seconds.
List<rtc.StatsReport> pairStats(String protocol, {String type = 'srflx', double rtt = 0.01}) => [
  rtc.StatsReport('T1', 'transport', 0, {'selectedCandidatePairId': 'CP1'}),
  rtc.StatsReport('CP1', 'candidate-pair', 0, {
    'localCandidateId': 'L1',
    'remoteCandidateId': 'R1',
    'currentRoundTripTime': rtt,
    'state': 'succeeded',
    'nominated': true,
  }),
  rtc.StatsReport('L1', 'local-candidate', 0, {'protocol': protocol, 'candidateType': type}),
  rtc.StatsReport('R1', 'remote-candidate', 0, {'protocol': protocol, 'candidateType': 'host'}),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  Room? room;
  Engine? engine;
  tearDown(() async {
    await room?.dispose();
    room = null;
    await engine?.dispose();
    engine = null;
  });

  const fastWatch = GravixRecoveryOptions(
    iceTransportWatch: Duration(milliseconds: 40),
    iceTransportWatchUdp: Duration(milliseconds: 40),
    slowTcpRtt: Duration(seconds: 1),
    slowTcpFor: Duration(milliseconds: 200),
  );

  Future<Room> hostRoom({GravixRecoveryOptions recovery = fastWatch}) async {
    server = FakeSignalServer()..answerOffers = true;
    pcs = FakePcFactory();
    final r = await connectedFakeRoom(
      server,
      pcs,
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
    return room = r;
  }

  group('selected transport', () {
    test('udp from the selected pair; null before the first reading', () async {
      final r = await hostRoom();
      pcs.publisher.stats = pairStats('udp');
      pcs.subscriber.stats = pairStats('udp');
      expect(await eventually(() => r.selectedTransport == GravixIceTransport.udp), isTrue);
      expect(r.publisherTransport, GravixIceTransport.udp);
      expect(r.subscriberTransport, GravixIceTransport.udp);
    });

    test('tcp on either connection makes the session tcp; an event with both connections', () async {
      final r = await hostRoom();
      final changes = <RoomIceTransportChangedEvent>[];
      r.events.on<RoomIceTransportChangedEvent>(changes.add);
      pcs.publisher.stats = pairStats('udp');
      pcs.subscriber.stats = pairStats('udp');
      expect(await eventually(() => r.selectedTransport == GravixIceTransport.udp), isTrue);
      pcs.publisher.stats = pairStats('tcp', type: 'prflx');
      expect(await eventually(() => r.selectedTransport == GravixIceTransport.tcp), isTrue);
      await settle(150);
      expect(changes.map((e) => e.transport).toList(), [GravixIceTransport.udp, GravixIceTransport.tcp]);
      expect(changes.last.previous, GravixIceTransport.udp);
      expect(changes.last.publisher, GravixIceTransport.tcp);
      expect(changes.last.subscriber, GravixIceTransport.udp);
    });

    test('a relay candidate is relay (whatever its protocol to the TURN server)', () async {
      final r = await hostRoom();
      pcs.publisher.stats = pairStats('udp', type: 'relay');
      pcs.subscriber.stats = pairStats('udp', type: 'relay');
      expect(await eventually(() => r.selectedTransport == GravixIceTransport.relay), isTrue);
    });

    test('off (iceTransportWatch: Duration.zero): nothing is read, the getter stays null', () async {
      final r = await hostRoom(recovery: const GravixRecoveryOptions(iceTransportWatch: Duration.zero));
      pcs.publisher.stats = pairStats('tcp');
      pcs.subscriber.stats = pairStats('tcp');
      await settle(200);
      expect(r.selectedTransport, isNull);
    });

    test('defaults: the first reading comes 3 s after a connection connected (not on the join path)', () async {
      final r = await hostRoom(recovery: const GravixRecoveryOptions());
      pcs.publisher.stats = pairStats('udp');
      pcs.subscriber.stats = pairStats('udp');
      await settle(1500);
      expect(r.selectedTransport, isNull, reason: 'nothing read during the join');
      expect(
        await eventually(() => r.selectedTransport == GravixIceTransport.udp, timeout: const Duration(seconds: 3)),
        isTrue,
      );
    });

    test('the default reads every 5 s; legacy is off', () {
      expect(const GravixRecoveryOptions().iceTransportWatch, const Duration(seconds: 5));
      expect(GravixRecoveryOptions.legacy.iceTransportWatch, Duration.zero);
    });
  });

  group('slow TCP', () {
    test('a TCP round trip above 1 s for slowTcpFor: one RoomSlowTcpTransportEvent per episode', () async {
      final r = await hostRoom();
      final slow = <RoomSlowTcpTransportEvent>[];
      r.events.on<RoomSlowTcpTransportEvent>(slow.add);
      pcs.publisher.stats = pairStats('tcp', type: 'prflx', rtt: 1.6);
      pcs.subscriber.stats = pairStats('tcp', type: 'prflx', rtt: 1.4);
      expect(await eventually(() => slow.isNotEmpty), isTrue);
      await settle(300);
      expect(slow.length, 1, reason: 'once per episode');
      expect(slow.single.rtt, const Duration(milliseconds: 1600));
      expect(slow.single.over, greaterThanOrEqualTo(const Duration(milliseconds: 200)));
      // recovers, then slow again: a second episode
      pcs.publisher.stats = pairStats('tcp', type: 'prflx', rtt: 0.05);
      pcs.subscriber.stats = pairStats('tcp', type: 'prflx', rtt: 0.05);
      await settle(150);
      pcs.publisher.stats = pairStats('tcp', type: 'prflx', rtt: 2.0);
      expect(await eventually(() => slow.length == 2), isTrue);
    });

    test('a slow UDP round trip is not a slow TCP transport', () async {
      final r = await hostRoom();
      final slow = <RoomSlowTcpTransportEvent>[];
      r.events.on<RoomSlowTcpTransportEvent>(slow.add);
      pcs.publisher.stats = pairStats('udp', rtt: 2.0);
      pcs.subscriber.stats = pairStats('udp', rtt: 2.0);
      await settle(400);
      expect(slow, isEmpty);
    });

    test('a short spike above 1 s is not reported', () async {
      final r = await hostRoom();
      final slow = <RoomSlowTcpTransportEvent>[];
      r.events.on<RoomSlowTcpTransportEvent>(slow.add);
      pcs.publisher.stats = pairStats('tcp', rtt: 1.5);
      pcs.subscriber.stats = pairStats('tcp', rtt: 0.05);
      await settle(100);
      pcs.publisher.stats = pairStats('tcp', rtt: 0.05);
      await settle(400);
      expect(slow, isEmpty);
    });
  });

  group('a fresh connection\'s transient FAILED (rejoin storm)', () {
    Future<Engine> hostEngine({Duration grace = const Duration(milliseconds: 300)}) async {
      server = FakeSignalServer();
      pcs = FakePcFactory();
      return engine = await connectedFakeEngine(
        server,
        pcs,
        roomOptions: RoomOptions(
          reconnectPolicy: FastPolicy(),
          recovery: GravixRecoveryOptions(freshPeerFailedGrace: grace),
        ),
      );
    }

    /// A full rejoin whose new subscriber goes checking -> FAILED -> connected
    /// after [recoverAfter] (null: stays failed); the publisher connects.
    Future<void> rejoinWithTransientFailure(Engine e, {Duration? recoverAfter}) async {
      final before = pcs.all.length;
      await e.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
      expect(await eventually(() => pcs.all.length >= before + 2, timeout: const Duration(seconds: 3)), isTrue);
      final pub = pcs.all[before], sub = pcs.all[before + 1];
      pub.connect();
      sub.setState(_failed);
      if (recoverAfter != null) {
        await Future<void>.delayed(recoverAfter);
        sub.connect();
      }
    }

    test('FAILED then connected within the grace: no second full rejoin', () async {
      final e = await hostEngine();
      var restarts = 0;
      e.events.on<EngineFullRestartingEvent>((_) => restarts++);
      await rejoinWithTransientFailure(e, recoverAfter: const Duration(milliseconds: 100));
      await settle(800);
      expect(restarts, 1, reason: 'the transient FAILED of a never-connected connection asked for nothing');
    });

    test('FAILED and still not connected after the grace: it asks for the reconnect as before', () async {
      final e = await hostEngine();
      var restarts = 0;
      e.events.on<EngineFullRestartingEvent>((_) => restarts++);
      await rejoinWithTransientFailure(e);
      autoConnectPcs(pcs); // the second rejoin's connections connect
      expect(await eventually(() => restarts >= 2, timeout: const Duration(seconds: 3)), isTrue);
    });

    test('a connection that WAS connected and fails reconnects at once (no grace)', () async {
      final e = await hostEngine(grace: const Duration(seconds: 5));
      var restarts = 0;
      e.events.on<EngineFullRestartingEvent>((_) => restarts++);
      autoConnectPcs(pcs);
      pcs.subscriber.setState(_failed);
      expect(await eventually(() => restarts >= 1, timeout: const Duration(seconds: 2)), isTrue);
    });

    test('off (freshPeerFailedGrace: Duration.zero): the transient FAILED rejoins again (the old behaviour)', () async {
      final e = await hostEngine(grace: Duration.zero);
      var restarts = 0;
      e.events.on<EngineFullRestartingEvent>((_) => restarts++);
      await rejoinWithTransientFailure(e, recoverAfter: const Duration(milliseconds: 100));
      autoConnectPcs(pcs);
      expect(await eventually(() => restarts >= 2, timeout: const Duration(seconds: 3)), isTrue);
    });

    test('the default grace is 3 s; legacy is off', () {
      expect(const GravixRecoveryOptions().freshPeerFailedGrace, const Duration(seconds: 3));
      expect(GravixRecoveryOptions.legacy.freshPeerFailedGrace, Duration.zero);
    });
  });
}

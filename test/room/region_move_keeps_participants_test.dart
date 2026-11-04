// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// F6 part 2 (device test 2026-10-10, r127 / r149): the rejoin landed on another
// node (sgp1) where the room had just been created; the host (on blr1) reaches
// that node through the relay a moment AFTER the JoinResponse. The JoinResponse
// therefore did not list the host: S5 treated the kept host as gone
// (TrackUnpublished x2, ParticipantDisconnected), and 2 ms later the relay's
// participant update announced it again (ParticipantConnected). The host never
// left.
//
// A kept identity the new JoinResponse does not list now gets a grace period
// (rejoinAbsentGrace) to reappear in a participant update before it is
// reported gone; when it reappears it is updated in place, no events.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

import '../support/fake_rtc.dart';

lk_models.ParticipantInfo host({int version = 1}) => lk_models.ParticipantInfo(
  sid: 'PA_host',
  identity: 'host',
  state: lk_models.ParticipantInfo_State.ACTIVE,
  version: version,
  tracks: [lk_models.TrackInfo(sid: 'TR_cam', type: lk_models.TrackType.VIDEO, source: lk_models.TrackSource.CAMERA)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  Room? room;
  tearDown(() async => room?.dispose());

  test('a rejoin to a node where the host appears just after the JoinResponse: no left / joined', () async {
    // blr1 lists the host; sgp1 does not yet (the relay attaches after the join)
    final server = FakeSignalServer()
      ..joinResponse = ((uri) => fakeJoinResponse(others: uri.host.startsWith('sgp1') ? [] : [host()]));
    final pcs = FakePcFactory();
    final r = room = await connectedFakeRoom(server, pcs, url: 'wss://blr1.example');
    final hostObject = r.remoteParticipants['host'];
    expect(hostObject, isNotNull);

    final log = <String>[];
    r.events.listen((e) {
      if (e is ParticipantConnectedEvent) log.add('+${e.participant.identity}');
      if (e is ParticipantDisconnectedEvent) log.add('-${e.participant.identity}');
      if (e is TrackUnpublishedEvent) log.add('unpublished ${e.publication.sid}');
      if (e is RoomReconnectedEvent) log.add('reconnected');
    });
    // the relay delivers the host ~50 ms after the join
    server.afterJoin = (ws) => Future<void>.delayed(
      const Duration(milliseconds: 50),
      () => ws.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host(version: 2)]))),
    );
    autoConnectPcs(pcs);
    await r.engine.restartConnection(regionUrl: 'wss://sgp1.example');
    expect(await eventually(() => log.contains('reconnected'), timeout: const Duration(seconds: 4)), isTrue);
    await settle(300);

    expect(log.where((e) => e.startsWith('+') || e.startsWith('-')), isEmpty, reason: 'base: -host then +host');
    expect(log.where((e) => e.startsWith('unpublished')), isEmpty);
    expect(identical(r.remoteParticipants['host'], hostObject), isTrue);
  });

  test('a kept participant that does not reappear within the grace is reported gone, once', () async {
    final server = FakeSignalServer()
      ..joinResponse = ((uri) => fakeJoinResponse(others: uri.host.startsWith('sgp1') ? [] : [host()]));
    final pcs = FakePcFactory();
    final r = room = await connectedFakeRoom(
      server,
      pcs,
      url: 'wss://blr1.example',
      roomOptions: RoomOptions(
        reconnectPolicy: FastPolicy(),
        recovery: const GravixRecoveryOptions(
          rejoinAbsentGrace: Duration(seconds: 30),
          rejoinAbsentMoveGrace: Duration(milliseconds: 300),
        ),
      ),
    );
    final log = <String>[];
    r.events.listen((e) {
      if (e is ParticipantConnectedEvent) log.add('+${e.participant.identity}');
      if (e is ParticipantDisconnectedEvent) log.add('-${e.participant.identity}');
      if (e is RoomReconnectedEvent) log.add('reconnected');
    });
    autoConnectPcs(pcs);
    await r.engine.restartConnection(regionUrl: 'wss://sgp1.example');
    expect(await eventually(() => log.contains('reconnected'), timeout: const Duration(seconds: 4)), isTrue);
    expect(log.where((e) => e.startsWith('-')), isEmpty, reason: 'still within the grace');
    expect(r.remoteParticipants.containsKey('host'), isTrue);
    await settle(500);
    expect(log.where((e) => e.startsWith('-')), ['-host']);
    expect(log.where((e) => e.startsWith('+')), isEmpty);
    expect(r.remoteParticipants.containsKey('host'), isFalse);
  });

  // Gulf test 2026-11-04, step c (Motorola, room gulf-test-c). The move to blr1 at 03:44:22.86;
  // the JoinResponse did not list the host, and the grace (5 s) ended at exactly 03:44:27.865:
  // "Remote user left", with the host's audio and video playing since 03:44:24. The host came
  // back at 03:44:52.83, the 30 s relay sweep, and nothing was subscribed until the leave.
  group('a move to a node where the room was just created', () {
    const short = GravixRecoveryOptions(
      rejoinAbsentGrace: Duration(milliseconds: 100),
      rejoinAbsentMoveGrace: Duration(milliseconds: 100),
    );

    Future<(Room, FakeSignalServer, FakePcFactory, List<String>)> joined({
      GravixRecoveryOptions recovery = short,
    }) async {
      final server = FakeSignalServer()
        ..joinResponse = ((uri) => fakeJoinResponse(others: uri.host.startsWith('sgp1') ? [] : [host()]));
      final pcs = FakePcFactory();
      final r = room = await connectedFakeRoom(
        server,
        pcs,
        url: 'wss://blr1.example',
        roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
      );
      final log = <String>[];
      r.events.listen((e) {
        if (e is ParticipantConnectedEvent) log.add('+${e.participant.identity}');
        if (e is ParticipantDisconnectedEvent) log.add('-${e.participant.identity}');
        if (e is RoomReconnectedEvent) log.add('reconnected');
      });
      autoConnectPcs(pcs);
      return (r, server, pcs, log);
    }

    test('an update right behind the JoinResponse, before the grace is armed, counts', () async {
      final (r, server, _, log) = await joined();
      server.afterJoin = (ws) =>
          ws.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host(version: 2)])));
      await r.engine.restartConnection(regionUrl: 'wss://sgp1.example');
      expect(await eventually(() => log.contains('reconnected'), timeout: const Duration(seconds: 4)), isTrue);
      await settle(300);
      expect(log.where((e) => e.startsWith('-')), isEmpty, reason: 'the host never left');
      expect(r.remoteParticipants.containsKey('host'), isTrue);
    });

    test('media arriving proves the participant is there, update or not', () async {
      final (r, server, _, log) = await joined();
      final subscribed = <String>[];
      r.events.listen((e) {
        if (e is TrackSubscribedEvent) subscribed.add(e.publication.sid);
        if (e is TrackUnsubscribedEvent) subscribed.add('-${e.publication.sid}');
      });
      await r.engine.restartConnection(regionUrl: 'wss://sgp1.example');
      expect(await eventually(() => log.contains('reconnected'), timeout: const Duration(seconds: 4)), isTrue);
      final t = FakeMediaTrack('TR_cam', kind: 'video');
      r.engine.events.emit(
        EngineTrackAddedEvent(
          track: t,
          stream: FakeMediaStream([t], id: 'PA_host|TR_cam'),
          receiver: FakeReceiver(),
        ),
      );
      expect(await eventually(() => subscribed.contains('TR_cam')), isTrue);
      await settle(300);
      expect(log.where((e) => e.startsWith('-')), isEmpty, reason: 'its video is playing');
      expect(r.remoteParticipants['host']?.trackPublications['TR_cam']?.track, isNotNull);
      expect(subscribed.last, 'TR_cam', reason: 'and it keeps playing');
    });

    test('a really gone participant is still reported: a move waits longer than a rejoin', () async {
      final (r, server, _, log) = await joined(
        recovery: const GravixRecoveryOptions(
          rejoinAbsentGrace: Duration(milliseconds: 50),
          rejoinAbsentMoveGrace: Duration(milliseconds: 500),
        ),
      );
      await r.engine.restartConnection(regionUrl: 'wss://sgp1.example');
      expect(await eventually(() => log.contains('reconnected'), timeout: const Duration(seconds: 4)), isTrue);
      await settle(200);
      expect(log.where((e) => e.startsWith('-')), isEmpty, reason: 'relay info may take up to the sweep');
      await settle(500);
      expect(log.where((e) => e.startsWith('-')), ['-host']);
    });

    test('the same node keeps the short grace: its room had everyone already', () async {
      final server = FakeSignalServer()..joinResponse = ((uri) => fakeJoinResponse(others: [host()]));
      final pcs = FakePcFactory();
      final r = room = await connectedFakeRoom(
        server,
        pcs,
        url: 'wss://blr1.example',
        roomOptions: RoomOptions(
          reconnectPolicy: FastPolicy(),
          recovery: const GravixRecoveryOptions(
            rejoinAbsentGrace: Duration(milliseconds: 50),
            rejoinAbsentMoveGrace: Duration(seconds: 30),
          ),
        ),
      );
      final log = <String>[];
      r.events.listen((e) {
        if (e is ParticipantDisconnectedEvent) log.add('-${e.participant.identity}');
        if (e is RoomReconnectedEvent) log.add('reconnected');
      });
      autoConnectPcs(pcs);
      server.joinResponse = (uri) => fakeJoinResponse();
      await r.engine.restartConnection(regionUrl: 'wss://blr1.example');
      expect(await eventually(() => log.contains('reconnected'), timeout: const Duration(seconds: 4)), isTrue);
      await settle(300);
      expect(log, contains('-host'));
    });

    test('a participant dropped by the grace and back with the same session is pulled again', () async {
      final (r, server, _, log) = await joined(
        recovery: const GravixRecoveryOptions(
          rejoinAbsentGrace: Duration(milliseconds: 50),
          rejoinAbsentMoveGrace: Duration(milliseconds: 50),
        ),
      );
      await r.engine.restartConnection(regionUrl: 'wss://sgp1.example');
      expect(await eventually(() => log.contains('-host'), timeout: const Duration(seconds: 4)), isTrue);
      final ws = server.sockets.last;
      final before = ws.sent.where((q) => q.hasSubscription()).length;
      ws.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [host(version: 3)])));
      expect(await eventually(() => log.contains('+host')), isTrue);
      expect(
        await eventually(() => ws.sent.where((q) => q.hasSubscription()).length >= before + 2),
        isTrue,
        reason: 'the server holds its subscription; only a new pull delivers the track again',
      );
      final subs = ws.sent.where((q) => q.hasSubscription()).skip(before).map((q) => q.subscription).toList();
      expect(subs.first.subscribe, isFalse);
      expect(subs.last.subscribe, isTrue);
      expect(subs.last.trackSids, ['TR_cam']);
    });

    test('someone new with that identity is not pulled again', () async {
      final (r, server, _, log) = await joined(
        recovery: const GravixRecoveryOptions(
          rejoinAbsentGrace: Duration(milliseconds: 50),
          rejoinAbsentMoveGrace: Duration(milliseconds: 50),
        ),
      );
      await r.engine.restartConnection(regionUrl: 'wss://sgp1.example');
      expect(await eventually(() => log.contains('-host'), timeout: const Duration(seconds: 4)), isTrue);
      final ws = server.sockets.last;
      final before = ws.sent.where((q) => q.hasSubscription()).length;
      final back = host(version: 1)..sid = 'PA_host2';
      ws.deliver(lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [back])));
      expect(await eventually(() => log.contains('+host')), isTrue);
      await settle(800);
      expect(ws.sent.where((q) => q.hasSubscription()).length, before);
    });
  });
}

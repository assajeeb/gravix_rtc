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
        recovery: const GravixRecoveryOptions(rejoinAbsentGrace: Duration(milliseconds: 300)),
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
}

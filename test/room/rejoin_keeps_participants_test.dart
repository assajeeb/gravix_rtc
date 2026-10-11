// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// S5 / R6, field 2026-10-09 (Pakhi viewer): the full rejoin emitted
// ParticipantDisconnected + ParticipantConnected for the host, who never left;
// the app logged "Remote user ItSLAUj593 left / offline". Upstream 2.13.0 only
// avoided the full reconnect for a migration (Leave{RESUME}, ported in
// reconnect_dispatch_test.dart); a real full rejoin still dropped everyone.
//
// keepParticipantsOnRejoin: the RemoteParticipant objects of identities still
// in the room are kept (same objects, same publications); their old tracks are
// unsubscribed and the new connection's tracks are subscribed on the same
// publications; only identities that really left get ParticipantDisconnected,
// and only new identities ParticipantConnected.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

lk_models.ParticipantInfo person(String id, {bool camera = false}) => lk_models.ParticipantInfo(
  sid: 'PA_$id',
  identity: id,
  state: lk_models.ParticipantInfo_State.ACTIVE,
  tracks: [
    if (camera)
      lk_models.TrackInfo(sid: 'TR_${id}_cam', type: lk_models.TrackType.VIDEO, source: lk_models.TrackSource.CAMERA),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  Room? room;
  tearDown(() async => room?.dispose());

  late List<lk_models.ParticipantInfo> inRoom;

  void subscribeCamera(Room r, String id) {
    final t = FakeMediaTrack('TR_${id}_cam', kind: 'video');
    r.engine.events.emit(
      EngineTrackAddedEvent(
        track: t,
        stream: FakeMediaStream([t], id: 'PA_$id|TR_${id}_cam'),
        receiver: FakeReceiver(),
      ),
    );
  }

  Future<Room> joined({GravixRecoveryOptions recovery = const GravixRecoveryOptions()}) async {
    inRoom = [person('host', camera: true), person('cat')];
    server = FakeSignalServer()..joinResponse = ((_) => fakeJoinResponse(others: inRoom));
    pcs = FakePcFactory();
    final r = await connectedFakeRoom(
      server,
      pcs,
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
    subscribeCamera(r, 'host');
    expect(
      await eventually(() => r.remoteParticipants['host']?.trackPublications['TR_host_cam']?.track != null),
      isTrue,
    );
    return r;
  }

  Future<List<String>> rejoin(Room r) async {
    final log = <String>[];
    r.events.listen((e) {
      if (e is ParticipantConnectedEvent) log.add('+${e.participant.identity}');
      if (e is ParticipantDisconnectedEvent) log.add('-${e.participant.identity}');
      if (e is TrackUnsubscribedEvent) log.add('unsub ${e.publication.sid}');
      if (e is TrackSubscribedEvent) log.add('sub ${e.publication.sid}');
      if (e is RoomReconnectedEvent) log.add('reconnected');
    });
    // during the outage cat left and bob joined
    inRoom = [person('host', camera: true), person('bob')];
    autoConnectPcs(pcs);
    await r.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(await eventually(() => log.contains('reconnected'), timeout: const Duration(seconds: 4)), isTrue);
    subscribeCamera(r, 'host'); // the new subscriber connection delivers the camera again
    await eventually(() => log.contains('sub TR_host_cam'));
    await settle();
    return log;
  }

  test('a full rejoin keeps the host: same objects, tracks resubscribed, only real leaves/joins reported', () async {
    // (0.4.15 F6: a kept identity the JoinResponse does not list is reported gone
    // after rejoinAbsentGrace; short here)
    final r = await joined(recovery: const GravixRecoveryOptions(rejoinAbsentGrace: Duration(milliseconds: 200)));
    room = r;
    final host = r.remoteParticipants['host']!;
    final pub = host.trackPublications['TR_host_cam']!;
    final oldTrack = pub.track;
    final log = await rejoin(r);
    await settle(300); // cat's grace runs out: it really left
    expect(log.where((e) => e.startsWith('-')), ['-cat'], reason: 'base: -host -cat');
    expect(log.where((e) => e.startsWith('+')), ['+bob'], reason: 'base: +host +bob');
    expect(identical(r.remoteParticipants['host'], host), isTrue, reason: 'base: a new object');
    expect(identical(host.trackPublications['TR_host_cam'], pub), isTrue);
    expect(pub.track, isNotNull);
    expect(identical(pub.track, oldTrack), isFalse, reason: 'the new connection\'s track');
    expect(log, containsAllInOrder(['unsub TR_host_cam', 'reconnected']));
    expect(r.remoteParticipants.keys, unorderedEquals(['host', 'bob']));
  });

  test('keepParticipantsOnRejoin: false keeps the 0.4.14 contract (drop all, re-announce)', () async {
    final r = await joined(recovery: const GravixRecoveryOptions(keepParticipantsOnRejoin: false));
    room = r;
    final host = r.remoteParticipants['host']!;
    final log = await rejoin(r);
    expect(log.where((e) => e.startsWith('-')), unorderedEquals(['-host', '-cat']));
    expect(log.where((e) => e.startsWith('+')), unorderedEquals(['+host', '+bob']));
    expect(identical(r.remoteParticipants['host'], host), isFalse);
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// PERF (2026-10-11): the signal client, the room and every participant log each
// event they see at FINE / FINER with the event in the message
// ('[SignalEvent] $event'). Dart builds an interpolated string BEFORE the call,
// so every event's toString() ran in release builds too, where the default
// level (INFO) then dropped the line. For protobuf-carrying events that is the
// whole message printed as text: UNIT bench (bench_pkg/hot_path_bench_test.dart)
// 6.3 µs and a 1.5 KB string per one-participant update, 23.7 µs for four,
// 5.9 µs per updateFromInfo, ~0 once guarded.
//
// Checked here: at the default level no event is stringified; with logging on
// (FINE / FINER) the same lines as before are produced.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:logging/logging.dart';

import '../support/fake_rtc.dart';

class _CountedSignal with SignalEvent, InternalEvent {
  int n = 0;
  @override
  String toString() {
    n++;
    return 'CountedSignal';
  }
}

class _CountedRoom with RoomEvent {
  int n = 0;
  @override
  String toString() {
    n++;
    return 'CountedRoom';
  }
}

class _CountedParticipant with ParticipantEvent {
  int n = 0;
  @override
  String toString() {
    n++;
    return 'CountedParticipant';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  final rootLevel = Logger.root.level;
  tearDown(() => Logger.root.level = rootLevel);

  Future<void> emitAll(dynamic room, _CountedSignal s, _CountedRoom r, _CountedParticipant p) async {
    room.engine.signalClient.events.emit(s);
    room.events.emit(r);
    room.localParticipant!.events.emit(p);
    // the emitters are async broadcast streams
    await settle(30);
  }

  test('default level (INFO): no event is turned into a string', () async {
    expect(Logger.root.level, Level.INFO, reason: 'package:logging default');
    final room = await connectedFakeRoom(FakeSignalServer(), FakePcFactory());
    final s = _CountedSignal(), r = _CountedRoom(), p = _CountedParticipant();
    await emitAll(room, s, r, p);
    expect(s.n, 0, reason: "SignalClient built '[SignalEvent] \$event' for nothing");
    expect(r.n, 0, reason: "Room built '[RoomEvent] \$event' for nothing");
    expect(p.n, 0, reason: "Participant built '[ParticipantEvent] \$event' for nothing");
    await room.dispose();
  });

  test('logging on (FINEST): the same lines as before', () async {
    Logger.root.level = Level.FINEST;
    final lines = <String>[];
    final sub = Logger.root.onRecord.listen((rec) => lines.add('${rec.level.name} ${rec.message}'));
    final others = [
      lk_models.ParticipantInfo(sid: 'PA_host', identity: 'host', state: lk_models.ParticipantInfo_State.ACTIVE),
    ];
    final server = FakeSignalServer()..joinResponse = ((_) => fakeJoinResponse(others: others));
    final room = await connectedFakeRoom(server, FakePcFactory());
    final s = _CountedSignal(), r = _CountedRoom(), p = _CountedParticipant();
    await emitAll(room, s, r, p);
    await sub.cancel();
    expect(lines, contains('FINE [SignalEvent] CountedSignal'));
    expect(lines, contains('FINER [RoomEvent] CountedRoom, will notifyListeners()'));
    expect(lines, contains('FINER [ParticipantEvent] CountedParticipant, will notifyListeners()'));
    expect(lines.where((l) => l.startsWith('FINE RemoteParticipant.updateFromInfo(info: ')), isNotEmpty);
    expect(lines.where((l) => l.startsWith('FINE LocalParticipant.updateFromInfo(info: ')), isNotEmpty);
    await room.dispose();
  });
}

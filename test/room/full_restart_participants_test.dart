// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Emulator proof 2026-10-02 (tester 0.3.6, airplane mode 4 s -> a resume that
// escalated to a full restart): the tester logged participant_left for the
// observer and never a join, although the observer never left. A full restart
// drops every remote participant (ParticipantDisconnectedEvent each, so the room
// service called onUserOffline for everyone) and re-created them from the new
// JoinResponse WITHOUT a ParticipantConnectedEvent (so no onUserJoined): an app
// keeping its user list from either ended up empty.
//
// Now: the room announces every re-created participant before
// RoomReconnectedEvent (new objects, so apps holding the old ones get the live
// ones), and the service's identity callbacks report only the real changes.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

lk_models.ParticipantInfo _p(String identity) =>
    lk_models.ParticipantInfo(sid: 'PA_$identity', identity: identity, name: identity);

lk_rtc.JoinResponse _join(List<String> others) => lk_rtc.JoinResponse(
  room: lk_models.Room(name: 'r', sid: 'RM_r'),
  participant: _p('me'),
  otherParticipants: others.map(_p),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GravixAudioRouting.v2 = false;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('gravity.music_mixer'), (call) async => true);
    m.setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);
    for (final name in const ['com.ryanheise.android_audio_manager', 'com.ryanheise.av_audio_session']) {
      m.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => switch (call.method) {
          'getDevices' => <dynamic>[],
          'getMode' => 0,
          'isBluetoothScoOn' => false,
          _ => null,
        },
      );
    }
    m.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
    );
  });

  // a service bound to a real Room whose engine events the test drives
  Future<(GravixRoomService, Room, List<String>, List<String>, List<String>)> inRoomWith(List<String> others) async {
    final joined = <String>[], offline = <String>[], roomEvents = <String>[];
    final s = GravixRoomService(connectRoom: (room, url, token) async {}, applyMic: (_) async {});
    await s.connect(url: 'wss://a.example', token: 't', publishMic: false);
    final room = s.room!;
    s.onUserJoined = joined.add;
    s.onUserOffline = offline.add;
    room.events.listen((e) {
      if (e is ParticipantConnectedEvent) roomEvents.add('+${e.participant.identity}');
      if (e is ParticipantDisconnectedEvent) roomEvents.add('-${e.participant.identity}');
      if (e is RoomReconnectedEvent) roomEvents.add('reconnected');
    });
    room.engine.events.emit(EngineJoinResponseEvent(response: _join(others)));
    await pump();
    expect(room.remoteParticipants.keys, unorderedEquals(others));
    roomEvents.clear();
    return (s, room, joined, offline, roomEvents);
  }

  Future<void> fullRestart(Room room, List<String> stillThere) async {
    room.engine.events.emit(const EngineFullRestartingEvent());
    await pump();
    room.engine.events.emit(EngineJoinResponseEvent(response: _join(stillThere)));
    await pump();
    room.engine.events.emit(const EngineRestartedEvent());
    await pump();
  }

  test('full restart, nobody changed: the list stays whole, no identity callback', () async {
    final (_, room, joined, offline, roomEvents) = await inRoomWith(['ann', 'bob']);
    final before = room.remoteParticipants['ann'];
    await fullRestart(room, ['ann', 'bob']);
    expect(room.remoteParticipants.keys, unorderedEquals(['ann', 'bob']));
    expect(joined, isEmpty);
    expect(offline, isEmpty, reason: 'before 0.4.6: [ann, bob] and never a join');
    // the room level: one disconnect and one connect each, the connects before "reconnected"
    expect(roomEvents.where((e) => e.startsWith('-')), unorderedEquals(['-ann', '-bob']));
    expect(roomEvents.where((e) => e.startsWith('+')), unorderedEquals(['+ann', '+bob']));
    expect(roomEvents.last, 'reconnected');
    expect(identical(room.remoteParticipants['ann'], before), isFalse, reason: 'a new object, announced');
  });

  test('one left during the outage, one joined: only offline for the leaver, only joined for the newcomer', () async {
    final (_, room, joined, offline, roomEvents) = await inRoomWith(['ann', 'bob']);
    await fullRestart(room, ['ann', 'cat']);
    expect(offline, ['bob']);
    expect(joined, ['cat']);
    expect(room.remoteParticipants.keys, unorderedEquals(['ann', 'cat']));
    expect(roomEvents.where((e) => e.startsWith('+')), unorderedEquals(['+ann', '+cat']));
    expect(roomEvents.last, 'reconnected');
  });

  test('outside a restart a leave is reported at once; the next restart starts clean', () async {
    final (_, room, joined, offline, _) = await inRoomWith(['ann', 'bob']);
    await fullRestart(room, ['ann', 'bob']);
    // a plain leave after the restart (the room event a DISCONNECTED update produces)
    room.events.emit(ParticipantDisconnectedEvent(participant: room.remoteParticipants['ann']!));
    await pump();
    expect(offline, contains('ann'));
    expect(joined, isEmpty);
  });

  test('the room disconnects in the middle of a restart: the dropped ones are reported offline', () async {
    final (_, room, joined, offline, _) = await inRoomWith(['ann']);
    room.engine.events.emit(const EngineFullRestartingEvent());
    await pump();
    expect(offline, isEmpty, reason: 'not known yet whether ann left');
    room.events.emit(RoomDisconnectedEvent(reason: DisconnectReason.reconnectAttemptsExceeded));
    await pump();
    expect(offline, ['ann']);
    expect(joined, isEmpty);
  });
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

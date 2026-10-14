// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// PERF (2026-10-11): steady-state cost must not grow across rejoins. A viewer
// on a bad network can go through dozens of resumes / full rejoins in one
// session (field 2026-10-10, Pakhi viewer); a timer or listener left behind by
// each one is a cost that grows for the rest of the call, and anything still
// running after dispose is a cost for the rest of the app's life.
//
// join -> rejoin x20 -> disconnect -> dispose, over the recovery fakes, inside a
// zone that tracks every Timer. Checked:
//  - listener counts on the room / engine / signal client / remote participant
//    after each rejoin equal those after the first one (no growth);
//  - live periodic timers after each rejoin equal those after the first one;
//  - after dispose: no periodic timer alive, no one-shot timer left pending, and
//    the process-wide monitors (mic state, background guard) hold no room.
// Not covered: the connectivity subscription (skipped under flutter test, see
// SignalClient.networkIsAvailable), native objects, and stream subscriptions
// that do not go through an EventsListener.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_background_guard.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_mic_state.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

/// Every Timer created in the zone, live until cancelled or (one-shot) fired.
class _TimerLedger {
  final live = <_Tracked>{};
  int created = 0;

  ZoneSpecification get spec => ZoneSpecification(
    createTimer: (self, parent, zone, duration, f) {
      late _Tracked t;
      final inner = parent.createTimer(zone, duration, () {
        live.remove(t);
        f();
      });
      t = _Tracked(inner, periodic: false, duration: duration, stack: StackTrace.current, ledger: this);
      live.add(t);
      created++;
      return t;
    },
    createPeriodicTimer: (self, parent, zone, period, f) {
      late _Tracked t;
      final inner = parent.createPeriodicTimer(zone, period, (_) => f(t));
      t = _Tracked(inner, periodic: true, duration: period, stack: StackTrace.current, ledger: this);
      live.add(t);
      created++;
      return t;
    },
  );

  Iterable<_Tracked> get periodic => live.where((t) => t.periodic);
  Iterable<_Tracked> get oneShot => live.where((t) => !t.periodic);

  /// The SDK frame that created the timer (first non-zone, non-test frame).
  static String origin(_Tracked t) {
    final lines = t.stack.toString().split('\n');
    return lines.firstWhere(
      (l) => l.contains('package:gravix_rtc/') && !l.contains('rejoin_leak_test.dart'),
      orElse: () => lines.length > 2 ? lines[2] : lines.first,
    );
  }

  String describe(Iterable<_Tracked> ts) => ts
      .map((t) => '${t.periodic ? 'periodic' : 'one-shot'} ${t.duration.inMilliseconds} ms @ ${origin(t).trim()}')
      .join('\n');
}

class _Tracked implements Timer {
  _Tracked(this.inner, {required this.periodic, required this.duration, required this.stack, required this.ledger});
  final Timer inner;
  final bool periodic;
  final Duration duration;
  final StackTrace stack;
  final _TimerLedger ledger;
  @override
  void cancel() {
    ledger.live.remove(this);
    inner.cancel();
  }

  @override
  bool get isActive => inner.isActive;
  @override
  int get tick => inner.tick;
}

lk_models.ParticipantInfo _person(String id, {bool camera = false, bool mic = false}) => lk_models.ParticipantInfo(
  sid: 'PA_$id',
  identity: id,
  state: lk_models.ParticipantInfo_State.ACTIVE,
  tracks: [
    if (camera)
      lk_models.TrackInfo(sid: 'TR_${id}_cam', type: lk_models.TrackType.VIDEO, source: lk_models.TrackSource.CAMERA),
    if (mic)
      lk_models.TrackInfo(
        sid: 'TR_${id}_mic',
        type: lk_models.TrackType.AUDIO,
        source: lk_models.TrackSource.MICROPHONE,
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  test('join -> rejoin x20 -> disconnect -> dispose: no growth, nothing left running', () async {
    final ledger = _TimerLedger();
    final report = <String>[];

    await runZoned(() async {
      final inRoom = [_person('host', camera: true, mic: true), _person('cohost', camera: true, mic: true)];
      final server = FakeSignalServer()..joinResponse = ((_) => fakeJoinResponse(others: inRoom));
      final pcs = FakePcFactory();
      final room = await connectedFakeRoom(
        server,
        pcs,
        // short grace so the rejoin's absent-participant timers settle inside the test
        roomOptions: RoomOptions(
          reconnectPolicy: FastPolicy(),
          adaptiveStream: true, // Pakhi video rooms: the 300 ms visibility timer per remote video
          // (2026-10-14) the ICE transport watch's one periodic timer starts its first
          // reading interval after a connection connected: short here so it exists
          // before the baseline count
          recovery: const GravixRecoveryOptions(
            rejoinAbsentGrace: Duration(milliseconds: 100),
            iceTransportWatch: Duration(milliseconds: 100),
          ),
        ),
      );

      void subscribeAll() {
        for (final p in inRoom) {
          for (final t in p.tracks) {
            final kind = t.type == lk_models.TrackType.VIDEO ? 'video' : 'audio';
            final mt = FakeMediaTrack(t.sid, kind: kind);
            room.engine.events.emit(
              EngineTrackAddedEvent(
                track: mt,
                stream: FakeMediaStream([mt], id: '${p.sid}|${t.sid}'),
                receiver: FakeReceiver(),
              ),
            );
          }
        }
      }

      bool allSubscribed() => inRoom.every(
        (p) => p.tracks.every((t) => room.remoteParticipants[p.identity]?.trackPublications[t.sid]?.track != null),
      );

      subscribeAll();
      expect(await eventually(allSubscribed), isTrue, reason: 'initial subscriptions');

      ({int room, int engine, int signal, int host, int periodic}) counts() => (
        room: room.events.listeners.length,
        engine: room.engine.events.listeners.length,
        signal: room.engine.signalClient.events.listeners.length,
        host: room.remoteParticipants['host']?.events.listeners.length ?? -1,
        periodic: ledger.periodic.length,
      );

      Future<void> rejoinOnce(int i) async {
        var reconnected = false;
        final cancel = room.events.on<RoomReconnectedEvent>((_) => reconnected = true);
        autoConnectPcs(pcs);
        // a full rejoin each time (new peer connections, new remote tracks on
        // the kept publications): run 2 created 2 + 20 x 2 peer connections
        room.engine.fullReconnectOnNext = true;
        await room.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
        expect(await eventually(() => reconnected, timeout: const Duration(seconds: 4)), isTrue, reason: 'rejoin $i');
        await cancel();
        subscribeAll(); // the new subscriber connection delivers the tracks again
        expect(await eventually(allSubscribed), isTrue, reason: 'resubscribed $i');
        await settle(150); // absent grace + debounce timers fire
      }

      final before = counts();
      report.add('after join: $before');
      await rejoinOnce(0);
      final first = counts();
      report.add('after rejoin 1: $first');
      for (var i = 1; i < 20; i++) {
        await rejoinOnce(i);
      }
      final last = counts();
      report.add('peer connections created: ${pcs.all.length} (2 per full rejoin)');
      report.add('after rejoin 20: $last');
      report.add('live periodic after rejoin 20:\n${ledger.describe(ledger.periodic)}');

      expect(last.room, first.room, reason: 'room listeners grew across rejoins\n${report.join('\n')}');
      expect(last.engine, first.engine, reason: 'engine listeners grew across rejoins\n${report.join('\n')}');
      expect(last.signal, first.signal, reason: 'signal listeners grew across rejoins\n${report.join('\n')}');
      expect(last.host, first.host, reason: 'participant listeners grew across rejoins\n${report.join('\n')}');
      expect(last.periodic, first.periodic, reason: 'periodic timers grew across rejoins\n${report.join('\n')}');
      expect(pcs.all.length, 2 + 20 * 2, reason: 'every cycle must be a full rejoin');

      await room.disconnect();
      await room.dispose();
      // one-shot timers still pending must be short ones that fire now
      await settle(500);
    }, zoneSpecification: ledger.spec);

    report.add('timers created in total: ${ledger.created}');
    report.add('after dispose, periodic:\n${ledger.describe(ledger.periodic)}');
    report.add('after dispose, one-shot:\n${ledger.describe(ledger.oneShot)}');
    // ignore: avoid_print
    print(report.join('\n'));
    expect(
      ledger.periodic,
      isEmpty,
      reason: 'periodic timers alive after dispose:\n${ledger.describe(ledger.periodic)}',
    );
    expect(
      ledger.oneShot,
      isEmpty,
      reason: 'one-shot timers pending after dispose:\n${ledger.describe(ledger.oneShot)}',
    );
    expect(GravixMicMonitor.instance.attachedRooms, 0, reason: 'mic monitor still holds a room');
    expect(GravixBackgroundGuard.instance.attachedRooms, 0, reason: 'background guard still holds a room');
  });
}

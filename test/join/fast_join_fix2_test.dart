// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join, gaps found by two apps' migrations (2026-10-15):
//  - markShown(): an app that knows its screen is shown (drawn under an overlay)
//    says so; from then on a Home press never leaves.
//  - A session whose Room is gone (the server ended it / a kick: the Room's
//    RoomDisconnectedEvent; or the app disposed it) was handed out again by
//    pendingFor / prepare / attach. An app dropped it by hand.
//    It is now treated as ended (GravixPrejoinEndReason.roomGone): the next
//    prepare / attach joins fresh. A resume (the signal reads `disconnected`
//    while it dials) is NOT a gone Room.
//  - warm(activity: false): an app refreshes its own room's token every 40 s; with
//    warm(role: ownRegion) that counted as user activity and kept the standby
//    pool rotating forever.
//  - An app: attach(request) with nothing pending joined cold with the
//    constructor's hooks; attach now takes the per-join hooks prepare takes.
//  - Lead decision (6): prepare(abandonInBackground:) per handle: a host's own
//    Go Live join starts at the tap and its screen is pushed only after the app's
//    Go Live flow; a Home press in that window must not abandon it.
//  - Lead decision (7): a dead Room (disconnected after the connect, or disposed)
//    is ended (`roomGone`) and NEVER left again through the app's leave hook,
//    also when superseded / abandoned: the app's own disconnect handling owns
//    that cleanup (a viewer rejoin after a drop must not stop and restart the
//    audio session). The SDK disposes only a Room it built itself with the
//    default createRoom and the default leave.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

import '../support/fake_rtc.dart' as fake;

const url = 'wss://rtc.example.test';

String jwt(String room, {int n = 0}) {
  String part(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000;
  return [
    part({'alg': 'HS256'}),
    part({
      'sub': 'u1',
      'n': n,
      'exp': exp,
      'video': {'room': room, 'roomJoin': true},
    }),
    'c2ln',
  ].join('.');
}

class Rig {
  Rig({DateTime Function()? clock}) : _clock = clock;
  final DateTime Function()? _clock;
  final log = <String>[];
  final rooms = <Room>[];
  final opened = <String>[];
  int fetches = 0;

  late final tokens = GravixTokenProvider.callback((r) async {
    fetches++;
    return {'token': jwt(r.room, n: fetches), 'url': url};
  }, reuse: GravixTokenReuse.fastJoin);

  late final pool = GravixStandbyPool(
    opener: (u, t, rtt) async {
      opened.add(u);
      return true;
    },
    inForeground: () => true,
    autoTick: false,
    clock: _clock,
  );

  late final join = GravixJoin(
    tokenProvider: tokens,
    standbyPool: pool,
    bindStandbyLifecycle: false,
    createRoom: () => newRoom('ctor'),
    connect: (room, t) async => log.add('connect ctor'),
    leave: (room) async => log.add('leave ctor ${rooms.indexOf(room)}'),
  );

  Room newRoom(String by) {
    final r = Room();
    rooms.add(r);
    log.add('room $by');
    return r;
  }

  Future<void> dispose(WidgetTester tester) => tester.runAsync(() async {
    await GravixPrejoin.debugEndAll();
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });
}

GravixTokenRequest req(String room) => GravixTokenRequest(room: room, identity: 'u1');

void background(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void foreground(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

GravixPrejoin startFake(List<Room> rooms, List<Room> leaves, {String key = 'k1', Completer<void>? hold}) =>
    GravixPrejoin.start(
      key: key,
      target: () => const GravixJoinTarget(url: url, token: 't1'),
      createRoom: () {
        final r = Room();
        rooms.add(r);
        return r;
      },
      connect: (room, t) async => hold?.future,
      leave: (room) async => leaves.add(room),
    );

Future<void> disposeAll(WidgetTester tester, List<Room> rooms) => tester.runAsync(() async {
  for (final r in rooms) {
    if (!r.isDisposed) await r.dispose();
  }
});

void main() {
  tearDown(GravixPrejoin.debugEndAll);

  group('markShown', () {
    testWidgets('before attach (screen drawn under an overlay): Home does not leave', (tester) async {
      final rooms = <Room>[], leaves = <Room>[];
      final events = <GravixJoinEvent>[];
      final h = GravixPrejoin.start(
        key: 'k1',
        target: () => const GravixJoinTarget(url: url, token: 't1'),
        createRoom: () {
          final r = Room();
          rooms.add(r);
          return r;
        },
        connect: (room, t) async {},
        leave: (room) async => leaves.add(room),
        onEvent: events.add,
      );
      await tester.pump(Duration.zero);
      h.markShown();
      expect(events.where((e) => e.kind == GravixJoinEventKind.shown), hasLength(1));
      background(tester);
      await tester.pump(Duration.zero);
      expect(h.state, isNot(GravixPrejoinState.ended));
      expect(leaves, isEmpty);
      foreground(tester);
      expect(await h.attach(), isNotNull, reason: 'attach after markShown: no never-shown watch either');
      background(tester);
      await tester.pump(Duration.zero);
      expect(h.state, GravixPrejoinState.attached);
      foreground(tester);
      await disposeAll(tester, rooms);
    });

    testWidgets('after attach, before any frame: Home does not leave', (tester) async {
      final rooms = <Room>[], leaves = <Room>[];
      final h = startFake(rooms, leaves);
      await h.attach();
      h.markShown();
      background(tester);
      await tester.pump(Duration.zero);
      expect(h.state, GravixPrejoinState.attached);
      expect(leaves, isEmpty);
      foreground(tester);
      await disposeAll(tester, rooms);
    });

    testWidgets('on an ended handle: nothing (no event, no state change)', (tester) async {
      final rooms = <Room>[], leaves = <Room>[];
      final events = <GravixJoinEvent>[];
      final h = GravixPrejoin.start(
        key: 'k1',
        target: () => const GravixJoinTarget(url: url, token: 't1'),
        createRoom: () {
          final r = Room();
          rooms.add(r);
          return r;
        },
        connect: (room, t) async {},
        leave: (room) async => leaves.add(room),
        onEvent: events.add,
      );
      await h.abandon();
      h.markShown();
      expect(events.map((e) => e.kind), isNot(contains(GravixJoinEventKind.shown)));
      expect(h.state, GravixPrejoinState.ended);
      await disposeAll(tester, rooms);
    });
  });

  group('a session whose Room is gone', () {
    testWidgets(
      'attached, then the server ends it (kick): pendingFor null, roomGone, no second leave, next start fresh',
      (tester) async {
        final rooms = <Room>[], leaves = <Room>[];
        final h = startFake(rooms, leaves);
        final room = await h.attach();
        await tester.pump();
        expect(GravixPrejoin.pendingFor('k1'), same(h), reason: 'live: the same handle');
        room!.events.emit(RoomDisconnectedEvent(reason: DisconnectReason.participantRemoved));
        await tester.pump(Duration.zero);
        expect(GravixPrejoin.pendingFor('k1'), isNull);
        expect(await h.ended, GravixPrejoinEndReason.roomGone);
        expect(leaves, isEmpty, reason: 'the app\'s own disconnect handling owns the cleanup: no second leave');
        final next = startFake(rooms, leaves);
        expect(next, isNot(same(h)));
        expect(await next.attach(), isNot(same(room)));
        await tester.pump();
        await disposeAll(tester, rooms);
      },
    );

    testWidgets('attached, Room disposed by the app: attach() on it is null, the next start is fresh', (tester) async {
      final rooms = <Room>[], leaves = <Room>[];
      final h = startFake(rooms, leaves);
      final room = await h.attach();
      await tester.pump();
      await tester.runAsync(() => room!.dispose());
      expect(await h.attach(), isNull);
      expect(await h.ended, GravixPrejoinEndReason.roomGone);
      expect(leaves, isEmpty, reason: 'whoever disposed it tore it down: the leave hook does not run again');
      expect(GravixPrejoin.pendingFor('k1'), isNull);
      final next = startFake(rooms, leaves);
      expect(next, isNot(same(h)));
      expect(await next.attach(), isNot(same(room)));
      await tester.pump();
      await disposeAll(tester, rooms);
    });

    testWidgets('connected (not yet attached), Room disposed: pendingFor null', (tester) async {
      final rooms = <Room>[], leaves = <Room>[];
      final h = startFake(rooms, leaves);
      expect(await h.connected, isTrue);
      await tester.runAsync(() => h.room!.dispose());
      expect(GravixPrejoin.pendingFor('k1'), isNull);
      expect(await h.ended, GravixPrejoinEndReason.roomGone);
      await disposeAll(tester, rooms);
    });

    testWidgets('still connecting: the same handle (double tap, the screen\'s own attach)', (tester) async {
      final rooms = <Room>[], leaves = <Room>[];
      final hold = Completer<void>();
      final h = startFake(rooms, leaves, hold: hold);
      await tester.pump(Duration.zero);
      expect(startFake(rooms, leaves, hold: hold), same(h));
      expect(GravixPrejoin.pendingFor('k1'), same(h));
      hold.complete();
      expect(await h.attach(), isNotNull);
      expect(GravixPrejoin.pendingFor('k1'), same(h));
      await tester.pump();
      await disposeAll(tester, rooms);
    });

    testWidgets('GravixJoin: prepare / attach after a kick join cold; the dead one is not left again', (tester) async {
      final rig = Rig();
      final a = rig.join.prepare(req('a'));
      final room = await rig.join.attach(req('a'));
      await tester.pump();
      expect(rig.join.prepare(req('a')), same(a), reason: 'double tap: the same live session');
      room!.events.emit(RoomDisconnectedEvent(reason: DisconnectReason.participantRemoved));
      await tester.pump(Duration.zero);
      expect(rig.join.pending(req('a')), isNull);
      expect(rig.join.current, isNull);
      final again = await rig.join.attach(req('a'));
      expect(again, isNotNull);
      expect(again, isNot(same(room)));
      expect(rig.log.where((l) => l == 'connect ctor'), hasLength(2));
      expect(rig.log.where((l) => l.startsWith('leave')), isEmpty, reason: 'a dead Room is not left again');
      expect(await a.ended, GravixPrejoinEndReason.roomGone);
      await tester.pump();
      await rig.dispose(tester);
    });

    testWidgets('adopt over a live handle of the same key whose Room the app disposed: replaced, never left', (
      tester,
    ) async {
      final rooms = <Room>[], leaves = <Room>[];
      final h = startFake(rooms, leaves);
      final old = await h.attach();
      await tester.pump();
      await tester.runAsync(() => old!.dispose()); // the app's own teardown + reconnect
      final room = Room();
      rooms.add(room);
      final adopted = GravixPrejoin.adopt(key: 'k1', room: room, leave: (r) async => leaves.add(r));
      expect(await h.ended, GravixPrejoinEndReason.replaced);
      expect(leaves, isEmpty);
      expect(GravixPrejoin.pendingFor('k1'), same(adopted));
      await disposeAll(tester, rooms);
    });

    testWidgets('an adopted Room that is disposed is gone too', (tester) async {
      final rooms = <Room>[];
      final room = Room();
      rooms.add(room);
      final h = GravixPrejoin.adopt(key: 'k-guest', room: room, leave: (r) async {});
      expect(GravixPrejoin.pendingFor('k-guest'), same(h));
      await tester.runAsync(() => room.dispose());
      expect(GravixPrejoin.pendingFor('k-guest'), isNull);
      expect(await h.ended, GravixPrejoinEndReason.roomGone);
      await disposeAll(tester, rooms);
    });
  });

  group('prepare(abandonInBackground:)', () {
    testWidgets('false: the host\'s Go Live join survives Home before the screen; attach in the background', (
      tester,
    ) async {
      final rig = Rig();
      final h = rig.join.prepare(req('host'), abandonInBackground: false);
      await tester.pump(Duration.zero);
      background(tester); // Home during the app's Go Live flow
      await tester.pump(Duration.zero);
      expect(h.state, isNot(GravixPrejoinState.ended));
      expect(rig.join.pending(req('host')), same(h));
      final room = await rig.join.attach(req('host')); // the screen, the app still in the background
      expect(room, same(h.room));
      expect(rig.log.where((l) => l == 'connect ctor'), hasLength(1));
      foreground(tester);
      await tester.pump();
      await rig.dispose(tester);
    });

    testWidgets('the default still abandons a prepare on Home before the screen', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(req('v'));
      await tester.pump(Duration.zero);
      background(tester);
      expect(await h.ended, GravixPrejoinEndReason.background);
      foreground(tester);
      await rig.dispose(tester);
    });

    testWidgets('false: attachTimeout still applies, counting only foreground time (fix 2026-10-15)', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(req('host'), abandonInBackground: false);
      await tester.pump(Duration.zero);
      background(tester);
      await tester.pump(const Duration(seconds: 21));
      expect(h.state, GravixPrejoinState.connected, reason: 'the clock is paused while the app is away');
      foreground(tester);
      await tester.pump(const Duration(seconds: 21));
      expect(await h.ended, GravixPrejoinEndReason.attachTimeout);
      await rig.dispose(tester);
    });

    testWidgets('attach(request, abandonInBackground: false) cold: Home before the first frame keeps it', (
      tester,
    ) async {
      final rig = Rig();
      final room = await rig.join.attach(req('c'), abandonInBackground: false);
      expect(room, isNotNull);
      background(tester); // no frame yet
      await tester.pump(Duration.zero);
      expect(rig.join.pending(req('c'))?.state, GravixPrejoinState.attached);
      foreground(tester);
      await tester.pump();
      await rig.dispose(tester);
    });
  });

  group('dead Room = ended, never left again', () {
    testWidgets('a dead handle superseded by a new prepare: leave hook 0; ended roomGone', (tester) async {
      final rig = Rig();
      final a = rig.join.prepare(req('a'));
      final room = await rig.join.attach(req('a'));
      await tester.pump();
      room!.events.emit(RoomDisconnectedEvent(reason: DisconnectReason.participantRemoved));
      await tester.pump(Duration.zero);
      expect(GravixPrejoin.pendingFor(a.key), isNull);
      final b = rig.join.prepare(req('b'));
      expect(await b.attach(), isNotNull);
      expect(rig.log.where((l) => l.startsWith('leave')), isEmpty);
      expect(await a.ended, GravixPrejoinEndReason.roomGone);
      await tester.pump();
      await rig.dispose(tester);
    });

    testWidgets('a disposed (app torn down) handle superseded before any lookup: leave hook 0', (tester) async {
      final rig = Rig();
      final a = rig.join.prepare(req('a'));
      final room = await rig.join.attach(req('a'));
      await tester.pump();
      await tester.runAsync(() => room!.dispose()); // the app's own reconnect failed; it tore the Room down
      final b = rig.join.prepare(req('b')); // no pending()/current lookup in between
      expect(await b.attach(), isNotNull);
      expect(rig.log.where((l) => l.startsWith('leave')), isEmpty);
      expect(await a.ended, GravixPrejoinEndReason.roomGone);
      await tester.pump();
      await rig.dispose(tester);
    });

    testWidgets('a dead handle abandoned / left by the app: leave hook 0', (tester) async {
      final rig = Rig();
      final room = await rig.join.attach(req('a'));
      await tester.pump();
      room!.events.emit(RoomDisconnectedEvent(reason: DisconnectReason.participantRemoved));
      await tester.pump(Duration.zero);
      await rig.join.leave();
      await rig.join.abandon(req('a'));
      expect(rig.log.where((l) => l.startsWith('leave')), isEmpty);
      await rig.dispose(tester);
    });

    testWidgets('a live handle superseded: leave hook 1', (tester) async {
      final rig = Rig();
      final a = rig.join.prepare(req('a'));
      await a.attach();
      await tester.pump();
      final b = rig.join.prepare(req('b'));
      expect(await b.attach(), isNotNull);
      expect(rig.log.where((l) => l.startsWith('leave')), ['leave ctor 0']);
      expect(await a.ended, GravixPrejoinEndReason.superseded);
      await tester.pump();
      await rig.dispose(tester);
    });
  });

  group('a real Room (fake signal server)', () {
    setUp(fake.installRecoveryChannelMocks);

    test('a Room the SDK built (default createRoom + default leave) that died is disposed by the SDK', () async {
      final h = GravixPrejoin.start(
        key: 'k-own',
        target: () => const GravixJoinTarget(url: url, token: 't'),
        connect: (r, t) async {},
        abandonInBackground: false,
      );
      final room = await h.attach(leaveIfNeverShown: false);
      room!.events.emit(RoomDisconnectedEvent(reason: DisconnectReason.participantRemoved));
      expect(await fake.eventually(() => GravixPrejoin.pendingFor('k-own') == null), isTrue);
      expect(await h.ended, GravixPrejoinEndReason.roomGone);
      expect(await fake.eventually(() => room.isDisposed), isTrue);
    });

    test('a resume (signal reads disconnected while it dials) keeps the handle; the server\'s Leave ends it', () async {
      final server = fake.FakeSignalServer();
      final pcs = fake.FakePcFactory();
      final room = await fake.connectedFakeRoom(server, pcs, url: 'wss://blr1.example');
      final leaves = <Room>[];
      final h = GravixPrejoin.start(
        key: 'k-real',
        target: () => const GravixJoinTarget(url: 'wss://blr1.example', token: 't'),
        createRoom: () => room,
        connect: (r, t) async {},
        leave: (r) async {
          leaves.add(r);
          await GravixPrejoin.defaultLeave(r);
        },
        abandonInBackground: false,
      );
      expect(await h.attach(leaveIfNeverShown: false), same(room));
      final dial = Completer<void>();
      server.onDial = (u) async {
        if (u.queryParameters['reconnect'] == '1' && !dial.isCompleted) await dial.future;
      };
      await server.last.serverClose(); // a resume starts; its dial hangs
      expect(
        await fake.eventually(() => room.engine.connectionState == ConnectionState.disconnected),
        isTrue,
        reason: 'the case under test: the signal reads disconnected mid-resume',
      );
      expect(GravixPrejoin.pendingFor('k-real'), same(h), reason: 'a resume is not a gone Room');
      dial.complete();
      expect(await fake.eventually(() => room.engine.connectionState == ConnectionState.connected), isTrue);
      expect(GravixPrejoin.pendingFor('k-real'), same(h));
      // the server removes the participant
      server.last.deliver(
        lk_rtc.SignalResponse(
          leave: lk_rtc.LeaveRequest(
            reason: lk_models.DisconnectReason.PARTICIPANT_REMOVED,
            action: lk_rtc.LeaveRequest_Action.DISCONNECT,
          ),
        ),
      );
      expect(await fake.eventually(() => GravixPrejoin.pendingFor('k-real') == null), isTrue);
      expect(await h.ended, GravixPrejoinEndReason.roomGone);
      expect(leaves, isEmpty, reason: 'an app-built Room: the app\'s disconnect handling cleans up');
      await GravixPrejoin.debugEndAll();
      if (!room.isDisposed) await room.dispose();
    });
  });

  group('warm(activity:)', () {
    testWidgets('activity: false (a periodic refresh) does not wake the pool; the default does', (tester) async {
      var now = DateTime(2026, 10, 15, 12);
      final rig = Rig(clock: () => now);
      final c = await rig.join.warm(req('own'), role: GravixStandbyRole.ownRegion, activity: false);
      expect(c, isNotNull, reason: 'the token is still fetched / cached');
      expect(rig.fetches, 1);
      expect(rig.opened, isEmpty, reason: 'no user activity yet: nothing opened, nothing rotating');
      expect(rig.pool.candidates.map((c) => c.role), contains(GravixStandbyRole.ownRegion));
      await rig.join.warm(req('a'), role: GravixStandbyRole.visible, activity: false);
      await rig.join.warm(req('b'), activity: false);
      expect(rig.opened, isEmpty, reason: 'the same rule for every role');
      await rig.join.warm(req('own'), role: GravixStandbyRole.ownRegion);
      expect(rig.opened, isNotEmpty, reason: 'the default counts as activity');
      // idle passes; a refresh does not count as activity, the pool closes on its tick
      rig.opened.clear();
      now = now.add(const Duration(minutes: 4));
      await rig.join.warm(req('own'), role: GravixStandbyRole.ownRegion, activity: false);
      await rig.pool.runTick();
      expect(rig.opened, isEmpty);
      await rig.dispose(tester);
    });
  });

  group('attach(request) hooks', () {
    testWidgets('nothing pending: the cold join uses the hooks passed to attach', (tester) async {
      final rig = Rig();
      final room = await rig.join.attach(
        req('a'),
        createRoom: () => rig.newRoom('attach'),
        connect: (r, t) async => rig.log.add('connect attach'),
        leave: (r) async => rig.log.add('leave attach'),
      );
      expect(room, isNotNull);
      expect(rig.log, ['room attach', 'connect attach']);
      await tester.pump();
      await rig.join.leave();
      expect(rig.log.last, 'leave attach');
      await rig.dispose(tester);
    });

    testWidgets('a live handle: the hooks are ignored, the same handle and Room', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(req('a'));
      var used = false;
      final room = await rig.join.attach(
        req('a'),
        createRoom: () {
          used = true;
          return rig.newRoom('attach');
        },
        connect: (r, t) async => used = true,
        leave: (r) async => used = true,
      );
      expect(room, same(h.room));
      expect(rig.join.pending(req('a')), same(h));
      expect(used, isFalse);
      expect(rig.log, ['room ctor', 'connect ctor']);
      await tester.pump();
      await rig.dispose(tester);
    });
  });
}

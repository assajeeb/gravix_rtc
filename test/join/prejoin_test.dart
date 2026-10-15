// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join: GravixPrejoin, the join handle the apps wrote by hand.
//  - The connect starts at the tap, beside the app's own work and the navigation;
//    the room screen's attach() gets the SAME connect (no second session).
//  - Field 2026-10-14: a Back ~170 ms after a tap sent the app to the background
//    before the room screen opened; the prejoin connected anyway and a ghost viewer
//    stayed in the room ~30 s with no screen to leave it. The handle now abandons
//    itself when the app is hidden / paused / detached before attach().
//  - Field 2026-10-14 (the same flow, a little later Back): the room screen was
//    already pushed but never shown; it connected in the background: a ghost
//    viewer for 30-33 s. attach(leaveIfNeverShown: true) leaves when the app goes
//    to the background before a frame was shown with the app resumed.
//  - A handle never attached leaves after attachTimeout.
//  - abandon() while joining ends the join at once (Room.disconnect ends its
//    retries): no waiting ~65 s for a join nobody wants.
import 'dart:async';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const url = 'wss://rtc.example.test';

/// The fake transport of these tests: a connect held until [release], counted.
class FakeJoin {
  final rooms = <Room>[];
  final connects = <String>[];
  final leaves = <Room>[];
  final gates = <Completer<void>>[];
  bool holdConnects = false;
  Object? failWith;

  Future<void> connect(Room room, GravixJoinTarget t) async {
    connects.add(t.token);
    if (holdConnects) {
      final c = Completer<void>();
      gates.add(c);
      await c.future;
    }
    final f = failWith;
    if (f != null) throw f;
  }

  Future<void> leave(Room room) async => leaves.add(room);

  Room createRoom() {
    final r = Room();
    rooms.add(r);
    return r;
  }

  /// Real Rooms start periodic timers; the fake clock of a widget test must end
  /// with none pending.
  Future<void> disposeRooms(WidgetTester tester) => tester.runAsync(() async {
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });

  void release() {
    for (final g in gates) {
      if (!g.isCompleted) g.complete();
    }
  }
}

GravixPrejoin start(
  FakeJoin f, {
  String key = 'k1',
  String token = 't1',
  Duration? attachTimeout = const Duration(seconds: 20),
  bool abandonInBackground = true,
  List<GravixJoinEvent>? events,
  FutureOr<GravixJoinTarget> Function()? target,
}) => GravixPrejoin.start(
  key: key,
  target: target ?? () => GravixJoinTarget(url: url, token: token),
  createRoom: f.createRoom,
  connect: f.connect,
  leave: f.leave,
  attachTimeout: attachTimeout,
  abandonInBackground: abandonInBackground,
  onEvent: events?.add,
);

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

void main() {
  tearDown(GravixPrejoin.debugEndAll);

  testWidgets('the tap starts the connect; attach returns the same room; a second start is the same handle', (
    tester,
  ) async {
    final f = FakeJoin();
    final events = <GravixJoinEvent>[];
    final h = start(f, events: events);
    expect(GravixPrejoin.pendingFor('k1'), same(h));
    final again = start(f, token: 't2'); // the screen's own connect, a refreshed token
    expect(again, same(h));
    final room = await h.attach();
    expect(room, isNotNull);
    expect(room, same(h.room));
    expect(f.connects, ['t1'], reason: 'one connect for one session');
    expect(h.state, GravixPrejoinState.attached);
    expect(await h.connected, isTrue);
    await tester.pump(); // a frame shown with the app resumed
    expect(events.map((e) => e.kind), [
      GravixJoinEventKind.prejoinStart,
      GravixJoinEventKind.connectStart,
      GravixJoinEventKind.connected,
      GravixJoinEventKind.attached,
      GravixJoinEventKind.shown,
    ]);
    expect(events.every((e) => e.key == 'k1'), isTrue);
    expect(events.every((e) => !e.sinceTap.isNegative), isTrue);
    await f.disposeRooms(tester);
  });

  testWidgets('abandon while joining: left at once, attach() is null, nothing reconnects', (tester) async {
    final f = FakeJoin()..holdConnects = true;
    final h = start(f);
    await tester.pump(Duration.zero);
    expect(f.connects, hasLength(1));
    final attach = h.attach();
    await h.abandon();
    expect(f.leaves, hasLength(1), reason: 'the joining room is left now, not after its retries');
    expect(await attach, isNull);
    expect(await h.ended, GravixPrejoinEndReason.abandoned);
    expect(GravixPrejoin.pendingFor('k1'), isNull);
    f.release(); // the join completes late
    await tester.pump(Duration.zero);
    expect(f.leaves, hasLength(1), reason: 'left once; the late connect is not adopted');
    expect(h.state, GravixPrejoinState.ended);
    await f.disposeRooms(tester);
  });

  testWidgets('abandon before the token arrived: no room, no connect', (tester) async {
    final f = FakeJoin();
    final token = Completer<GravixJoinTarget>();
    final h = start(f, target: () => token.future);
    await h.abandon();
    token.complete(const GravixJoinTarget(url: url, token: 't1'));
    await tester.pump(Duration.zero);
    expect(f.connects, isEmpty);
    expect(f.leaves, isEmpty);
    expect(h.room, isNull);
    expect(await h.connected, isFalse, reason: 'the join gate never opens');
    await f.disposeRooms(tester);
  });

  testWidgets('the app goes to the background before attach: abandoned (no ghost viewer)', (tester) async {
    final f = FakeJoin();
    final h = start(f);
    await tester.pump(Duration.zero);
    background(tester);
    expect(await h.ended, GravixPrejoinEndReason.background);
    expect(f.leaves, hasLength(1));
    expect(await h.attach(), isNull, reason: 'the screen does not open a room behind the user');
    foreground(tester);
    await f.disposeRooms(tester);
  });

  testWidgets('abandonInBackground: false (a call answered from a push): kept', (tester) async {
    final f = FakeJoin();
    final h = start(f, abandonInBackground: false);
    await tester.pump(Duration.zero);
    background(tester);
    await tester.pump(Duration.zero);
    expect(h.state, isNot(GravixPrejoinState.ended));
    foreground(tester);
    expect(await h.attach(leaveIfNeverShown: false), isNotNull);
    await f.disposeRooms(tester);
  });

  testWidgets('started with the app already in the background: abandoned at once', (tester) async {
    background(tester);
    final f = FakeJoin();
    final h = start(f);
    expect(await h.ended, GravixPrejoinEndReason.background);
    expect(f.connects, isEmpty, reason: 'nothing dialled behind the user');
    foreground(tester);
    await f.disposeRooms(tester);
  });

  testWidgets('attached but never shown, then background: left (the screen hears it on ended)', (tester) async {
    final f = FakeJoin();
    final h = start(f);
    final room = await h.attach();
    expect(room, isNotNull);
    // no frame yet: the screen was built but never shown
    background(tester);
    expect(await h.ended, GravixPrejoinEndReason.neverShown);
    expect(f.leaves, [room]);
    foreground(tester);
    await f.disposeRooms(tester);
  });

  testWidgets('shown, then background: the normal minimise -- nothing', (tester) async {
    final f = FakeJoin();
    final h = start(f);
    await h.attach();
    await tester.pump();
    background(tester);
    await tester.pump(Duration.zero);
    expect(f.leaves, isEmpty);
    expect(h.state, GravixPrejoinState.attached);
    foreground(tester);
    await f.disposeRooms(tester);
  });

  testWidgets('never attached within attachTimeout: left', (tester) async {
    final f = FakeJoin();
    final h = start(f, attachTimeout: const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 4));
    expect(h.state, GravixPrejoinState.connected);
    await tester.pump(const Duration(seconds: 2));
    expect(await h.ended, GravixPrejoinEndReason.attachTimeout);
    expect(f.leaves, hasLength(1));
    await f.disposeRooms(tester);
  });

  testWidgets('a failed connect: attach() null, the error kept, cleaned up, the next start is fresh', (tester) async {
    final f = FakeJoin()..failWith = StateError('no server');
    final h = start(f);
    expect(await h.attach(), isNull);
    expect(h.error, isA<StateError>());
    expect(await h.ended, GravixPrejoinEndReason.failed);
    expect(await h.connected, isFalse);
    expect(f.leaves, hasLength(1), reason: 'the failed room is disposed');
    expect(GravixPrejoin.pendingFor('k1'), isNull);
    f.failWith = null;
    final next = start(f);
    expect(next, isNot(same(h)));
    expect(await next.attach(), isNotNull);
    expect(f.connects, hasLength(2));
    await f.disposeRooms(tester);
  });

  testWidgets('a token that cannot be had: failed with that error, no room', (tester) async {
    final f = FakeJoin();
    final h = start(f, target: () => throw const GravixTokenException(GravixTokenErrorReason.timeout, 'x'));
    expect(await h.attach(), isNull);
    expect(h.error, isA<GravixTokenException>());
    expect(h.room, isNull);
    expect(f.connects, isEmpty);
    await f.disposeRooms(tester);
  });

  testWidgets('leave() after attach: the real exit; abandon afterwards does not leave twice', (tester) async {
    final f = FakeJoin();
    final h = start(f);
    await h.attach();
    await tester.pump();
    await h.leave();
    await h.abandon();
    expect(f.leaves, hasLength(1));
    expect(await h.ended, GravixPrejoinEndReason.left);
    await f.disposeRooms(tester);
  });

  testWidgets('adopt: a Room the app connected itself becomes the live attached handle of its key', (tester) async {
    final f = FakeJoin();
    final old = start(f, key: 'k-viewer');
    final oldRoom = await old.attach();
    await tester.pump();
    final room = f.createRoom(); // the app's own reconnect (a role change)
    final events = <GravixJoinEvent>[];
    final h = GravixPrejoin.adopt(key: 'k-guest', room: room, leave: f.leave, replaces: old, onEvent: events.add);
    expect(GravixPrejoin.pendingFor('k-guest'), same(h));
    expect(GravixPrejoin.pendingFor('k-viewer'), isNull);
    expect(await old.ended, GravixPrejoinEndReason.replaced);
    expect(f.leaves, isEmpty, reason: 'the app tore its old room down itself');
    expect(await h.attach(), same(room));
    expect(f.connects, hasLength(1), reason: 'no connect for the adopted room');
    expect(events.map((e) => e.kind), [GravixJoinEventKind.adopted]);
    expect(h.startedAt, isNotNull);
    await h.leave();
    expect(f.leaves, [room]);
    expect(f.leaves.contains(oldRoom), isFalse);
    await f.disposeRooms(tester);
  });

  testWidgets('the default leave of a Room: disconnect + dispose (no app hook)', (tester) async {
    await tester.runAsync(() async {
      final h = GravixPrejoin.start(
        key: 'k2',
        target: () => const GravixJoinTarget(url: url, token: 't'),
        createRoom: Room.new,
        connect: (room, t) async {},
      );
      final room = await h.attach(leaveIfNeverShown: false);
      await h.leave();
      expect(room!.isDisposed, isTrue);
      expect(room.connectionState, ConnectionState.disconnected);
    });
  });

  test('session key: room + identity + publish right from the token; null when unreadable', () {
    String jwt(bool publish, {int n = 0}) => JWT(<String, dynamic>{
      'sub': 'u1',
      'n': n,
      'video': <String, dynamic>{'room': 'r1', 'roomJoin': true, 'canPublish': publish},
    }).sign(SecretKey('test-secret'));
    expect(GravixPrejoin.sessionKeyOf(jwt(false)), GravixPrejoin.sessionKeyOf(jwt(false, n: 1)));
    expect(GravixPrejoin.sessionKeyOf(jwt(false)), isNot(GravixPrejoin.sessionKeyOf(jwt(true))));
    expect(GravixPrejoin.sessionKeyOf('not-a-jwt'), isNull);
    expect(
      GravixPrejoin.sessionKey(const GravixTokenRequest(room: 'r1', identity: 'u1')),
      GravixPrejoin.sessionKeyOf(jwt(false)),
    );
  });
}

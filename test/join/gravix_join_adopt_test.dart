// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join: GravixJoin.adopt, a session the app connected itself.
//  - Two apps (2026-10-15 migration): the role change (viewer -> guest / host)
//    is a full new connect with a new token whose canPublish differs, done by the
//    app's own service outside GravixJoin. The session key (room + identity +
//    canPublish) changes, so GravixJoin's current session went stale: a later
//    prepare / switchTo called the old handle's leave hook on a room the app had
//    already replaced (a service-wide teardown would close the NEW room), and
//    join.leave() did not leave the new room at all.
//  - adopt(request, room) records the app's room as the current session: found by
//    pending / attach / pendingFor, left by the next prepare / switchTo and by
//    leave(); the previous attached session ends `replaced` without a second
//    leave (the app tore it down); a previous one still joining is abandoned
//    normally (its connect must stop).
//  - An adopted room is already on screen: no background auto-abandon, no
//    neverShown watch, no attachTimeout.
//  - Review (2026-10-15): an in-app minimize (route popped / overlay, app still
//    resumed) after attach() never leaves; a Home press after the first frame
//    was shown does not leave either.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

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
  final log = <String>[];
  final rooms = <Room>[];
  final events = <GravixJoinEvent>[];
  int fetches = 0;
  Completer<void>? leaveGate;

  late final tokens = GravixTokenProvider.callback((r) async {
    fetches++;
    return {'token': jwt(r.room, n: fetches), 'url': url};
  }, reuse: GravixTokenReuse.fastJoin);

  late final pool = GravixStandbyPool(opener: (u, t, rtt) async => true, inForeground: () => true, autoTick: false);

  late final join = GravixJoin(
    tokenProvider: tokens,
    standbyPool: pool,
    bindStandbyLifecycle: false,
    createRoom: newRoom,
    connect: (room, t) async {
      log.add('connect ${GravixPrejoin.sessionKeyOf(t.token)?.split('\u0000').first}');
    },
    leave: (room) async {
      log.add('leave ${rooms.indexOf(room)}');
      if (leaveGate != null) await leaveGate!.future;
      log.add('left ${rooms.indexOf(room)}');
    },
    onEvent: events.add,
  );

  /// A Room the app built and connected itself (its own reconnect).
  Room newRoom() {
    final r = Room();
    rooms.add(r);
    return r;
  }

  Iterable<String> get leaves => log.where((l) => l.startsWith('leave'));
  Iterable<String> get connects => log.where((l) => l.startsWith('connect'));

  Future<void> dispose(WidgetTester tester) => tester.runAsync(() async {
    await GravixPrejoin.debugEndAll();
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });
}

GravixTokenRequest viewer(String room) => GravixTokenRequest(room: room, identity: 'u1');
GravixTokenRequest guest(String room) => GravixTokenRequest(room: room, identity: 'u1', canPublish: true);

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

  testWidgets('adopt after the app reconnected itself (role change): the attached session ends replaced, never left '
      'again; the adopted one is found by pending / attach / pendingFor', (tester) async {
    final rig = Rig();
    final a = rig.join.prepare(viewer('a'));
    await a.attach();
    await tester.pump();
    // the app's own role change: it tore room 0 down and connected room 1 with a guest token
    final r1 = rig.newRoom();
    final h = rig.join.adopt(guest('a'), r1);
    expect(await a.ended, GravixPrejoinEndReason.replaced);
    expect(rig.leaves, isEmpty, reason: 'the app already tore the old room down');
    expect(h.state, GravixPrejoinState.attached);
    expect(h.room, same(r1));
    expect(h.key, GravixPrejoin.sessionKey(guest('a')));
    expect(await h.connected, isTrue);
    expect(rig.join.current, same(h));
    expect(rig.join.pending(guest('a')), same(h));
    expect(rig.join.pending(viewer('a')), isNull);
    expect(GravixPrejoin.pendingFor(GravixPrejoin.sessionKey(guest('a'))), same(h));
    expect(await rig.join.attach(guest('a')), same(r1));
    expect(await h.attach(), same(r1));
    expect(rig.connects, ['connect a'], reason: 'no connect for the adopted room');
    expect(rig.fetches, 1, reason: 'no token for the adopted room');
    await rig.dispose(tester);
  });

  testWidgets('prepare for another session after adopt leaves the adopted room once, then connects', (tester) async {
    final rig = Rig();
    await rig.join.prepare(viewer('a')).attach();
    await tester.pump();
    final r1 = rig.newRoom();
    final h = rig.join.adopt(guest('a'), r1);
    rig.leaveGate = Completer<void>();
    final b = rig.join.prepare(viewer('b'));
    await tester.pump(Duration.zero);
    expect(rig.leaves, ['leave 1'], reason: 'the adopted room, with the constructor leave; never room 0 again');
    expect(rig.connects.contains('connect b'), isFalse, reason: 'not while the adopted session is still up');
    rig.leaveGate!.complete();
    expect(await b.attach(), isNotNull);
    expect(rig.log.indexOf('connect b'), greaterThan(rig.log.indexOf('left 1')));
    expect(await h.ended, GravixPrejoinEndReason.superseded);
    await rig.join.leave();
    expect(rig.leaves, ['leave 1', 'leave 2'], reason: 'b left; the adopted room not twice');
    await rig.dispose(tester);
  });

  testWidgets('switchTo after adopt leaves the adopted room through its own leave hook', (tester) async {
    final rig = Rig();
    final r0 = rig.newRoom();
    final own = <Room>[];
    final h = rig.join.adopt(guest('a'), r0, leave: (room) async => own.add(room));
    final b = rig.join.switchTo(viewer('b'));
    expect(await b.attach(), isNotNull);
    expect(own, [r0]);
    expect(rig.leaves, isEmpty, reason: 'the adopt-time hook, not the constructor one');
    expect(await h.ended, GravixPrejoinEndReason.superseded);
    await rig.dispose(tester);
  });

  testWidgets('join.leave() after adopt leaves the adopted room', (tester) async {
    final rig = Rig();
    await rig.join.prepare(viewer('a')).attach();
    await tester.pump();
    final h = rig.join.adopt(guest('a'), rig.newRoom());
    await rig.join.leave();
    expect(rig.leaves, ['leave 1']);
    expect(await h.ended, GravixPrejoinEndReason.left);
    expect(rig.join.current, isNull);
    expect(rig.join.pending(guest('a')), isNull);
    await h.leave();
    expect(rig.leaves, ['leave 1'], reason: 'idempotent');
    await rig.dispose(tester);
  });

  testWidgets('adopt while the previous session is still joining: that join is abandoned normally (left)', (
    tester,
  ) async {
    final rig = Rig();
    final hold = Completer<void>();
    final a = rig.join.prepare(viewer('a'), connect: (room, t) => hold.future);
    await tester.pump(Duration.zero);
    expect(a.state, GravixPrejoinState.connecting);
    final h = rig.join.adopt(guest('a'), rig.newRoom());
    expect(await a.ended, GravixPrejoinEndReason.superseded);
    await tester.pump(Duration.zero);
    expect(rig.leaves, ['leave 0'], reason: 'the join in flight is stopped, the adopted room is not touched');
    expect(await a.attach(), isNull);
    hold.complete();
    await tester.pump(Duration.zero);
    expect(rig.join.current, same(h));
    expect(h.state, GravixPrejoinState.attached);
    await rig.dispose(tester);
  });

  testWidgets('adopt while the previous session is still waiting for its token: ended, nothing to leave', (
    tester,
  ) async {
    final rig = Rig();
    final a = rig.join.prepare(viewer('a'), connect: (room, t) => Completer<void>().future);
    final h = rig.join.adopt(guest('a'), rig.newRoom());
    expect(await a.ended, GravixPrejoinEndReason.superseded);
    await tester.pump(Duration.zero);
    expect(rig.leaves, isEmpty);
    expect(rig.connects, isEmpty);
    expect(rig.join.current, same(h));
    await rig.dispose(tester);
  });

  testWidgets('a connected handle no screen took yet is abandoned normally (left) by adopt', (tester) async {
    final rig = Rig();
    final a = rig.join.prepare(viewer('a'));
    expect(await a.connected, isTrue);
    rig.join.adopt(guest('a'), rig.newRoom());
    expect(await a.ended, GravixPrejoinEndReason.superseded);
    await tester.pump(Duration.zero);
    expect(rig.leaves, ['leave 0']);
    await rig.dispose(tester);
  });

  testWidgets('the same key adopted twice: one handle, one event; a new Room for the same key replaces it', (
    tester,
  ) async {
    final rig = Rig();
    final r0 = rig.newRoom();
    final h = rig.join.adopt(guest('a'), r0);
    expect(rig.join.adopt(guest('a'), r0), same(h));
    expect(rig.events.where((e) => e.kind == GravixJoinEventKind.adopted), hasLength(1));
    expect(h.state, GravixPrejoinState.attached);
    // the same session reconnected by the app into another Room (a refreshed token)
    final r1 = rig.newRoom();
    final h2 = rig.join.adopt(guest('a'), r1);
    expect(h2, isNot(same(h)));
    expect(await h.ended, GravixPrejoinEndReason.replaced);
    expect(rig.join.pending(guest('a')), same(h2));
    expect(rig.join.current, same(h2));
    await tester.pump(Duration.zero);
    expect(rig.leaves, isEmpty);
    await rig.dispose(tester);
  });

  testWidgets('a prepared handle connected, not yet attached, adopted with its own Room: attached, no guards', (
    tester,
  ) async {
    final rig = Rig();
    final a = rig.join.prepare(guest('a'));
    expect(await a.connected, isTrue);
    expect(rig.join.adopt(guest('a'), a.room!), same(a));
    expect(a.state, GravixPrejoinState.attached);
    expect(rig.events.where((e) => e.kind == GravixJoinEventKind.adopted), hasLength(1));
    background(tester);
    await tester.pump(const Duration(seconds: 25)); // past attachTimeout
    foreground(tester);
    expect(a.state, GravixPrejoinState.attached);
    expect(rig.leaves, isEmpty);
    await rig.dispose(tester);
  });

  testWidgets('the old handle\'s own Room adopted under a new key (re-tokened in place): never left', (tester) async {
    final rig = Rig();
    final a = rig.join.prepare(viewer('a'));
    final room = await a.attach();
    await tester.pump();
    final h = rig.join.adopt(guest('a'), room!);
    expect(await a.ended, GravixPrejoinEndReason.replaced);
    expect(h.room, same(room));
    await tester.pump(Duration.zero);
    expect(rig.leaves, isEmpty);
    await rig.dispose(tester);
  });

  testWidgets('adopt emits adopted (key of the new session) and the replaced one\'s end', (tester) async {
    final rig = Rig();
    await rig.join.prepare(viewer('a')).attach();
    await tester.pump();
    rig.join.adopt(guest('a'), rig.newRoom());
    final adopted = rig.events.where((e) => e.kind == GravixJoinEventKind.adopted).toList();
    expect(adopted, hasLength(1));
    expect(adopted.single.key, GravixPrejoin.sessionKey(guest('a')));
    final ended = rig.events.where((e) => e.kind == GravixJoinEventKind.abandoned).single;
    expect(ended.key, GravixPrejoin.sessionKey(viewer('a')));
    expect(ended.detail, 'replaced');
    await rig.dispose(tester);
  });

  testWidgets('an adopted room is on screen already: no background abandon, no neverShown, no attachTimeout', (
    tester,
  ) async {
    final rig = Rig();
    final h = rig.join.adopt(guest('a'), rig.newRoom());
    background(tester);
    await tester.pump(Duration.zero);
    foreground(tester);
    await tester.pump(const Duration(seconds: 25));
    expect(h.state, GravixPrejoinState.attached);
    expect(rig.leaves, isEmpty);
    await rig.dispose(tester);
  });

  testWidgets('review: an in-app minimize after attach (route popped, app resumed), then Home: never left', (
    tester,
  ) async {
    final rig = Rig();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
    final h = rig.join.prepare(viewer('a'));
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('room'))));
    await tester.pumpAndSettle();
    expect(await rig.join.attach(viewer('a')), isNotNull);
    await tester.pump(); // the room screen's first frame, app resumed
    nav.currentState!.pop(); // the minimize: back to the list, a bubble overlay keeps the room
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(h.state, GravixPrejoinState.attached);
    background(tester); // Home
    await tester.pump(Duration.zero);
    foreground(tester);
    await tester.pump();
    expect(rig.leaves, isEmpty);
    expect(h.state, GravixPrejoinState.attached);
    expect(rig.join.current, same(h));
    await rig.dispose(tester);
  });
}

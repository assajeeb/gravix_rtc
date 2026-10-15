// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join: the room screen claims the session the moment it CALLS
// attach(), not when attach() returns.
//  - An app's migration (2026-10-15): the room screen calls attach() in initState and
//    is visible while the connect still runs. The handle counted the screen only
//    once attach() returned (after the connect), so a Home press with the screen
//    visible and the connect running was taken for "the app left before the room
//    opened" and the join was ended. The app wrote its own show guard around it.
//  - Intended (as another app's first-frame guard): from the attach() call, only "the
//    app went to the background before the screen's first frame was drawn with
//    the app resumed" leaves; once a frame was shown, a Home press never leaves.
//    The pre-attach guard (tap -> Home before any screen) stays.
//  - A frame drawn while `inactive` does not count; the next frame after the
//    resume does.
//  - A screen gone before its first frame ends the handle: its watch goes with
//    it (no late leave, no `shown` on a dead handle).
//  - attachTimeout is "nobody attached": a screen waiting on a long connect is
//    not timed out.
import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const url = 'wss://rtc.example.test';

class FakeJoin {
  final rooms = <Room>[];
  final connects = <String>[];
  final leaves = <Room>[];
  final gates = <Completer<void>>[];
  bool holdConnects = false;

  Future<void> connect(Room room, GravixJoinTarget t) async {
    connects.add(t.token);
    if (holdConnects) {
      final c = Completer<void>();
      gates.add(c);
      await c.future;
    }
  }

  Future<void> leave(Room room) async => leaves.add(room);

  Room createRoom() {
    final r = Room();
    rooms.add(r);
    return r;
  }

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
  Duration? attachTimeout = const Duration(seconds: 20),
  List<GravixJoinEvent>? events,
}) => GravixPrejoin.start(
  key: key,
  target: () => const GravixJoinTarget(url: url, token: 't1'),
  createRoom: f.createRoom,
  connect: f.connect,
  leave: f.leave,
  attachTimeout: attachTimeout,
  onEvent: events?.add,
);

void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
  for (final s in states) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void background(WidgetTester tester) =>
    lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);

void foreground(WidgetTester tester) =>
    lifecycle(tester, const [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);

void main() {
  tearDown(GravixPrejoin.debugEndAll);

  testWidgets('screen visible while connecting (attach called, frame shown), then Home: the join stays', (
    tester,
  ) async {
    final f = FakeJoin()..holdConnects = true;
    final events = <GravixJoinEvent>[];
    final h = start(f, events: events);
    await tester.pump(Duration.zero);
    final attach = h.attach(); // initState: the connect is still running
    await tester.pump(); // the screen's first frame, app resumed
    expect(events.map((e) => e.kind), contains(GravixJoinEventKind.shown));
    background(tester); // Home with the room screen on screen
    await tester.pump(Duration.zero);
    expect(h.state, isNot(GravixPrejoinState.ended), reason: 'the room was shown: a Home press is a minimise');
    expect(f.leaves, isEmpty);
    f.release();
    expect(await attach, same(h.room));
    expect(h.state, GravixPrejoinState.attached);
    foreground(tester);
    await f.disposeRooms(tester);
  });

  testWidgets('attach called while connecting, Home before any frame: neverShown, attach() null', (tester) async {
    final f = FakeJoin()..holdConnects = true;
    final h = start(f);
    await tester.pump(Duration.zero);
    final attach = h.attach();
    background(tester); // no frame of the screen yet
    expect(await h.ended, GravixPrejoinEndReason.neverShown);
    expect(f.leaves, hasLength(1));
    f.release();
    expect(await attach, isNull);
    foreground(tester);
    await f.disposeRooms(tester);
  });

  testWidgets('a frame drawn while inactive does not count: hidden afterwards is neverShown', (tester) async {
    final f = FakeJoin()..holdConnects = true;
    final h = start(f);
    await tester.pump(Duration.zero);
    unawaited(h.attach());
    lifecycle(tester, const [AppLifecycleState.inactive]);
    await tester.pump(); // drawn under the notification shade
    lifecycle(tester, const [AppLifecycleState.hidden, AppLifecycleState.paused]);
    expect(await h.ended, GravixPrejoinEndReason.neverShown);
    foreground(tester);
    await f.disposeRooms(tester);
  });

  testWidgets('a frame drawn while inactive, then resumed + a frame: shown; Home later stays', (tester) async {
    final f = FakeJoin()..holdConnects = true;
    final events = <GravixJoinEvent>[];
    final h = start(f, events: events);
    await tester.pump(Duration.zero);
    unawaited(h.attach());
    lifecycle(tester, const [AppLifecycleState.inactive]);
    await tester.pump();
    expect(events.map((e) => e.kind), isNot(contains(GravixJoinEventKind.shown)));
    lifecycle(tester, const [AppLifecycleState.resumed]);
    await tester.pump();
    expect(events.map((e) => e.kind), contains(GravixJoinEventKind.shown));
    background(tester);
    await tester.pump(Duration.zero);
    expect(h.state, isNot(GravixPrejoinState.ended));
    foreground(tester);
    f.release();
    await f.disposeRooms(tester);
  });

  testWidgets('the screen gone before its first frame (left): no shown, no second leave on a later Home', (
    tester,
  ) async {
    final f = FakeJoin()..holdConnects = true;
    final events = <GravixJoinEvent>[];
    final h = start(f, events: events);
    await tester.pump(Duration.zero);
    final attach = h.attach();
    await h.leave(); // the screen's dispose, before any frame
    await tester.pump();
    background(tester);
    await tester.pump(Duration.zero);
    f.release();
    expect(await attach, isNull);
    expect(f.leaves, hasLength(1));
    expect(events.map((e) => e.kind), isNot(contains(GravixJoinEventKind.shown)));
    expect(await h.ended, GravixPrejoinEndReason.left);
    foreground(tester);
    await f.disposeRooms(tester);
  });

  testWidgets('tap -> Home before any screen called attach: still abandoned (background)', (tester) async {
    final f = FakeJoin()..holdConnects = true;
    final h = start(f);
    await tester.pump(Duration.zero);
    background(tester);
    expect(await h.ended, GravixPrejoinEndReason.background);
    foreground(tester);
    f.release();
    await f.disposeRooms(tester);
  });

  testWidgets('a screen waiting on a long connect is not timed out (attachTimeout = nobody attached)', (tester) async {
    final f = FakeJoin()..holdConnects = true;
    final h = start(f, attachTimeout: const Duration(seconds: 5));
    await tester.pump(Duration.zero);
    final attach = h.attach();
    await tester.pump(const Duration(seconds: 8));
    expect(h.state, isNot(GravixPrejoinState.ended));
    f.release();
    expect(await attach, isNotNull);
    await f.disposeRooms(tester);
  });
}

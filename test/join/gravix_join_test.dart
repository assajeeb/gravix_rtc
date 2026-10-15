// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join: GravixJoin, the few calls an app makes instead of the
// token cache + standby pool + prejoin + one-session guard + room switch it wrote
// by hand.
//  - warm() at the list / finger-down: the token and the server's standby, no connect.
//  - prepare() at the tap: no second token request after a warm, the connect at once.
//  - attach() from the room screen: the same connect.
//  - Never two sessions: a prepare for another session leaves the current one
//    first; the new connect starts only after that leave returned.
//  - switchTo() (field 2026-10-15, a room switch from the in-room list was 2.2 s
//    to the new room connected vs ~1 s for a tap from the home list: fetch, then the
//    whole old exit, then the new join from zero, one after the other): the target
//    is warmed at the tap, the old session stopped at once, the app's own work runs
//    beside it, and the new connect starts the moment both are done.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show DebugPrintCallback;
import 'package:flutter/widgets.dart' hide ConnectionState;
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
  final opened = <String>[];
  int fetches = 0;
  Completer<void>? leaveGate;
  Completer<void>? tokenGate;
  bool failToken = false;

  late final tokens = GravixTokenProvider.callback((r) async {
    fetches++;
    log.add('token ${r.room}');
    if (tokenGate != null) await tokenGate!.future;
    if (failToken) throw StateError('backend down');
    return {'token': jwt(r.room, n: fetches), 'url': url};
  }, reuse: GravixTokenReuse.fastJoin);

  late final pool = GravixStandbyPool(
    opener: (u, t, rtt) async {
      opened.add(t.isEmpty ? 'host' : 'token');
      return true;
    },
    inForeground: () => true,
    autoTick: false,
  );

  final events = <GravixJoinEvent>[];

  late final join = GravixJoin(
    tokenProvider: tokens,
    standbyPool: pool,
    bindStandbyLifecycle: false,
    createRoom: () {
      final r = Room();
      rooms.add(r);
      return r;
    },
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

  Future<void> dispose(WidgetTester tester) => tester.runAsync(() async {
    await GravixPrejoin.debugEndAll();
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });
}

GravixTokenRequest req(String room) => GravixTokenRequest(room: room, identity: 'u1');

void main() {
  tearDown(GravixPrejoin.debugEndAll);

  testWidgets('warm, then the tap: no second token request; attach() is the same connect', (tester) async {
    final rig = Rig();
    final c = await rig.join.warm(req('a'), role: GravixStandbyRole.touched);
    expect(c, isNotNull);
    expect(rig.opened, ['token'], reason: 'the server of the room under the finger is pre-connected');
    final h = rig.join.prepare(req('a'));
    final room = await rig.join.attach(req('a'));
    expect(room, same(h.room));
    expect(rig.fetches, 1);
    expect(rig.log.where((l) => l.startsWith('connect')), ['connect a']);
    final ready = rig.events.firstWhere((e) => e.kind == GravixJoinEventKind.tokenReady);
    expect(ready.detail, 'cached');
    expect(rig.events.firstWhere((e) => e.kind == GravixJoinEventKind.urlChosen).detail, contains('token'));
    await tester.pump();
    await rig.dispose(tester);
  });

  testWidgets('the same request twice is one session; attach() with no prepare joins cold', (tester) async {
    final rig = Rig();
    final h = rig.join.prepare(req('a'));
    expect(rig.join.prepare(req('a')), same(h));
    expect(rig.join.pending(req('a')), same(h));
    await rig.join.attach(req('a'));
    expect(rig.log.where((l) => l.startsWith('connect')), hasLength(1));
    await rig.join.leave();
    expect(rig.join.current, isNull);
    final room = await rig.join.attach(req('b'));
    expect(room, isNotNull);
    expect(rig.log.where((l) => l.startsWith('connect')), ['connect a', 'connect b']);
    await tester.pump();
    await rig.dispose(tester);
  });

  testWidgets('never two sessions: another session waits for the current one to be left', (tester) async {
    final rig = Rig();
    final a = rig.join.prepare(req('a'));
    await a.attach();
    await tester.pump();
    rig.leaveGate = Completer<void>();
    final b = rig.join.prepare(req('b'));
    await tester.pump(Duration.zero);
    expect(rig.log, contains('leave 0'));
    expect(rig.log.contains('connect b'), isFalse, reason: 'not while the old session is still up');
    rig.leaveGate!.complete();
    final room = await b.attach();
    expect(room, isNotNull);
    final i = rig.log.indexOf('left 0');
    expect(i, greaterThan(-1));
    expect(rig.log.indexOf('connect b'), greaterThan(i));
    expect(await a.ended, GravixPrejoinEndReason.superseded);
    expect(rig.join.current, same(b));
    await tester.pump();
    await rig.dispose(tester);
  });

  testWidgets('switchTo: target warmed at the tap, old stopped at once, new connected right after; timed', (
    tester,
  ) async {
    final rig = Rig();
    await rig.join.prepare(req('a')).attach();
    await tester.pump();
    rig.log.clear();
    rig.leaveGate = Completer<void>();
    final app = Completer<bool>(); // the app's own close of the old screen
    final h = rig.join.switchTo(req('b'), beforeConnect: () => app.future);
    await tester.pump(Duration.zero);
    expect(rig.log, containsAll(['leave 0', 'token b']), reason: 'the old leave and the new token at the tap');
    expect(rig.opened, contains('token'), reason: 'the target server pre-connected while the old room closes');
    expect(rig.log.contains('connect b'), isFalse);
    rig.leaveGate!.complete();
    await tester.pump(Duration.zero);
    expect(rig.log.contains('connect b'), isFalse, reason: 'the app is not done yet');
    app.complete(true);
    expect(await h.attach(), isNotNull);
    expect(rig.log.indexOf('connect b'), greaterThan(rig.log.indexOf('left 0')));
    expect(rig.fetches, 2, reason: 'one token per room: the switch uses the warmed one');
    final kinds = rig.events.map((e) => e.kind).where((k) => k.name.startsWith('switch')).toList();
    expect(kinds, [
      GravixJoinEventKind.switchStart,
      GravixJoinEventKind.switchOldLeft,
      GravixJoinEventKind.switchConnected,
    ]);
    final times = rig.events.where((e) => e.kind.name.startsWith('switch') && e.key == h.key).map((e) => e.sinceTap);
    expect(times.first, lessThan(const Duration(milliseconds: 50)));
    await tester.pump();
    await rig.dispose(tester);
  });

  testWidgets('switchTo cancelled by the app: no connect, ended = cancelled', (tester) async {
    final rig = Rig();
    await rig.join.prepare(req('a')).attach();
    await tester.pump();
    final h = rig.join.switchTo(req('b'), beforeConnect: () async => false);
    expect(await h.ended, GravixPrejoinEndReason.cancelled);
    expect(rig.log.contains('connect b'), isFalse);
    expect(await h.attach(), isNull);
    await rig.dispose(tester);
  });

  testWidgets('warm roles feed the standby pool; a token failure is not thrown', (tester) async {
    final rig = Rig();
    await rig.join.warm(req('a'), role: GravixStandbyRole.visible, rank: 2);
    expect(rig.pool.candidates.single.role, GravixStandbyRole.visible);
    expect(rig.pool.candidates.single.rank, 2);
    await rig.join.warm(req('own'), role: GravixStandbyRole.ownRegion);
    expect(rig.pool.candidates.map((c) => c.role), contains(GravixStandbyRole.ownRegion));
    rig.failToken = true;
    expect(await rig.join.warm(req('x')), isNull);
    await rig.dispose(tester);
  });

  // Field 2026-10-15: "not warmed (GravixTokenException)" x4 per list rebuild
  // said nothing about why (the app's refusal of rooms hosted by old app
  // versions). The line names the reason and the cause's type, never a message.
  testWidgets('a failed warm logs the token error\'s reason and cause type, never its message', (tester) async {
    final lines = <String>[];
    final DebugPrintCallback saved = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) lines.add(m);
    };
    final rig = Rig();
    rig.failToken = true; // the callback throws StateError('backend down')
    expect(await rig.join.warm(req('x'), role: GravixStandbyRole.visible), isNull);
    final refusing = GravixJoin(
      tokenProvider: GravixTokenProvider.callback(
        (r) => throw const _AppRefusal('host_app_outdated: token=secret-value'),
      ),
      standbyPool: rig.pool,
      bindStandbyLifecycle: false,
    );
    expect(await refusing.warm(req('old')), isNull);
    final malformed = GravixJoin(
      tokenProvider: GravixTokenProvider.callback((r) => {'token': 'eyJsecret'}),
      standbyPool: rig.pool,
      bindStandbyLifecycle: false,
    );
    expect(await malformed.warm(req('m')), isNull);
    debugPrint = saved; // (a widget test must end with it restored)
    final warmLines = lines.where((l) => l.startsWith('[GravixJoin] warmFail ')).toList();
    expect(warmLines.map((l) => l.substring(l.indexOf('not warmed'))), [
      'not warmed (callback, cause StateError)',
      'not warmed (callback, cause _AppRefusal)',
      'not warmed (malformed)',
    ]);
    for (final l in warmLines) {
      expect(l, isNot(contains('secret')));
      expect(l, isNot(contains('backend down')));
      expect(l, isNot(contains('eyJ')));
    }
    expect(rig.pool.candidates, isEmpty);
    await rig.dispose(tester);
  });

  test('warmFailure: any other error is named by its type only', () {
    expect(GravixJoin.warmFailure(StateError('wss://x?token=abc')), 'StateError');
    expect(
      GravixJoin.warmFailure(const GravixTokenException(GravixTokenErrorReason.timeout, 'no token within 8000ms')),
      'timeout',
    );
  });

  testWidgets('a token that cannot be had: attach() null with the error; forgetAll drops the cache', (tester) async {
    final rig = Rig();
    rig.failToken = true;
    final h = rig.join.prepare(req('a'));
    expect(await h.attach(), isNull);
    expect(h.error, isA<GravixTokenException>());
    rig.failToken = false;
    await rig.join.warm(req('b'));
    rig.join.forgetAll();
    await rig.join.warm(req('b'));
    expect(rig.fetches, 3, reason: 'a, b, b again after forgetAll');
    expect(rig.pool.candidates, hasLength(1), reason: 'forgotten, then the new warm');
    await rig.dispose(tester);
  });

  testWidgets('the app backgrounded while the old room closes during a switch: nothing connects', (tester) async {
    final rig = Rig();
    await rig.join.prepare(req('a')).attach();
    await tester.pump();
    rig.leaveGate = Completer<void>();
    final h = rig.join.switchTo(req('b'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    rig.leaveGate!.complete();
    expect(await h.ended, GravixPrejoinEndReason.background);
    await tester.pump(Duration.zero);
    expect(rig.log.contains('connect b'), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await rig.dispose(tester);
  });
}

/// An app's own refusal (its "room of an old app version" exception), with a message
/// that must never reach a log line.
class _AppRefusal implements Exception {
  const _AppRefusal(this.detail);
  final String detail;

  @override
  String toString() => '_AppRefusal($detail)';
}

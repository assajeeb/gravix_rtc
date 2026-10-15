// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixJoinLog (owner 2026-10-15: "properly log every step to catch the
// bugs"): every fast-join step writes one secret-free line
//   [GravixJoin] <step> key=<room>|u<hash>|pub=<bool> [+<ms>ms] [<detail>]
// The sequences of a tap -> attach -> leave, a failed warm, an abandon and a
// switch; and never a token, a JWT, a url query or the full identity.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const identity = 'user-identity-7f3a9c';
const url = 'wss://rtc.example.test/rtc?access_token=SECRETQUERY';

String jwt(String room, {int n = 0, bool canPublish = false}) {
  String part(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000;
  return [
    part({'alg': 'HS256'}),
    part({
      'sub': identity,
      'n': n,
      'exp': exp,
      'video': {'room': room, 'roomJoin': true, 'canPublish': canPublish},
    }),
    'c2ln',
  ].join('.');
}

GravixTokenRequest req(String room) => GravixTokenRequest(room: room, identity: identity, name: 'Me');

class Rig {
  final lines = <String>[];
  final tokensIssued = <String>[];
  final rooms = <Room>[];
  bool failToken = false;
  Completer<void>? connectGate;

  late final tokens = GravixTokenProvider.callback((r) async {
    if (failToken) throw StateError('backend down: $url');
    final t = jwt(r.room, n: tokensIssued.length);
    tokensIssued.add(t);
    return {'token': t, 'url': url};
  }, reuse: GravixTokenReuse.fastJoin);

  late final pool = GravixStandbyPool(
    opener: (u, t, rtt) async => true,
    stateOf: (u, t) => const GravixStandbyState('none'),
    inForeground: () => true,
    autoTick: false,
    log: lines.add,
  );

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
      final g = connectGate;
      if (g != null) await g.future;
    },
    leave: (room) async {},
    log: lines.add,
  );

  /// The step names, in order.
  List<String> get steps => [
    for (final l in lines)
      if (l.startsWith('${GravixJoinLog.prefix} ')) l.split(' ')[1],
  ];

  List<String> linesOf(String step) => lines.where((l) => l.startsWith('${GravixJoinLog.prefix} $step ')).toList();

  Future<void> dispose(WidgetTester tester) => tester.runAsync(() async {
    await GravixPrejoin.debugEndAll();
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });

  /// No token, JWT, url query or full identity in any line.
  void expectClean() {
    for (final l in lines) {
      expect(l, startsWith(GravixJoinLog.prefix));
      expect(l, isNot(contains('eyJ')), reason: l);
      for (final t in tokensIssued) {
        expect(l, isNot(contains(t)), reason: l);
      }
      expect(l, isNot(contains('SECRETQUERY')), reason: l);
      expect(l, isNot(contains('access_token')), reason: l);
      expect(l, isNot(contains(identity)), reason: l);
      expect(l, isNot(contains('backend down')), reason: l);
    }
  }
}

/// [want] appears in [got] in this order (other steps may come between).
void expectInOrder(List<String> got, List<String> want) {
  var i = 0;
  for (final s in got) {
    if (i < want.length && s == want[i]) i++;
  }
  expect(i, want.length, reason: 'wanted $want in order, got $got');
}

void main() {
  late GravixJoinLogLevel savedLevel;
  setUp(() {
    savedLevel = GravixJoinLog.level;
    GravixJoinLog.level = GravixJoinLogLevel.verbose;
  });
  tearDown(() async {
    GravixJoinLog.level = savedLevel;
    await GravixPrejoin.debugEndAll();
  });

  test('the line format: prefix, step, hashed identity key, ms since tap, scrubbed detail', () {
    final key = GravixPrejoin.sessionKey(req('r1'));
    final line = GravixJoinLog.format(
      'tokenOk',
      key: key,
      sinceTap: const Duration(milliseconds: 312),
      detail: 'via=fetched eyJabc.def.ghi wss://h/x?token=abc',
    );
    expect(
      line,
      '[GravixJoin] tokenOk key=r1|${GravixJoinLog.shortId(identity)}|pub=false +312ms via=fetched <jwt> '
      'wss://h/x?token=<redacted>',
    );
    expect(GravixJoinLog.shortId(identity), matches(RegExp(r'^u[0-9a-f]{8}$')));
    expect(GravixJoinLog.shortId(identity), GravixJoinLog.shortId(identity), reason: 'stable');
    expect(GravixJoinLog.host(url), 'rtc.example.test');
    expect(GravixJoinLog.format('standbyOpen'), '[GravixJoin] standbyOpen key=-');
  });

  test('levels: off writes nothing; info skips the verbose lines; a sink that throws costs nothing', () {
    final got = <String>[];
    GravixJoinLog.level = GravixJoinLogLevel.off;
    GravixJoinLog.step('prepare', to: got.add);
    expect(got, isEmpty);
    GravixJoinLog.level = GravixJoinLogLevel.info;
    GravixJoinLog.step('warmStart', at: GravixJoinLogLevel.verbose, to: got.add);
    GravixJoinLog.step('prepare', to: got.add);
    expect(got, ['[GravixJoin] prepare key=-']);
    GravixJoinLog.step('prepare', to: (_) => throw StateError('sink'));
    expect(GravixJoinLog.enabled, isTrue);
    GravixJoinLog.enabled = false;
    expect(GravixJoinLog.level, GravixJoinLogLevel.off);
  });

  testWidgets('tap -> attach -> leave: one line per step, in order, with the tap clock', (tester) async {
    final rig = Rig();
    final h = rig.join.prepare(req('a'));
    final room = await tester.runAsync(() => rig.join.attach(req('a')));
    expect(room, isNotNull);
    await tester.pump();
    await tester.runAsync(() => rig.join.leave());
    expectInOrder(rig.steps, [
      'prepare',
      'tokenStart',
      'attachCall', // the screen calls attach while the join runs
      'tokenOk',
      'urlChosen',
      'connectStart',
      'connectOk',
      'attached',
      'left',
      'leaveStart',
      'leaveDone',
    ]);
    expect(rig.linesOf('prepare').single, contains(' +0ms new'));
    expect(rig.linesOf('tokenOk').single, contains('via=fetched'));
    expect(rig.linesOf('urlChosen').single, contains('host=rtc.example.test'));
    expect(rig.linesOf('attachCall').single, contains('claimed'));
    expect(rig.linesOf('connectOk').single, matches(RegExp(r'\+\d+ms in=\d+ms')));
    expect(rig.linesOf('leaveDone').single, matches(RegExp(r'in=\d+ms')));
    expect(h.state, GravixPrejoinState.ended);
    rig.expectClean();
    await rig.dispose(tester);
  });

  testWidgets('the same session tapped again: "same handle"; a cold attach says so', (tester) async {
    final rig = Rig();
    rig.join.prepare(req('a'));
    rig.join.prepare(req('a'));
    expect(rig.linesOf('prepare').last, contains('same handle'));
    await tester.runAsync(() => rig.join.attach(req('b')));
    expect(rig.linesOf('attachCold').single, contains('key=b|'));
    rig.expectClean();
    await rig.dispose(tester);
  });

  testWidgets('a failed warm: start, then the failure with its reason and cause type', (tester) async {
    final rig = Rig();
    rig.failToken = true;
    expect(await rig.join.warm(req('x'), role: GravixStandbyRole.visible, rank: 3), isNull);
    expect(rig.steps, ['warmStart', 'warmFail']);
    expect(rig.linesOf('warmFail').single, endsWith('role=visible rank=3 not warmed (callback, cause StateError)'));
    rig.failToken = false;
    await rig.join.warm(req('y'), role: GravixStandbyRole.touched);
    expect(rig.linesOf('warmOk').single, contains('role=touched rank=0 via=fetched host=rtc.example.test'));
    rig.expectClean();
    await rig.dispose(tester);
  });

  testWidgets('a failed token at the tap: tokenFail with the reason, then connectFail', (tester) async {
    final rig = Rig();
    rig.failToken = true;
    final h = rig.join.prepare(req('a'));
    expect(await tester.runAsync(() => h.attach()), isNull);
    expectInOrder(rig.steps, ['prepare', 'tokenStart', 'tokenFail', 'connectFail']);
    expect(rig.linesOf('tokenFail').single, contains('callback, cause StateError'));
    expect(rig.linesOf('connectFail').single, contains('no target (callback, cause StateError)'));
    rig.expectClean();
    await rig.dispose(tester);
  });

  testWidgets('an abandon (a gate refused the room) names its reason; the leave hook runs', (tester) async {
    final rig = Rig();
    rig.join.prepare(req('a'));
    await tester.runAsync(() => rig.join.pending(req('a'))!.connected);
    await tester.runAsync(() => rig.join.abandon(req('a')));
    expectInOrder(rig.steps, ['prepare', 'connectOk', 'abandon', 'leaveStart', 'leaveDone']);
    expect(rig.linesOf('abandon').single, endsWith('reason=abandoned'));
    rig.expectClean();
    await rig.dispose(tester);
  });

  testWidgets('a switch: start, the old session superseded and left, then the new one connected', (tester) async {
    final rig = Rig();
    await tester.runAsync(() => rig.join.attach(req('a')));
    rig.lines.clear();
    final h = rig.join.switchTo(req('b'));
    await tester.runAsync(() => h.attach());
    expectInOrder(rig.steps, [
      'prepare',
      'abandon',
      'leaveStart',
      'tokenStart',
      'switchStart',
      'leaveDone',
      'switchOldLeft',
      'tokenOk',
      'connectOk',
      'switchConnected',
    ]);
    expect(rig.linesOf('prepare').single, allOf(contains('key=b|'), contains('new switch supersedes=a|')));
    expect(rig.linesOf('abandon').single, allOf(contains('key=a|'), endsWith('reason=superseded')));
    expect(rig.linesOf('switchConnected').single, contains('key=b|'));
    rig.expectClean();
    await rig.dispose(tester);
  });

  testWidgets('adopt: one line on the adopted session', (tester) async {
    final rig = Rig();
    final room = Room();
    rig.rooms.add(room);
    rig.join.adopt(const GravixTokenRequest(room: 'a', identity: identity, canPublish: true), room);
    expect(rig.linesOf('adopt').single, contains('key=a|'));
    rig.expectClean();
    await rig.dispose(tester);
  });

  testWidgets('the standby pool: an open, a failed open (type only), a reuse', (tester) async {
    final lines = <String>[];
    var open = false;
    final pool = GravixStandbyPool(
      opener: (u, t, rtt) async {
        if (u.contains('bad')) throw StateError('socket to $u failed');
        open = true;
        return true;
      },
      stateOf: (u, t) => GravixStandbyState(open && !u.contains('bad') ? 'open' : 'none'),
      inForeground: () => true,
      autoTick: false,
      log: lines.add,
    );
    final t = jwt('a');
    await tester.runAsync(() => pool.touchCard('a', url: url, token: t));
    await tester.runAsync(() => pool.touchCard('a', url: url, token: t));
    await tester.runAsync(() => pool.touchCard('b', url: 'wss://bad.example.test/x?token=$t', token: t));
    expect(lines.where((l) => l.contains(' standbyOpen ')).first, contains('host=rtc.example.test role=touched'));
    expect(lines.where((l) => l.contains(' standbyReuse ')), isNotEmpty);
    expect(
      lines.where((l) => l.contains(' standbyFail ')).single,
      allOf(contains('host=bad.example.test'), endsWith('err=StateError')),
    );
    for (final l in lines) {
      expect(l, isNot(contains('eyJ')));
      expect(l, isNot(contains('SECRETQUERY')));
    }
  });

  test('the rejoin policy: scheduled with its backoff, the attempt, a refusal with why', () {
    fakeAsync((async) {
      final lines = <String>[];
      var allowed = true;
      final p = GravixRejoinPolicy(
        rejoin: () async => false,
        liveOn: () => true,
        mayRejoin: () async => allowed,
        log: lines.add,
      );
      expect(p.sessionEnded(DisconnectReason.signalClose), isTrue);
      expect(lines.last, '[GravixJoin] rejoinScheduled key=- n=1 in=1000ms after=signalClose');
      async.elapse(const Duration(seconds: 1));
      expect(lines.any((l) => l.startsWith('[GravixJoin] rejoinAttempt key=- n=1 total=1')), isTrue);
      expect(lines.any((l) => l.startsWith('[GravixJoin] rejoinFail key=- n=1 connected=false')), isTrue);
      expect(lines.last, '[GravixJoin] rejoinScheduled key=- n=2 in=2000ms after=retry');
      allowed = false;
      async.elapse(const Duration(seconds: 2));
      expect(lines.last, '[GravixJoin] rejoinRefused key=- why=entry check');
      expect(p.sessionEnded(DisconnectReason.participantRemoved), isFalse);
      p.dispose();
      final q = GravixRejoinPolicy(rejoin: () async => true, liveOn: () => true, log: lines.add);
      expect(q.sessionEnded(DisconnectReason.participantRemoved), isFalse);
      expect(lines.last, '[GravixJoin] rejoinRefused key=- why=not after participantRemoved');
      q.dispose();
    });
  });
}

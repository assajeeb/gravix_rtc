// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19: rooms this SDK cannot join (owner 2026-10-15: "all the apps' rooms
// still exist on the old LiveKit -- handle that also, not to count"). Many live
// rooms are hosted by old app builds on the old, retired server: the app's token
// callback refuses them (its own "old app version" exception), or the token
// answer names a retired Gravix host (RetiredServerException). Before, warm()
// logged `warmFail` for them and every list refresh warmed them again (one
// line and one token call per card per rebuild). Now:
//  - a refusal is: a RetiredServerException (built in), a GravixRoomRefused the
//    callback throws, or what the app's `isRefusal` says of its own exception;
//  - warm(): one `warmRefused` line + a `refused` event, the room remembered for
//    `refusalMemo` (default 60 s): warms inside it do nothing (one verbose
//    `warmSkip reason=refused` line at most);
//  - prepare / attach still ask the callback (the app shows its old-app message),
//    fail fast with the app's own error, log `refused` (not `connectFail`) and
//    refresh the memo; a token for the room clears it; forgetAll clears it;
//  - isRefused(request) for a list badge; refusals are never failures.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const okUrl = 'wss://rtc.example.test';
// a retired host, spelled by the SDK's own list (no host literal in a test)
final retiredUrl = 'wss://${RetiredServerException.retiredHosts.first}';

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

/// An app's own "room of an old app version" exception, with a message that
/// must never reach a log line.
class OldAppRoom implements Exception {
  const OldAppRoom();

  @override
  String toString() => 'OldAppRoom(host_app_outdated token=secret-value)';
}

/// What the token callback does for a room.
enum Answer { ok, retired, oldApp, sdkRefused, down }

class Rig {
  Rig({this.isRefusal, this.refusalMemo = const Duration(seconds: 60), this.connectError});

  final bool Function(Object e)? isRefusal;
  final Duration refusalMemo;
  final Object? connectError;
  DateTime clock = DateTime(2026, 10, 15, 12);
  final answers = <String, Answer>{};
  final calls = <String>[];
  final lines = <String>[];
  final events = <GravixJoinEvent>[];
  final rooms = <Room>[];

  late final tokens = GravixTokenProvider.callback((r) async {
    calls.add(r.room);
    switch (answers[r.room] ?? Answer.ok) {
      case Answer.ok:
        return {'token': jwt(r.room, n: calls.length), 'url': okUrl};
      case Answer.retired:
        return {'token': jwt(r.room, n: calls.length), 'url': retiredUrl};
      case Answer.oldApp:
        throw const OldAppRoom();
      case Answer.sdkRefused:
        throw const GravixRoomRefused('host_app_outdated');
      case Answer.down:
        throw StateError('backend down');
    }
  }, reuse: GravixTokenReuse.fastJoin);

  late final pool = GravixStandbyPool(
    opener: (u, t, rtt) async => true,
    stateOf: (u, t) => const GravixStandbyState('none'),
    inForeground: () => true,
    autoTick: false,
  );

  late final join = GravixJoin(
    tokenProvider: tokens,
    standbyPool: pool,
    bindStandbyLifecycle: false,
    isRefusal: isRefusal,
    refusalMemo: refusalMemo,
    now: () => clock,
    createRoom: () {
      final r = Room();
      rooms.add(r);
      return r;
    },
    connect: (room, t) async {
      final e = connectError;
      if (e != null) throw e;
    },
    leave: (room) async {},
    onEvent: events.add,
    log: lines.add,
  );

  List<String> get steps => [
    for (final l in lines)
      if (l.startsWith('${GravixJoinLog.prefix} ')) l.split(' ')[1],
  ];

  List<String> linesOf(String step) => lines.where((l) => l.startsWith('${GravixJoinLog.prefix} $step ')).toList();

  List<GravixJoinEventKind> get kinds => [for (final e in events) e.kind];

  Future<void> dispose(WidgetTester tester) => tester.runAsync(() async {
    await GravixPrejoin.debugEndAll();
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });
}

GravixTokenRequest req(String room) => GravixTokenRequest(room: room, identity: 'u1');

bool oldApp(Object e) => e is OldAppRoom;

void main() {
  final savedLevel = GravixJoinLog.level;
  setUp(() => GravixJoinLog.level = GravixJoinLogLevel.verbose);
  tearDown(() async {
    GravixJoinLog.level = savedLevel;
    await GravixPrejoin.debugEndAll();
  });

  group('classification', () {
    test('built in: a RetiredServerException and a GravixRoomRefused, also inside a GravixTokenException', () {
      final join = Rig().join;
      for (final e in <Object>[
        RetiredServerException(RetiredServerException.retiredHosts.first),
        const GravixRoomRefused(),
        GravixTokenException(
          GravixTokenErrorReason.malformed,
          'retired',
          cause: RetiredServerException(RetiredServerException.retiredHosts.first),
        ),
        const GravixTokenException(GravixTokenErrorReason.callback, 'x', cause: GravixRoomRefused('old')),
      ]) {
        expect(GravixRoomRefused.isBuiltIn(e), isTrue, reason: '$e');
        expect(join.isRefusalError(e), isTrue, reason: '$e');
      }
      for (final e in <Object>[
        StateError('x'),
        const OldAppRoom(),
        const GravixTokenException(GravixTokenErrorReason.timeout, 'no token'),
        const GravixTokenException(GravixTokenErrorReason.callback, 'x', cause: OldAppRoom()),
      ]) {
        expect(GravixRoomRefused.isBuiltIn(e), isFalse, reason: '$e');
        expect(join.isRefusalError(e), isFalse, reason: '$e');
      }
    });

    test("the app's isRefusal is given the unwrapped error; a throwing isRefusal is not a refusal", () {
      final seen = <Object>[];
      final join = Rig(
        isRefusal: (e) {
          seen.add(e);
          if (e is StateError) throw ArgumentError('bad predicate');
          return e is OldAppRoom;
        },
      ).join;
      expect(
        join.isRefusalError(const GravixTokenException(GravixTokenErrorReason.callback, 'x', cause: OldAppRoom())),
        isTrue,
      );
      expect(seen.single, isA<OldAppRoom>());
      expect(join.isRefusalError(StateError('x')), isFalse);
      expect(join.isRefusal, isNotNull);
    });

    test('GravixRoomRefused: the reason is kept, toString names it', () {
      const e = GravixRoomRefused('host_app_outdated');
      expect(e.reason, 'host_app_outdated');
      expect(e.toString(), contains('host_app_outdated'));
      expect(const GravixRoomRefused().reason, isNull);
    });
  });

  group('warm', () {
    test('a retired server url in the token answer: warmRefused + a refused event, not warmFail', () async {
      final rig = Rig()..answers['old'] = Answer.retired;
      expect(await rig.join.warm(req('old'), role: GravixStandbyRole.visible), isNull);
      expect(rig.linesOf('warmFail'), isEmpty);
      expect(rig.linesOf('warmRefused').single, endsWith('reason=RetiredServerException'));
      expect(rig.linesOf('warmRefused').single, contains('key=old|'));
      final ev = rig.events.single;
      expect(ev.kind, GravixJoinEventKind.refused);
      expect(ev.detail, 'RetiredServerException');
      expect(ev.session?.room, 'old');
      expect(rig.join.isRefused(req('old')), isTrue);
      expect(rig.pool.candidates, isEmpty);
    });

    test("the app's own exception with isRefusal: warmRefused reason=<its type>, never its message", () async {
      final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
      expect(await rig.join.warm(req('old')), isNull);
      final line = rig.linesOf('warmRefused').single;
      expect(line, endsWith('reason=OldAppRoom'));
      expect(line, isNot(contains('secret')));
      expect(line, isNot(contains('host_app_outdated')));
      expect(rig.join.isRefused(req('old')), isTrue);
    });

    test('the same exception without isRefusal stays a failure (warmFail, nothing remembered)', () async {
      final rig = Rig()..answers['old'] = Answer.oldApp;
      expect(await rig.join.warm(req('old')), isNull);
      expect(rig.linesOf('warmRefused'), isEmpty);
      expect(rig.linesOf('warmFail').single, endsWith('not warmed (callback, cause OldAppRoom)'));
      expect(rig.join.isRefused(req('old')), isFalse);
      expect(rig.kinds, isNot(contains(GravixJoinEventKind.refused)));
      await rig.join.warm(req('old'));
      expect(rig.calls, ['old', 'old'], reason: 'a failure is asked again');
    });

    test('a GravixRoomRefused from the callback is a refusal with no isRefusal', () async {
      final rig = Rig()..answers['old'] = Answer.sdkRefused;
      expect(await rig.join.warm(req('old')), isNull);
      expect(rig.linesOf('warmRefused').single, endsWith('reason=GravixRoomRefused'));
      expect(rig.join.isRefused(req('old')), isTrue);
    });

    test('inside the memo further warms do nothing: no callback, one verbose warmSkip at most', () async {
      final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
      await rig.join.warm(req('old'), role: GravixStandbyRole.visible);
      for (var i = 0; i < 5; i++) {
        rig.clock = rig.clock.add(const Duration(seconds: 10));
        expect(await rig.join.warm(req('old'), role: GravixStandbyRole.visible, rank: i), isNull);
      }
      expect(rig.calls, ['old'], reason: 'one token call for the whole minute');
      expect(rig.linesOf('warmRefused'), hasLength(1));
      expect(rig.linesOf('warmFail'), isEmpty);
      expect(rig.linesOf('warmSkip').single, endsWith('reason=refused'));
      expect(rig.kinds.where((k) => k == GravixJoinEventKind.refused), hasLength(1));
      expect(rig.pool.candidates, isEmpty);
      // after the memo the next warm asks again (the host may have updated)
      rig.clock = rig.clock.add(const Duration(seconds: 11));
      expect(rig.join.isRefused(req('old')), isFalse);
      await rig.join.warm(req('old'));
      expect(rig.calls, ['old', 'old']);
      expect(rig.linesOf('warmRefused'), hasLength(2));
    });

    test('the warmSkip line is verbose: none at info', () async {
      GravixJoinLog.level = GravixJoinLogLevel.info;
      final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
      await rig.join.warm(req('old'));
      await rig.join.warm(req('old'));
      await rig.join.warm(req('old'));
      expect(rig.steps, ['warmRefused']);
    });

    test('a token for the room clears the memo; other rooms are not affected', () async {
      final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
      await rig.join.warm(req('old'));
      expect(await rig.join.warm(req('new')), isNotNull);
      expect(rig.join.isRefused(req('new')), isFalse);
      expect(rig.join.isRefused(req('old')), isTrue);
      rig.answers['old'] = Answer.ok;
      rig.clock = rig.clock.add(const Duration(seconds: 61));
      expect(await rig.join.warm(req('old')), isNotNull);
      expect(rig.join.isRefused(req('old')), isFalse);
    });

    test('forgetAll clears the memo', () async {
      final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
      await rig.join.warm(req('old'));
      rig.join.forgetAll();
      expect(rig.join.isRefused(req('old')), isFalse);
      await rig.join.warm(req('old'));
      expect(rig.calls, ['old', 'old']);
    });

    test('refusalMemo zero: classified and logged, never remembered', () async {
      final rig = Rig(isRefusal: oldApp, refusalMemo: Duration.zero)..answers['old'] = Answer.oldApp;
      await rig.join.warm(req('old'));
      await rig.join.warm(req('old'));
      expect(rig.calls, ['old', 'old']);
      expect(rig.linesOf('warmRefused'), hasLength(2));
      expect(rig.join.isRefused(req('old')), isFalse);
    });

    test('a plain failure is still warmFail', () async {
      final rig = Rig(isRefusal: oldApp)..answers['x'] = Answer.down;
      await rig.join.warm(req('x'));
      expect(rig.linesOf('warmFail').single, endsWith('not warmed (callback, cause StateError)'));
      expect(rig.join.isRefused(req('x')), isFalse);
    });
  });

  group('prepare / attach', () {
    testWidgets(
      'inside the memo the callback is still asked; attachOrThrow throws the app error; refused, not connectFail',
      (tester) async {
        final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
        await rig.join.warm(req('old'));
        rig.events.clear();
        rig.lines.clear();
        await expectLater(rig.join.attachOrThrow(req('old')), throwsA(isA<OldAppRoom>()));
        expect(rig.calls, ['old', 'old'], reason: 'the app may show its old-app message');
        expect(rig.steps, contains('refused'));
        expect(rig.steps, isNot(contains('connectFail')));
        expect(rig.steps, isNot(contains('tokenFail')));
        expect(rig.steps, isNot(contains('connectStart')));
        final line = rig.linesOf('refused').single;
        expect(line, endsWith('reason=OldAppRoom'));
        expect(line, isNot(contains('secret')));
        expect(rig.kinds, contains(GravixJoinEventKind.refused));
        expect(rig.kinds, isNot(contains(GravixJoinEventKind.connectFailed)));
        expect(rig.events.firstWhere((e) => e.kind == GravixJoinEventKind.refused).detail, 'OldAppRoom');
        await rig.dispose(tester);
      },
    );

    testWidgets('a refused prepare refreshes the memo', (tester) async {
      final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
      await rig.join.warm(req('old')); // t+0
      rig.clock = rig.clock.add(const Duration(seconds: 50));
      final h = rig.join.prepare(req('old')); // t+50
      expect(await h.attach(), isNull);
      rig.clock = rig.clock.add(const Duration(seconds: 50)); // t+100
      expect(rig.join.isRefused(req('old')), isTrue, reason: 'remembered from the prepare at t+50');
      rig.clock = rig.clock.add(const Duration(seconds: 11)); // t+111
      expect(rig.join.isRefused(req('old')), isFalse);
      await rig.dispose(tester);
    });

    testWidgets('attachResult: the unwrapped app error; the handle says refused and ended failed', (tester) async {
      final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
      final r = await rig.join.attachResult(req('old'));
      expect(r.room, isNull);
      expect(r.error, isA<OldAppRoom>());
      expect(r.handle.refused, isTrue);
      expect(await r.handle.ended, GravixPrejoinEndReason.failed);
      expect(rig.join.isRefused(req('old')), isTrue, reason: 'a tap refusal is remembered too');
      await rig.dispose(tester);
    });

    testWidgets('a retired url from the token answer: refused at the tap too', (tester) async {
      final rig = Rig()..answers['old'] = Answer.retired;
      await expectLater(rig.join.attachOrThrow(req('old')), throwsA(isA<RetiredServerException>()));
      expect(rig.linesOf('refused').single, endsWith('reason=RetiredServerException'));
      expect(rig.join.isRefused(req('old')), isTrue);
      await rig.dispose(tester);
    });

    testWidgets('a connect that throws a refusal (GravixRoomRefused) is refused, not connectFail', (tester) async {
      final rig = Rig(connectError: const GravixRoomRefused());
      final h = rig.join.prepare(req('r'));
      expect(await h.attach(), isNull);
      expect(h.refused, isTrue);
      expect(rig.steps, contains('refused'));
      expect(rig.steps, isNot(contains('connectFail')));
      expect(rig.join.isRefused(req('r')), isTrue);
      await rig.dispose(tester);
    });

    testWidgets('a successful join inside the memo clears it', (tester) async {
      final rig = Rig(isRefusal: oldApp)..answers['old'] = Answer.oldApp;
      await rig.join.warm(req('old'));
      rig.answers['old'] = Answer.ok; // the host updated the app
      final room = await rig.join.attach(req('old'));
      expect(room, isNotNull);
      expect(rig.join.isRefused(req('old')), isFalse);
      await rig.join.warm(req('old'));
      expect(rig.linesOf('warmSkip'), isEmpty);
      await rig.dispose(tester);
    });

    testWidgets('a plain token failure at the tap is still connectFail, not refused', (tester) async {
      final rig = Rig(isRefusal: oldApp)..answers['x'] = Answer.down;
      final h = rig.join.prepare(req('x'));
      expect(await h.attach(), isNull);
      expect(h.refused, isFalse);
      expect(rig.steps, contains('connectFail'));
      expect(rig.steps, isNot(contains('refused')));
      expect(rig.join.isRefused(req('x')), isFalse);
      await rig.dispose(tester);
    });
  });
}

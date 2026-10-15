// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join, the app layer (2026-10-15, package-first): three host apps
// each wrote the same wrapper around GravixJoin after migrating to it --
// a createRoom / connect / leave bundle handed to prepare / attach / switchTo,
// an attach that throws the app's own token exception (not the provider's
// GravixTokenException) and hands out the session's handle, an attach result
// that never throws (one app), `isLive(Room)`, the session key's parts for a join
// trace, and "the user left before the room was shown". Two of the apps
// started the attach before awaiting a permission dialog: a token failure in
// that window was reported by Dart as an unhandled async error first.
import 'dart:async';
import 'dart:convert';

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

/// The app's own refusal (e.g. a room hosted by an old app version).
class AppRefusal implements Exception {
  const AppRefusal(this.why);
  final String why;
}

/// The app's own connect failure (its connect hook reported it already).
class AppConnectFailed implements Exception {
  const AppConnectFailed();
}

class Rig {
  Rig({this.refuse = false});
  final bool refuse;
  final log = <String>[];
  final rooms = <Room>[];
  int fetches = 0;

  late final tokens = GravixTokenProvider.callback((r) async {
    fetches++;
    if (refuse) throw const AppRefusal('host_app_outdated');
    return {'token': jwt(r.room, n: fetches), 'url': url};
  }, reuse: GravixTokenReuse.fastJoin);

  late final pool = GravixStandbyPool(opener: (u, t, rtt) async => true, inForeground: () => true, autoTick: false);

  late final join = GravixJoin(
    tokenProvider: tokens,
    standbyPool: pool,
    bindStandbyLifecycle: false,
    createRoom: () => newRoom('ctor'),
    connect: (room, t) async => log.add('connect ctor'),
    leave: (room) async => log.add('leave ctor'),
  );

  Room newRoom(String by) {
    final r = Room();
    rooms.add(r);
    log.add('room $by');
    return r;
  }

  GravixJoinHooks hooks(String tag, {Object? connectError}) => GravixJoinHooks(
    createRoom: () => newRoom(tag),
    connect: (room, t) async {
      log.add('connect $tag');
      if (connectError != null) throw connectError;
    },
    leave: (room) async => log.add('leave $tag'),
  );

  Future<void> dispose(WidgetTester tester) => tester.runAsync(() async {
    await GravixPrejoin.debugEndAll();
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });
}

GravixTokenRequest req(String room, {bool canPublish = false}) =>
    GravixTokenRequest(room: room, identity: 'u1', canPublish: canPublish);

void main() {
  group('GravixJoinHooks: one bundle for prepare / attach / switchTo / adopt', () {
    testWidgets('prepare(hooks:) builds, connects and leaves with the bundle', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(req('a'), hooks: rig.hooks('app'));
      await tester.pump();
      expect(h.state, GravixPrejoinState.connected);
      await h.leave();
      expect(rig.log, ['room app', 'connect app', 'leave app']);
      await rig.dispose(tester);
    });

    testWidgets('an explicit createRoom / connect / leave wins over the bundle', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(
        req('a'),
        hooks: rig.hooks('app'),
        connect: (room, t) async => rig.log.add('connect own'),
      );
      await tester.pump();
      await h.leave();
      expect(rig.log, ['room app', 'connect own', 'leave app']);
      await rig.dispose(tester);
    });

    testWidgets('attach(hooks:) joins cold with the bundle; a live handle keeps its own', (tester) async {
      final rig = Rig();
      final room = await rig.join.attach(req('a'), hooks: rig.hooks('cold'));
      expect(room, isNotNull);
      expect(rig.log, ['room cold', 'connect cold']);
      final again = await rig.join.attach(req('a'), hooks: rig.hooks('other'));
      expect(again, same(room));
      expect(rig.log, ['room cold', 'connect cold']);
      await rig.dispose(tester);
    });

    testWidgets('switchTo(hooks:) leaves the old session with ITS hooks, connects the new with the bundle', (
      tester,
    ) async {
      final rig = Rig();
      final a = rig.join.prepare(req('a'), hooks: rig.hooks('A'));
      await rig.join.attach(req('a'));
      await tester.pump();
      final b = rig.join.switchTo(req('b'), hooks: rig.hooks('B'), beforeConnect: () async => true);
      await tester.pump();
      expect(await a.ended, GravixPrejoinEndReason.superseded);
      expect(b.state, GravixPrejoinState.connected);
      expect(rig.log, ['room A', 'connect A', 'leave A', 'room B', 'connect B']);
      await rig.dispose(tester);
    });

    testWidgets("adopt(hooks:) leaves the adopted Room with the bundle's leave", (tester) async {
      final rig = Rig();
      final room = rig.newRoom('own');
      final h = rig.join.adopt(req('a', canPublish: true), room, hooks: rig.hooks('app'));
      await h.leave();
      expect(rig.log, ['room own', 'leave app']);
      await rig.dispose(tester);
    });
  });

  group('attachResult: never throws', () {
    testWidgets('the tap connected first: room, handle, connectedBeforeAttach', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(req('a'), hooks: rig.hooks('app'));
      await tester.pump();
      final r = await rig.join.attachResult(req('a'), hooks: rig.hooks('other'));
      expect(r.room, same(h.room));
      expect(r.handle, same(h));
      expect(r.connectedBeforeAttach, isTrue);
      expect(r.error, isNull);
      expect(r.isLive, isFalse, reason: 'a fake connect leaves the Room disconnected');
      expect(rig.log, ['room app', 'connect app']);
      await rig.dispose(tester);
    });

    testWidgets('a cold join (nothing pending): joins with the hooks, connectedBeforeAttach false', (tester) async {
      final rig = Rig();
      final r = await rig.join.attachResult(req('a'), hooks: rig.hooks('cold'));
      expect(r.room, isNotNull);
      expect(r.connectedBeforeAttach, isFalse);
      expect(r.handle.state, GravixPrejoinState.attached);
      expect(rig.log, ['room cold', 'connect cold']);
      await rig.dispose(tester);
    });

    testWidgets("a refused token: null room, the app's own exception as error, no throw", (tester) async {
      final rig = Rig(refuse: true);
      final r = await rig.join.attachResult(req('a'), hooks: rig.hooks('app'));
      expect(r.room, isNull);
      expect(r.error, isA<AppRefusal>());
      expect(r.handle.error, isA<GravixTokenException>());
      expect(await r.handle.ended, GravixPrejoinEndReason.failed);
      expect(rig.log, isEmpty, reason: 'no Room without a token');
      await rig.dispose(tester);
    });
  });

  group('attachOrThrow: the unwrapped cause, never an unhandled error', () {
    testWidgets('connected: the Room; onHandle gets the handle at the call', (tester) async {
      final rig = Rig();
      GravixPrejoin? seen;
      final f = rig.join.attachOrThrow(req('a'), hooks: rig.hooks('app'), onHandle: (h) => seen = h);
      expect(seen, isNotNull, reason: 'before the connect returned');
      expect(seen!.state, isNot(GravixPrejoinState.ended));
      final room = await f;
      expect(room, same(seen!.room));
      await rig.dispose(tester);
    });

    testWidgets("a refused token throws the token callback's own exception, not GravixTokenException", (tester) async {
      final rig = Rig(refuse: true);
      GravixPrejoin? seen;
      await expectLater(
        rig.join.attachOrThrow(req('a'), hooks: rig.hooks('app'), onHandle: (h) => seen = h),
        throwsA(isA<AppRefusal>().having((e) => e.why, 'why', 'host_app_outdated')),
      );
      expect(seen!.error, isA<GravixTokenException>());
      await rig.dispose(tester);
    });

    testWidgets('started before a permission dialog: the failure waits for the await, never unhandled', (tester) async {
      // the screens: final attaching = attachOrThrow(...); await permissions; await attaching
      final rig = Rig(refuse: true);
      final attaching = rig.join.attachOrThrow(req('a'), hooks: rig.hooks('app'));
      // the dialog: the token fails meanwhile (an unhandled error fails this test)
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      Object? caught;
      try {
        await attaching;
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<AppRefusal>());
      await rig.dispose(tester);
    });

    test('outside a widget test too: no uncaught error in the zone while nobody awaits yet', () async {
      final uncaught = <Object>[];
      final done = Completer<Object?>();
      runZonedGuarded(() async {
        final tokens = GravixTokenProvider.callback(
          (r) async => throw const AppRefusal('x'),
          reuse: GravixTokenReuse.fastJoin,
        );
        final join = GravixJoin(
          tokenProvider: tokens,
          standbyPool: GravixStandbyPool(opener: (u, t, rtt) async => true, inForeground: () => true, autoTick: false),
          bindStandbyLifecycle: false,
          abandonInBackground: false,
          attachTimeout: null,
        );
        final attaching = join.attachOrThrow(req('zone'), hooks: GravixJoinHooks(createRoom: Room.new));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          await attaching;
          done.complete(null);
        } catch (e) {
          done.complete(e);
        }
      }, (e, s) => uncaught.add(e));
      expect(await done.future, isA<AppRefusal>());
      expect(uncaught, isEmpty);
      await GravixPrejoin.debugEndAll();
    });

    testWidgets('a GravixTokenException without a cause is thrown as it is', (tester) async {
      final tokens = GravixTokenProvider.callback(
        (r) async => throw const GravixTokenException(GravixTokenErrorReason.malformed, 'bad'),
        reuse: GravixTokenReuse.fastJoin,
      );
      final rig = Rig();
      final join = GravixJoin(tokenProvider: tokens, standbyPool: rig.pool, bindStandbyLifecycle: false);
      Object? caught;
      try {
        await join.attachOrThrow(req('a'), hooks: rig.hooks('app'));
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<GravixTokenException>());
      await rig.dispose(tester);
    });

    testWidgets('throwIf false (a connect failure the app reported itself): null, no throw', (tester) async {
      final rig = Rig();
      final room = await rig.join.attachOrThrow(
        req('a'),
        hooks: rig.hooks('app', connectError: const AppConnectFailed()),
        throwIf: (e) => e is! AppConnectFailed,
      );
      expect(room, isNull);
      await rig.dispose(tester);
    });

    testWidgets('by default a connect error is thrown too', (tester) async {
      final rig = Rig();
      await expectLater(
        rig.join.attachOrThrow(req('a'), hooks: rig.hooks('app', connectError: const AppConnectFailed())),
        throwsA(isA<AppConnectFailed>()),
      );
      await rig.dispose(tester);
    });

    testWidgets('ended without an error (a gate abandoned it): null, no throw', (tester) async {
      final rig = Rig();
      final f = rig.join.attachOrThrow(req('a'), hooks: rig.hooks('app'));
      await rig.join.abandon(req('a'));
      expect(await f, isNull);
      await rig.dispose(tester);
    });
  });

  group('small pieces', () {
    test('unwrapError: the cause inside a GravixTokenException, anything else as it is', () {
      const refusal = AppRefusal('x');
      const wrapped = GravixTokenException(GravixTokenErrorReason.callback, 'threw', cause: refusal);
      expect(GravixJoin.unwrapError(wrapped), same(refusal));
      const bare = GravixTokenException(GravixTokenErrorReason.malformed, 'bad');
      expect(GravixJoin.unwrapError(bare), same(bare));
      final other = StateError('x');
      expect(GravixJoin.unwrapError(other), same(other));
    });

    testWidgets('isLive: null and a disconnected Room are not live', (tester) async {
      expect(GravixJoin.isLive(null), isFalse);
      final r = Room();
      expect(GravixJoin.isLive(r), isFalse);
      await tester.runAsync(() => r.dispose());
    });

    test('a session key reads back as room / identity / publish right', () {
      final key = GravixPrejoin.sessionKey(req('abc12live', canPublish: true));
      expect(GravixPrejoin.parseSessionKey(key), (room: 'abc12live', identity: 'u1', canPublish: true));
      expect(GravixPrejoin.parseSessionKey('nonsense'), isNull);
      final e = GravixJoinEvent(
        kind: GravixJoinEventKind.urlChosen,
        key: key,
        at: DateTime(2026),
        sinceTap: Duration.zero,
      );
      expect(e.session, (room: 'abc12live', identity: 'u1', canPublish: true));
    });

    test('leftBeforeShown: only background and neverShown close a room screen', () {
      final yes = GravixPrejoinEndReason.values.where((r) => r.leftBeforeShown).toSet();
      expect(yes, {GravixPrejoinEndReason.background, GravixPrejoinEndReason.neverShown});
    });

    testWidgets('hasToken / dropToken: the provider cache for a request', (tester) async {
      final rig = Rig();
      expect(rig.join.hasToken(req('a')), isFalse);
      await rig.join.warm(req('a'));
      expect(rig.join.hasToken(req('a')), isTrue);
      rig.join.dropToken(req('a'));
      expect(rig.join.hasToken(req('a')), isFalse);
      await rig.dispose(tester);
    });
  });
}

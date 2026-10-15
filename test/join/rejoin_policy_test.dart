// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19: GravixRejoinPolicy, the viewer rejoin the apps wrote by hand.
// Field 2026-10-13: a viewer stayed on "waiting for the host's video" forever
// after the host left and came back on the same room: the viewer's session had
// ended with the live and nothing joined again. The policy: join again when the
// live is back, and after a session that ended by itself while the live is on
// (bounded backoff); never after a kick, the same identity joining elsewhere, a
// deleted room, a refused join or our own leave; at most 3 rejoins in a row while
// each session ends again within 60 s (two phones of one account must not kick
// each other forever); at most maxTotal per live; an optional entry check.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

class Rig {
  Rig({Future<bool> Function()? mayRejoin, int maxTotal = 12}) {
    r = GravixRejoinPolicy(
      rejoin: () async => answer(++joins),
      liveOn: () => live,
      onGaveUp: () => gaveUp++,
      mayRejoin: mayRejoin,
      maxTotal: maxTotal,
      now: () => clock,
      log: log.add,
    );
  }
  bool live = true;
  int joins = 0;
  bool Function(int n) answer = (_) => true;
  int gaveUp = 0;
  DateTime clock = DateTime(2026, 10, 15, 12);
  final log = <String>[];
  late final GravixRejoinPolicy r;
}

void main() {
  test('rejoinable: transport-style ends yes; a kick, another device, a delete, a refusal, our leave no', () {
    for (final r in [
      null,
      DisconnectReason.unknown,
      DisconnectReason.signalingConnectionFailure,
      DisconnectReason.reconnectAttemptsExceeded,
      DisconnectReason.serverShutdown,
      DisconnectReason.migration,
    ]) {
      expect(GravixRejoinPolicy.rejoinable(r), isTrue, reason: '$r');
    }
    for (final r in [
      DisconnectReason.clientInitiated,
      DisconnectReason.participantRemoved,
      DisconnectReason.duplicateIdentity,
      DisconnectReason.roomDeleted,
      DisconnectReason.joinFailure,
    ]) {
      expect(GravixRejoinPolicy.rejoinable(r), isFalse, reason: '$r');
    }
  });

  testWidgets('live ended: nothing rejoins; live again: one join at once', (tester) async {
    final g = Rig()..live = false;
    g.r.liveEnded();
    g.r.sessionEnded();
    await tester.pump(const Duration(seconds: 30));
    expect(g.joins, 0);
    g.live = true;
    g.r.liveBack();
    await tester.pump(const Duration(milliseconds: 1));
    expect(g.joins, 1);
  });

  testWidgets('liveBack without an end before: nothing', (tester) async {
    final g = Rig();
    g.r.liveBack();
    await tester.pump(const Duration(seconds: 5));
    expect(g.joins, 0);
  });

  testWidgets('a session ended by itself: rejoin after 1 s; success resets the count', (tester) async {
    final g = Rig();
    expect(g.r.sessionEnded(), isTrue);
    await tester.pump(const Duration(milliseconds: 999));
    expect(g.joins, 0);
    await tester.pump(const Duration(milliseconds: 2));
    expect(g.joins, 1);
    expect(g.r.attempts, 0);
    expect(g.r.pending, isFalse);
  });

  testWidgets('a kick is never rejoined', (tester) async {
    final g = Rig();
    expect(g.r.sessionEnded(DisconnectReason.participantRemoved), isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(g.joins, 0);
  });

  testWidgets('bounded backoff 1, 2, 4, 8 s, then gives up', (tester) async {
    final g = Rig()..answer = (_) => false;
    g.r.sessionEnded();
    for (final (wait, n) in [(1, 1), (2, 2), (4, 3), (8, 4)]) {
      await tester.pump(Duration(seconds: wait));
      expect(g.joins, n);
    }
    await tester.pump(const Duration(seconds: 60));
    expect(g.joins, 4);
    expect(g.gaveUp, 1);
  });

  testWidgets('the live ends while retrying: stops cleanly, no give-up', (tester) async {
    final g = Rig()..answer = (_) => false;
    g.r.sessionEnded();
    await tester.pump(const Duration(seconds: 1));
    g.live = false;
    g.r.liveEnded();
    await tester.pump(const Duration(seconds: 60));
    expect(g.joins, 1);
    expect(g.gaveUp, 0);
  });

  testWidgets('one rejoin at a time; dispose cancels it', (tester) async {
    final g = Rig();
    g.r.sessionEnded();
    expect(g.r.sessionEnded(), isFalse);
    g.r.dispose();
    await tester.pump(const Duration(seconds: 30));
    expect(g.joins, 0);
  });

  testWidgets('sessions that end again at once: 3 rejoins, then give up (no ping-pong)', (tester) async {
    final g = Rig();
    for (var i = 1; i <= 3; i++) {
      g.r.sessionEnded();
      await tester.pump(const Duration(seconds: 1));
      expect(g.joins, i);
      g.clock = g.clock.add(const Duration(seconds: 5)); // ends again 5 s later
    }
    expect(g.r.sessionEnded(), isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(g.joins, 3);
    expect(g.gaveUp, 1);
  });

  testWidgets('a session that stayed up 60 s ends the incident', (tester) async {
    final g = Rig();
    for (var i = 1; i <= 3; i++) {
      g.r.sessionEnded();
      await tester.pump(const Duration(seconds: 1));
      g.clock = g.clock.add(const Duration(seconds: 61));
    }
    expect(g.r.sessionEnded(), isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(g.joins, 4);
  });

  testWidgets('maxTotal per live; liveBack starts a new budget', (tester) async {
    final g = Rig(maxTotal: 2);
    for (var i = 0; i < 3; i++) {
      g.r.sessionEnded();
      await tester.pump(const Duration(seconds: 1));
      g.clock = g.clock.add(const Duration(minutes: 2));
    }
    expect(g.joins, 2);
    expect(g.gaveUp, 1);
    g.r.liveEnded();
    g.r.liveBack();
    await tester.pump(const Duration(milliseconds: 1));
    expect(g.joins, 3);
  });

  testWidgets('the entry check refuses: never again on this screen; a slow check counts as yes', (tester) async {
    var allowed = false;
    final g = Rig(mayRejoin: () async => allowed);
    g.r.sessionEnded();
    await tester.pump(const Duration(seconds: 1));
    expect(g.joins, 0);
    expect(g.r.refused, isTrue);
    allowed = true;
    expect(g.r.sessionEnded(), isFalse);

    final slow = Rig(mayRejoin: () => Completer<bool>().future);
    slow.r.sessionEnded();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    expect(slow.joins, 1);
  });

  group('gravixConnectWhileAlive', () {
    test('no connect for a screen already gone', () async {
      var connects = 0;
      final ok = await gravixConnectWhileAlive(
        alive: () => false,
        connect: () async => ++connects > 0,
        disconnect: () async {},
      );
      expect(ok, isFalse);
      expect(connects, 0);
    });

    test('a session joined while the screen closed is left again', () async {
      var alive = true;
      var left = 0;
      final ok = await gravixConnectWhileAlive(
        alive: () => alive,
        connect: () async {
          alive = false;
          return true;
        },
        disconnect: () async => left++,
      );
      expect(ok, isFalse);
      expect(left, 1);
    });
  });

  // 0.4.19 (owner 2026-10-15: rooms on the old server, "not to count"): a rejoin
  // whose join is refused (a RetiredServerException, a GravixRoomRefused, or the
  // app's isRefusal) is not a failed attempt: not counted, no backoff retry, no
  // give-up (a Retry cannot join it); onRefused gets the app's own error. A new
  // live (liveBack) may try again.
  group('a refused rejoin', () {
    GravixRejoinPolicy policy({
      required Future<bool> Function() rejoin,
      bool Function(Object e)? isRefusal,
      required List<Object> refusedWith,
      required List<int> gaveUp,
      required List<String> log,
    }) => GravixRejoinPolicy(
      rejoin: rejoin,
      liveOn: () => true,
      isRefusal: isRefusal,
      onRefused: refusedWith.add,
      onGaveUp: () => gaveUp.add(1),
      log: log.add,
    );

    testWidgets('a GravixRoomRefused: not counted, no retry, no give-up, onRefused', (tester) async {
      var joins = 0;
      final refusedWith = <Object>[];
      final gaveUp = <int>[];
      final log = <String>[];
      final r = policy(
        rejoin: () async {
          joins++;
          throw const GravixRoomRefused();
        },
        refusedWith: refusedWith,
        gaveUp: gaveUp,
        log: log,
      );
      expect(r.sessionEnded(), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(joins, 1);
      expect(r.attempts, 0, reason: 'a refusal is not a failed attempt');
      expect(r.total, 0);
      expect(r.pending, isFalse);
      expect(r.roomRefused, isTrue);
      expect(refusedWith.single, isA<GravixRoomRefused>());
      await tester.pump(const Duration(seconds: 60));
      expect(joins, 1, reason: 'no backoff retry for a refused room');
      expect(gaveUp, isEmpty);
      expect(log.where((l) => l.contains('rejoinFail')), isEmpty);
      expect(log.where((l) => l.contains('rejoinRefused')).single, contains('why=room refused (GravixRoomRefused)'));
      // the session of a refused room cannot end again, but a new live may join
      r.liveEnded();
      r.liveBack();
      await tester.pump(const Duration(milliseconds: 1));
      expect(joins, 2);
      r.dispose();
    });

    testWidgets("the app's exception inside a GravixTokenException, with isRefusal: unwrapped, not counted", (
      tester,
    ) async {
      final refusedWith = <Object>[];
      final gaveUp = <int>[];
      final log = <String>[];
      final r = policy(
        rejoin: () async => throw const GravixTokenException(GravixTokenErrorReason.callback, 'x', cause: _OldApp()),
        isRefusal: (e) => e is _OldApp,
        refusedWith: refusedWith,
        gaveUp: gaveUp,
        log: log,
      );
      r.sessionEnded();
      await tester.pump(const Duration(seconds: 1));
      expect(r.total, 0);
      expect(refusedWith.single, isA<_OldApp>());
      expect(gaveUp, isEmpty);
      r.dispose();
    });

    testWidgets('a RetiredServerException is a refusal with no isRefusal', (tester) async {
      final refusedWith = <Object>[];
      final r = policy(
        rejoin: () async => throw RetiredServerException(RetiredServerException.retiredHosts.first),
        refusedWith: refusedWith,
        gaveUp: <int>[],
        log: <String>[],
      );
      r.sessionEnded();
      await tester.pump(const Duration(seconds: 1));
      expect(r.total, 0);
      expect(refusedWith.single, isA<RetiredServerException>());
      r.dispose();
    });

    testWidgets('any other throw still counts and retries', (tester) async {
      var joins = 0;
      final r = policy(
        rejoin: () async {
          joins++;
          throw StateError('down');
        },
        isRefusal: (e) => e is _OldApp,
        refusedWith: <Object>[],
        gaveUp: <int>[],
        log: <String>[],
      );
      r.sessionEnded();
      await tester.pump(const Duration(seconds: 1));
      expect(r.attempts, 1);
      expect(r.total, 1);
      expect(r.roomRefused, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(joins, 2);
      r.dispose();
    });
  });
}

class _OldApp implements Exception {
  const _OldApp();
}

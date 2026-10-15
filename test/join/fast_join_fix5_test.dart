// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join, device findings (2026-10-15):
//  - A host's own Go Live join is prepared with `abandonInBackground: false`
//    (its room screen is pushed only after the app's Go Live flow). Home right
//    after the tap and back 25-28 s later: the handle was abandoned at +20 s
//    (`attachTimeout`) while the app was away, because the app's flow does not
//    progress in the background. The attach timeout now counts only the time
//    the app is in front: paused while hidden / paused, resumed on resumed
//    (`attachTimeoutPaused` / `attachTimeoutResumed`). A per-call
//    `attachTimeout` on prepare / attach overrides the constructor's (null:
//    never).
//  - Ghost viewer (1 in 16 tries): Back right after the tap sent the app to the
//    background; the join was abandoned and the app's leave hook started, but
//    the engine detached ~20 ms later and the hook never reached its
//    disconnect: the host saw the viewer until the server timed it out (~34 s).
//    An abandon of a connecting / connected handle, or one for the background
//    (`background` / `neverShown`), now sends the signal leave FIRST
//    (`room.disconnect()`, not awaited: the Leave is written synchronously)
//    and only then runs the leave hook (`leaveSignalFirst`). A detached app
//    ends a handle no screen has shown (also one allowed to survive the
//    background), and a leave hook still running when the app detaches gets
//    its signal leave at once.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

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

/// A Room whose disconnect() is only recorded (the order against the hook).
class SpyRoom extends Room {
  SpyRoom(this.calls);
  final List<String> calls;
  int disconnects = 0;

  @override
  Future<void> disconnect() async {
    disconnects++;
    calls.add('disconnect');
  }
}

void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
  for (final s in states) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void background(WidgetTester tester) =>
    lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);

void foreground(WidgetTester tester) =>
    lifecycle(tester, const [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);

void detach(WidgetTester tester) => lifecycle(tester, const [AppLifecycleState.detached]);

class Rig {
  final calls = <String>[];
  final rooms = <SpyRoom>[];
  final lines = <String>[];
  Completer<void>? hookGate;
  int fetches = 0;

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
    connect: (room, t) async => calls.add('connect'),
    leave: leaveHook,
    log: lines.add,
  );

  SpyRoom newRoom() {
    final r = SpyRoom(calls);
    rooms.add(r);
    return r;
  }

  Future<void> leaveHook(Room room) async {
    calls.add('hookStart');
    final g = hookGate;
    if (g != null) await g.future;
    calls.add('hookDone');
  }

  GravixPrejoin start({
    String key = 'k1',
    Duration? attachTimeout = const Duration(seconds: 20),
    bool abandonInBackground = true,
    DateTime Function()? clock,
  }) => GravixPrejoin.start(
    key: key,
    target: () => const GravixJoinTarget(url: url, token: 't1'),
    createRoom: newRoom,
    connect: (room, t) async => calls.add('connect'),
    leave: leaveHook,
    attachTimeout: attachTimeout,
    abandonInBackground: abandonInBackground,
    log: lines.add,
    clock: clock,
  );

  bool logged(String step) => lines.any((l) => l.contains(' $step'));

  Future<void> dispose(WidgetTester tester) => tester.runAsync(() async {
    if (hookGate?.isCompleted == false) hookGate!.complete();
    await GravixPrejoin.debugEndAll();
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });
}

GravixTokenRequest req(String room) => GravixTokenRequest(room: room, identity: 'u1');

void main() {
  tearDown(GravixPrejoin.debugEndAll);

  group('defect 1: the attach timeout counts only foreground time', () {
    testWidgets('abandonInBackground false: Home for 60 s does not time out; the rest of the budget runs on resume', (
      tester,
    ) async {
      final rig = Rig();
      final h = rig.start(abandonInBackground: false, clock: () => tester.binding.clock.now());
      await tester.pump(const Duration(seconds: 10)); // the Go Live flow, in front
      expect(h.state, GravixPrejoinState.connected);
      background(tester); // Home
      expect(rig.logged('attachTimeoutPaused'), isTrue);
      await tester.pump(const Duration(seconds: 60));
      expect(h.state, GravixPrejoinState.connected, reason: 'the clock is paused while the app is away');
      expect(rig.calls, isNot(contains('hookStart')));
      foreground(tester);
      expect(rig.logged('attachTimeoutResumed'), isTrue);
      await tester.pump(const Duration(seconds: 9));
      expect(h.state, GravixPrejoinState.connected, reason: '10 s of the 20 s budget were left');
      await tester.pump(const Duration(seconds: 2));
      expect(await h.ended, GravixPrejoinEndReason.attachTimeout);
      expect(rig.calls.where((c) => c == 'hookStart'), hasLength(1));
      await rig.dispose(tester);
    });

    testWidgets('a screen that attaches after the return keeps the join (the device case)', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(req('live'), abandonInBackground: false);
      await tester.pump(const Duration(milliseconds: 300));
      background(tester);
      await tester.pump(const Duration(seconds: 28));
      foreground(tester);
      await tester.pump(const Duration(seconds: 1)); // the Go Live flow resumes
      final room = await rig.join.attach(req('live'));
      expect(room, same(h.room));
      expect(h.state, GravixPrejoinState.attached);
      expect(rig.calls, isNot(contains('hookStart')));
      expect(rig.logged('attachCold'), isFalse, reason: 'the same join, not a new one');
      await rig.dispose(tester);
    });

    testWidgets('started while the app is hidden: the clock starts paused', (tester) async {
      final rig = Rig();
      background(tester);
      final h = rig.start(abandonInBackground: false);
      await tester.pump(const Duration(seconds: 90));
      expect(h.state, GravixPrejoinState.connected);
      foreground(tester);
      await tester.pump(const Duration(seconds: 21));
      expect(await h.ended, GravixPrejoinEndReason.attachTimeout);
      await rig.dispose(tester);
    });

    testWidgets('inactive (a shade, a dialog) does not pause the clock', (tester) async {
      final rig = Rig();
      final h = rig.start(abandonInBackground: false);
      lifecycle(tester, const [AppLifecycleState.inactive]);
      await tester.pump(const Duration(seconds: 21));
      expect(await h.ended, GravixPrejoinEndReason.attachTimeout);
      expect(rig.logged('attachTimeoutPaused'), isFalse);
      lifecycle(tester, const [AppLifecycleState.resumed]);
      await rig.dispose(tester);
    });

    testWidgets('a screen that attaches while away ends the timeout: a resume does not restart it', (tester) async {
      final rig = Rig();
      final h = rig.start(abandonInBackground: false);
      await tester.pump(Duration.zero);
      background(tester);
      final room = await h.attach(leaveIfNeverShown: false);
      expect(room, isNotNull);
      foreground(tester);
      expect(rig.logged('attachTimeoutResumed'), isFalse);
      await tester.pump(const Duration(seconds: 60));
      expect(h.state, GravixPrejoinState.attached);
      await rig.dispose(tester);
    });

    testWidgets('per call: prepare(attachTimeout: null) never times out', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(req('a'), attachTimeout: null);
      await tester.pump(const Duration(seconds: 120));
      expect(h.state, GravixPrejoinState.connected);
      await rig.dispose(tester);
    });

    testWidgets('per call: prepare(attachTimeout: 5 s) overrides the constructor\'s 20 s', (tester) async {
      final rig = Rig();
      final h = rig.join.prepare(req('a'), attachTimeout: const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 4));
      expect(h.state, GravixPrejoinState.connected);
      await tester.pump(const Duration(seconds: 2));
      expect(await h.ended, GravixPrejoinEndReason.attachTimeout);
      await rig.dispose(tester);
    });

    testWidgets('per call: omitted keeps the constructor\'s; attach / attachResult / attachOrThrow take it', (
      tester,
    ) async {
      final rig = Rig();
      final h = rig.join.prepare(req('a'));
      expect(h.attachTimeout, GravixPrejoin.defaultAttachTimeout);
      expect(await rig.join.attach(req('b'), attachTimeout: null), isNotNull);
      expect((await rig.join.attachResult(req('c'), attachTimeout: const Duration(seconds: 3))).room, isNotNull);
      expect(await rig.join.attachOrThrow(req('d'), attachTimeout: null), isNotNull);
      expect(GravixPrejoin.pendingFor(GravixPrejoin.sessionKey(req('d')))!.attachTimeout, isNull);
      await rig.dispose(tester);
    });
  });

  group('defect 2: the signal leave goes first', () {
    testWidgets('abandon of a connected handle: room.disconnect() before the leave hook (slow hook)', (tester) async {
      final rig = Rig()..hookGate = Completer<void>();
      final h = rig.start();
      await tester.pump(Duration.zero);
      expect(h.state, GravixPrejoinState.connected);
      unawaited(h.abandon());
      // synchronously: the Leave is out before the hook even starts
      expect(rig.calls, ['connect', 'disconnect', 'hookStart']);
      expect(rig.logged('leaveSignalFirst'), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(rig.calls.last, 'hookStart', reason: 'the hook is still running');
      rig.hookGate!.complete();
      await tester.pump(Duration.zero);
      expect(rig.calls, ['connect', 'disconnect', 'hookStart', 'hookDone']);
      expect(rig.rooms.single.disconnects, 1);
      await rig.dispose(tester);
    });

    testWidgets('Back before the screen (background) of a connecting handle: signal first', (tester) async {
      final rig = Rig()..hookGate = Completer<void>();
      final hold = Completer<void>();
      final h = GravixPrejoin.start(
        key: 'k-connecting',
        target: () => const GravixJoinTarget(url: url, token: 't1'),
        createRoom: rig.newRoom,
        connect: (room, t) => hold.future,
        leave: rig.leaveHook,
        log: rig.lines.add,
      );
      await tester.pump(Duration.zero);
      expect(h.state, GravixPrejoinState.connecting);
      background(tester);
      expect(rig.calls, ['disconnect', 'hookStart']);
      expect(await h.ended, GravixPrejoinEndReason.background);
      hold.complete();
      foreground(tester);
      await rig.dispose(tester);
    });

    testWidgets('neverShown (attached, Home before its frame): signal first', (tester) async {
      final rig = Rig()..hookGate = Completer<void>();
      final h = rig.start();
      await tester.pump(Duration.zero);
      expect(await h.attach(), isNotNull);
      background(tester); // no frame of the screen yet
      expect(await h.ended, GravixPrejoinEndReason.neverShown);
      expect(rig.calls, ['connect', 'disconnect', 'hookStart']);
      foreground(tester);
      await rig.dispose(tester);
    });

    testWidgets('the real exit of a shown room (leave()) keeps the hook first: no signal-first', (tester) async {
      final rig = Rig();
      final h = rig.start();
      await tester.pump(Duration.zero);
      expect(await h.attach(), isNotNull);
      await tester.pump();
      await h.leave();
      expect(rig.calls, ['connect', 'hookStart', 'hookDone']);
      expect(rig.logged('leaveSignalFirst'), isFalse);
      await rig.dispose(tester);
    });

    testWidgets('detached: a handle allowed to survive the background ends, signal first, before any pump', (
      tester,
    ) async {
      final rig = Rig()..hookGate = Completer<void>();
      final h = rig.start(abandonInBackground: false);
      await tester.pump(Duration.zero);
      background(tester);
      expect(h.state, GravixPrejoinState.connected, reason: 'the background keeps it');
      detach(tester); // the engine is going away
      expect(rig.calls, ['connect', 'disconnect', 'hookStart']);
      expect(rig.logged('detached'), isTrue);
      expect(await h.ended, GravixPrejoinEndReason.background);
      foreground(tester);
      await rig.dispose(tester);
    });

    testWidgets('detached while the leave hook of a shown room runs: the signal leave goes at once', (tester) async {
      final rig = Rig()..hookGate = Completer<void>();
      final h = rig.start();
      await tester.pump(Duration.zero);
      expect(await h.attach(), isNotNull);
      await tester.pump(); // shown
      unawaited(h.leave());
      expect(rig.calls, ['connect', 'hookStart']);
      background(tester);
      expect(rig.calls, ['connect', 'hookStart']);
      detach(tester);
      expect(rig.calls, ['connect', 'hookStart', 'disconnect']);
      expect(rig.logged('leaveSignalFirst'), isTrue);
      rig.hookGate!.complete();
      await tester.pump(Duration.zero);
      foreground(tester);
      await rig.dispose(tester);
    });

    testWidgets('a dead Room (roomGone) gets no signal leave and no hook', (tester) async {
      final rig = Rig();
      final h = rig.start();
      await tester.pump(Duration.zero);
      await tester.runAsync(() => rig.rooms.single.dispose());
      await h.abandon();
      expect(await h.ended, GravixPrejoinEndReason.roomGone);
      expect(rig.calls, ['connect']);
      await rig.dispose(tester);
    });
  });

  group('a real Room (fake signal server)', () {
    setUp(fake.installRecoveryChannelMocks);

    int leaves(fake.FakeSignalServer s) => s.sockets.expand((w) => w.sent).where((r) => r.hasLeave()).length;

    test('disconnect twice (signal-first + the hook\'s own default leave) is harmless: one Leave', () async {
      final server = fake.FakeSignalServer();
      final room = await fake.connectedFakeRoom(server, fake.FakePcFactory());
      final first = room.disconnect();
      expect(leaves(server), 1, reason: 'the Leave is written synchronously');
      await GravixPrejoin.defaultLeave(room);
      await first;
      expect(leaves(server), 1);
      expect(room.isDisposed, isTrue);
    });

    test('two concurrent disconnects complete, one Leave', () async {
      final server = fake.FakeSignalServer();
      final room = await fake.connectedFakeRoom(server, fake.FakePcFactory());
      await Future.wait([room.disconnect(), room.disconnect()]);
      expect(leaves(server), 1);
      expect(room.connectionState, ConnectionState.disconnected);
      await room.dispose();
    });

    test('abandon of a connected handle: the Leave is on the wire before the slow hook runs', () async {
      final server = fake.FakeSignalServer();
      final room = await fake.connectedFakeRoom(server, fake.FakePcFactory());
      int? atHookEntry;
      final h = GravixPrejoin.start(
        key: 'k-real-sf',
        target: () => const GravixJoinTarget(url: 'wss://blr1.example', token: 't'),
        createRoom: () => room,
        connect: (r, t) async {},
        leave: (r) async {
          atHookEntry = leaves(server);
          await Future<void>.delayed(const Duration(milliseconds: 50)); // the app's slow cleanup
          await GravixPrejoin.defaultLeave(r);
        },
        abandonInBackground: false,
      );
      expect(await h.connected, isTrue);
      final done = h.abandon(GravixPrejoinEndReason.background);
      expect(leaves(server), 1, reason: 'sent within the abandon() call');
      await done;
      expect(atHookEntry, 1);
      expect(leaves(server), 1);
      expect(room.isDisposed, isTrue);
    });
    group('a leave before the app\'s connect hook connects never ends joined', () {
      test('abandon before the hook calls connect() (slow hook): no join at all, ended abandoned', () async {
        final server = fake.FakeSignalServer();
        final room = fake.fakeRoom(server, fake.FakePcFactory());
        final gate = Completer<void>();
        final events = <GravixJoinEventKind>[];
        final lines = <String>[];
        var hookLeaves = 0;
        final h = GravixPrejoin.start(
          key: 'k-late-1',
          target: () => const GravixJoinTarget(url: 'wss://blr1.example', token: 't'),
          createRoom: () => room,
          connect: (r, t) async {
            await gate.future; // the app's own work first (an audio session, a fetch)
            await r.connect(
              'wss://blr1.example',
              'tok',
              connectOptions: ConnectOptions(timeouts: fake.fastTimeouts(), joinRetries: 0),
            );
          },
          leave: (r) async => hookLeaves++,
          onEvent: (e) => events.add(e.kind),
          log: lines.add,
          abandonInBackground: false,
        );
        await fake.settle();
        expect(h.state, GravixPrejoinState.connecting);
        await h.abandon();
        gate.complete();
        await fake.settle(300);
        expect(await h.ended, GravixPrejoinEndReason.abandoned);
        expect(await h.connected, isFalse);
        expect(events, isNot(contains(GravixJoinEventKind.connected)));
        expect(room.connectionState, ConnectionState.disconnected);
        expect(leaves(server), lessThanOrEqualTo(1));
        expect(server.dials, isEmpty, reason: 'the abandoned Room does not dial at all');
        expect(hookLeaves, 1);
        await room.dispose();
      });

      test('a late connect that still joins (a reused Room) is left at once, signal first', () async {
        final server = fake.FakeSignalServer();
        final room = await fake.connectedFakeRoom(server, fake.FakePcFactory());
        await room.disconnect(); // an earlier session of this Room object
        final socketsBefore = server.sockets.length;
        final gate = Completer<void>();
        final events = <GravixJoinEventKind>[];
        final lines = <String>[];
        final h = GravixPrejoin.start(
          key: 'k-late-3',
          target: () => const GravixJoinTarget(url: 'wss://blr1.example', token: 't'),
          createRoom: () => room,
          connect: (r, t) async {
            await gate.future;
            await r.connect(
              'wss://blr1.example',
              'tok',
              connectOptions: ConnectOptions(timeouts: fake.fastTimeouts(), joinRetries: 0),
            );
          },
          leave: (r) async {},
          onEvent: (e) => events.add(e.kind),
          log: lines.add,
          abandonInBackground: false,
        );
        await fake.settle();
        await h.abandon();
        gate.complete();
        expect(
          await fake.eventually(() => lines.any((l) => l.contains(' leaveAfterLateConnect'))),
          isTrue,
          reason: lines.join('\n'),
        );
        expect(await fake.eventually(() => room.connectionState == ConnectionState.disconnected), isTrue);
        await fake.settle(100);
        expect(lines.where((l) => l.contains(' leaveAfterLateConnect')), hasLength(1));
        expect(server.sockets.length, socketsBefore + 1);
        expect(server.sockets.last.sent.where((r) => r.hasLeave()), hasLength(1));
        expect(await h.ended, GravixPrejoinEndReason.abandoned);
        expect(await h.connected, isFalse);
        expect(events, isNot(contains(GravixJoinEventKind.connected)));
        await room.dispose();
      });

      test('abandon while the connect is in flight: exactly one Leave, nothing ends connected', () async {
        final server = fake.FakeSignalServer();
        final room = fake.fakeRoom(server, fake.FakePcFactory());
        final dial = Completer<void>();
        server.onDial = (u) => dial.future; // the signal dial is slow
        final events = <GravixJoinEventKind>[];
        final lines = <String>[];
        final h = GravixPrejoin.start(
          key: 'k-late-2',
          target: () => const GravixJoinTarget(url: 'wss://blr1.example', token: 't'),
          createRoom: () => room,
          connect: (r, t) async {
            try {
              await r.connect(
                'wss://blr1.example',
                'tok',
                connectOptions: ConnectOptions(timeouts: fake.fastTimeouts(), joinRetries: 0),
              );
            } catch (_) {}
          },
          leave: (r) async {},
          onEvent: (e) => events.add(e.kind),
          log: lines.add,
          abandonInBackground: false,
        );
        expect(await fake.eventually(() => server.dials.isNotEmpty), isTrue);
        await h.abandon();
        dial.complete();
        await fake.settle(500);
        expect(await h.ended, GravixPrejoinEndReason.abandoned);
        expect(await h.connected, isFalse);
        expect(events, isNot(contains(GravixJoinEventKind.connected)));
        expect(
          await fake.eventually(() => room.connectionState == ConnectionState.disconnected),
          isTrue,
          reason: lines.join('\n'),
        );
        if (server.sockets.isNotEmpty) {
          expect(leaves(server), 1, reason: 'joined after the abandon: left once, at once');
        }
        await room.dispose();
      });
    });
  });
}

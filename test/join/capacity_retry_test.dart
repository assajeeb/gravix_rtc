// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.7.2: GravixJoin.retryCapacityRefusals. Field 2026-10-27 (an app on dac1): the
// owner's 160-user cap refused viewer joins with 403 "app user limit reached";
// the refusal was final and the viewer sat in a silent room. Opt-in: the join
// is tried again silently while the handle is alive; off = fails at once.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

import '../support/fake_rtc.dart' as fake;

String jwt(String room) {
  String part(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000;
  return [
    part({'alg': 'HS256'}),
    part({
      'sub': 'u1',
      'exp': exp,
      'video': {'room': room, 'roomJoin': true},
    }),
    'c2ln',
  ].join('.');
}

ConnectException capRefusal() =>
    ConnectException('app user limit reached', reason: ConnectionErrorReason.NotAllowed, statusCode: 403);

class Rig {
  Rig({required this.retry, required this.errors});

  final bool retry;

  /// Thrown by the first connects, in order; then the connect succeeds.
  final List<Object> errors;
  int connects = 0;
  final lines = <String>[];
  final rooms = <Room>[];

  late final join = GravixJoin(
    tokenProvider: GravixTokenProvider.callback(
      (r) async => {'token': jwt(r.room), 'url': 'wss://rtc.example.test'},
      reuse: GravixTokenReuse.fastJoin,
    ),
    standbyPool: GravixStandbyPool(
      opener: (u, t, rtt) async => true,
      stateOf: (u, t) => const GravixStandbyState('none'),
      inForeground: () => true,
      autoTick: false,
    ),
    bindStandbyLifecycle: false,
    retryCapacityRefusals: retry,
    createRoom: () {
      final r = Room();
      rooms.add(r);
      return r;
    },
    connect: (room, t) async {
      connects++;
      if (connects <= errors.length) throw errors[connects - 1];
    },
    leave: (room) async {},
    log: lines.add,
  );

  List<String> linesOf(String step) => lines.where((l) => l.startsWith('${GravixJoinLog.prefix} $step ')).toList();

  Future<void> dispose(WidgetTester tester) => tester.runAsync(() async {
    await GravixPrejoin.debugEndAll();
    for (final r in rooms) {
      if (!r.isDisposed) await r.dispose();
    }
  });
}

GravixTokenRequest req(String room) => GravixTokenRequest(room: room, identity: 'u1');

void main() {
  final savedBackoff = GravixPrejoin.capacityRetryBackoff;
  setUp(() => GravixPrejoin.capacityRetryBackoff = const [Duration(milliseconds: 10), Duration(milliseconds: 20)]);
  tearDown(() async {
    GravixPrejoin.capacityRetryBackoff = savedBackoff;
    await GravixPrejoin.debugEndAll();
  });

  test('isCapacityRefusal: only a 403 "app user limit reached"', () {
    expect(GravixPrejoin.isCapacityRefusal(capRefusal()), isTrue);
    expect(
      GravixPrejoin.isCapacityRefusal(
        ConnectException('app plan limit reached', reason: ConnectionErrorReason.NotAllowed, statusCode: 403),
      ),
      isFalse,
    );
    expect(
      GravixPrejoin.isCapacityRefusal(
        ConnectException('app user limit reached', reason: ConnectionErrorReason.InternalError, statusCode: 500),
      ),
      isFalse,
    );
    expect(GravixPrejoin.isCapacityRefusal(StateError('app user limit reached')), isFalse);
  });

  testWidgets('on: refused twice, then connected on the same Room; one capacityRetry line per wait', (tester) async {
    final rig = Rig(retry: true, errors: [capRefusal(), capRefusal()]);
    final room = await tester.runAsync(() => rig.join.prepare(req('r')).attach());
    expect(room, isNotNull);
    expect(rig.connects, 3);
    expect(rig.rooms, hasLength(1));
    expect(rig.linesOf('capacityRetry'), hasLength(2));
    expect(rig.linesOf('capacityRetryOk'), hasLength(1));
    expect(rig.linesOf('connectFail'), isEmpty);
    await rig.dispose(tester);
  });

  testWidgets('off (default): the first refusal fails the join', (tester) async {
    final rig = Rig(retry: false, errors: [capRefusal()]);
    final room = await tester.runAsync(() => rig.join.prepare(req('r')).attach());
    expect(room, isNull);
    expect(rig.connects, 1);
    expect(rig.linesOf('capacityRetry'), isEmpty);
    await rig.dispose(tester);
  });

  testWidgets('on: another error is not retried', (tester) async {
    final rig = Rig(retry: true, errors: [StateError('network')]);
    final room = await tester.runAsync(() => rig.join.prepare(req('r')).attach());
    expect(room, isNull);
    expect(rig.connects, 1);
    await rig.dispose(tester);
  });

  testWidgets('on: leaving while it waits stops the retries', (tester) async {
    final rig = Rig(retry: true, errors: List.generate(100, (_) => capRefusal()));
    await tester.runAsync(() async {
      final h = rig.join.prepare(req('r'));
      final attached = h.attach();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await h.abandon(GravixPrejoinEndReason.left);
      expect(await attached, isNull);
      final after = rig.connects;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.connects, after);
    });
    await rig.dispose(tester);
  });

  group('a real Room (fake signal server)', () {
    setUp(fake.installRecoveryChannelMocks);

    test('the same Room connects after two refused connects', () async {
      final server = fake.FakeSignalServer();
      var dials = 0;
      // the first two dials fail like a refused upgrade; the third is answered
      server.onDial = (uri) async {
        dials++;
        if (dials <= 2) throw StateError('refused upgrade');
      };
      final room = fake.fakeRoom(server, fake.FakePcFactory());
      final rig = GravixJoin(
        tokenProvider: GravixTokenProvider.callback(
          (r) async => {'token': jwt(r.room), 'url': 'wss://blr1.example'},
          reuse: GravixTokenReuse.fastJoin,
        ),
        standbyPool: GravixStandbyPool(
          opener: (u, t, rtt) async => true,
          stateOf: (u, t) => const GravixStandbyState('none'),
          inForeground: () => true,
          autoTick: false,
        ),
        bindStandbyLifecycle: false,
        retryCapacityRefusals: true,
        createRoom: () => room,
        connect: (r, t) async {
          try {
            await r.connect(
              t.url,
              t.token,
              connectOptions: ConnectOptions(timeouts: fake.fastTimeouts(), joinRetries: 0),
            );
          } catch (_) {
            // what the SDK reports for the SFU's 403 body
            throw capRefusal();
          }
        },
      );
      final attached = await rig.prepare(req('r')).attach();
      expect(identical(attached, room), isTrue);
      expect(dials, 3);
      expect(room.connectionState, ConnectionState.connected);
      await room.disconnect();
    });
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field test 2026-10-05: a second join for the same identity raced the first
// session's resume on another node, moved the room's origin and cost ~2.5 min of
// instability. GravixRoomService now runs one session per room + identity.
import 'dart:async';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const sgp = 'wss://rtc.example.com';

String jwt(String room, String identity, {int n = 0}) => JWT(<String, dynamic>{
  'sub': identity,
  'n': n, // a different token for the same grant
  'video': <String, dynamic>{'room': room, 'roomJoin': true},
}).sign(SecretKey('test-secret'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    for (final name in const [
      'com.ryanheise.audio_session',
      'com.ryanheise.android_audio_manager',
      'com.ryanheise.av_audio_session',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => switch (call.method) {
          'getDevices' => <dynamic>[],
          'getMode' => 0,
          'isBluetoothScoOn' => false,
          _ => null,
        },
      );
    }
  });

  test('session key: room + identity from the token; unreadable token -> no dedupe', () {
    expect(GravixRoomService.gravixSessionKey(jwt('r1', 'u1')), 'r1\u0000u1');
    expect(GravixRoomService.gravixSessionKey(jwt('r1', 'u1', n: 1)), 'r1\u0000u1');
    expect(GravixRoomService.gravixSessionKey('not-a-jwt'), isNull);
  });

  test('the same room/identity/token while a connect is in flight: one session, one result', () async {
    final gate = Completer<void>();
    var dials = 0;
    final service = GravixRoomService(
      connectRoom: (room, url, token) async {
        dials++;
        await gate.future;
        throw StateError('test: no server');
      },
    );
    final t = jwt('r1', 'u1');
    final a = service.connect(url: sgp, token: t);
    final b = service.connect(url: sgp, token: t); // a double tap / re-entry
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gate.complete();
    expect(await a, isFalse);
    expect(await b, isFalse);
    expect(dials, 1, reason: 'no second connect for the same room + identity');
  });

  test('another identity (or token) waits for the connect in flight, never runs beside it', () async {
    final gates = [Completer<void>(), Completer<void>()];
    final order = <String>[];
    var running = 0;
    var maxRunning = 0;
    final service = GravixRoomService(
      connectRoom: (room, url, token) async {
        final i = order.length;
        order.add(GravixRoomService.gravixSessionKey(token)!);
        running++;
        maxRunning = running > maxRunning ? running : maxRunning;
        try {
          await gates[i].future;
        } finally {
          running--;
        }
        throw StateError('test: no server');
      },
    );
    final a = service.connect(url: sgp, token: jwt('r1', 'u1'));
    final b = service.connect(url: sgp, token: jwt('r1', 'u1', n: 1)); // e.g. a refreshed token
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(order, hasLength(1), reason: 'the second waits');
    gates[0].complete();
    expect(await a, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gates[1].complete();
    expect(await b, isFalse);
    expect(order, hasLength(2));
    expect(maxRunning, 1);
  });

  test('connected or reconnecting with the same room/identity/token: the session is kept', () {
    final k = GravixRoomService.gravixSessionKey(jwt('r1', 'u1'));
    final t = jwt('r1', 'u1');
    bool keep(ConnectionState? s, {String? token, String? key}) =>
        GravixRoomService.gravixKeepSession(key: key ?? k, token: token ?? t, sessionKey: k, sessionToken: t, state: s);
    expect(keep(ConnectionState.connected), isTrue);
    expect(keep(ConnectionState.reconnecting), isTrue);
    expect(keep(ConnectionState.disconnected), isFalse);
    expect(keep(null), isFalse);
    // another token (reconnectWithToken: promotion / refresh) reconnects as before
    expect(keep(ConnectionState.connected, token: jwt('r1', 'u1', n: 2)), isFalse);
    expect(keep(ConnectionState.connected, key: 'r2\u0000u1'), isFalse);
  });
}

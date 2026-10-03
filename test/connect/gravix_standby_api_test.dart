// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.8: the standby pre-connect without a GravixRoomService. An app that drives
// `Room` itself created a throwaway GravixRoomService only to call
// `standby()`. `GravixStandby` (static) and `room.standby(url, token)` (JS SDK
// shape) open the same connection the service's standby() opens; Room.connect
// takes it for the same url + token (standby_test.dart covers the take).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  // GravixRoomService needs a binary messenger; the test binding also swaps in a
  // fake HttpClient, which this file must not have (real loopback server).
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late HttpServer http;
  late String url;
  var heads = 0;

  setUp(() async {
    heads = 0;
    http = await HttpServer.bind('127.0.0.1', 0);
    http.listen((req) async {
      if (req.method == 'HEAD') heads++;
      req.response.statusCode = 404;
      await req.response.close();
    });
    url = 'ws://127.0.0.1:${http.port}';
  });

  tearDown(() async {
    await GravixStandby.closeAll();
    await http.close(force: true);
  });

  test('GravixStandby.open: opens, state is open, idempotent while fresh', () async {
    expect(GravixStandby.state(url, 't1').state, 'none');
    expect(await GravixStandby.open(url, 't1'), isTrue);
    expect(GravixStandby.state(url, 't1').state, 'open');
    expect(await GravixStandby.open(url, 't1'), isTrue);
    expect(heads, 1, reason: 'a fresh standby is reused, not re-opened');
  });

  test('keyed by url + token: another token has none', () async {
    expect(await GravixStandby.open(url, 't1'), isTrue);
    expect(GravixStandby.state(url, 't2').state, 'none');
  });

  test('closeAll: nothing open afterwards', () async {
    expect(await GravixStandby.open(url, 't1'), isTrue);
    await GravixStandby.closeAll();
    expect(GravixStandby.state(url, 't1').state, isNot('open'));
  });

  test('reopenAll: open again afterwards', () async {
    expect(await GravixStandby.open(url, 't1'), isTrue);
    await GravixStandby.reopenAll();
    expect(GravixStandby.state(url, 't1').state, 'open');
  });

  test('nothing listening: false, never throws', () async {
    final s = await ServerSocket.bind('127.0.0.1', 0);
    final dead = 'ws://127.0.0.1:${s.port}';
    await s.close();
    expect(await GravixStandby.open(dead, 't1'), isFalse);
  });

  test('room.standby(url, token): the same standby, no service needed', () async {
    final room = Room();
    expect(await room.standby(url, 't3'), isTrue);
    expect(GravixStandby.state(url, 't3').state, 'open');
    expect(room.standbyState(url, 't3').state, 'open');
    await room.dispose();
  });

  test('GravixRoomService.standby is the same connection (delegates)', () async {
    expect(await GravixRoomService().standby(url, 't4'), isTrue);
    expect(GravixStandby.state(url, 't4').state, 'open');
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// S2, field 2026-10-09 (Pakhi): the app's server chip showed blr1 while the
// whole session ran on doh1. The chip read the url the app PASSED to
// Room.connect; the SDK had failed over to another region. Room.connectedUrl /
// connectedRegion now say where the session really is, and
// RoomConnectedUrlChangedEvent fires when that changes (first connect, region
// failover, a full rejoin to another region). A resume keeps the url.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart' show ConnectionState;

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    gravixClearRegionMeasurement();
  });

  late FakeSignalServer server;
  late FakePcFactory pcs;
  Room? room;
  tearDown(() async => room?.dispose());

  test('after the connect: the url the session is on, the region the server named, one event', () async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    final changes = <RoomConnectedUrlChangedEvent>[];
    room = await connectedFakeRoom(server, pcs, url: 'wss://blr1.example', serverRegion: 'blr1');
    // (listening after the connect: the event is also kept as the last one)
    expect(room!.connectedUrl, 'wss://blr1.example');
    expect(room!.connectedRegion, 'blr1');
    room!.events.on<RoomConnectedUrlChangedEvent>(changes.add);
    // a resume keeps the url: no event
    await room!.engine.handleReconnect(ClientDisconnectReason.signal);
    await settle(200);
    expect(changes, isEmpty);
    expect(room!.connectedUrl, 'wss://blr1.example');
  });

  test('a full rejoin that lands on another region moves connectedUrl and emits the change', () async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs, url: 'wss://blr1.example');
    final changes = <RoomConnectedUrlChangedEvent>[];
    room!.events.on<RoomConnectedUrlChangedEvent>(changes.add);
    autoConnectPcs(pcs);
    await room!.engine.restartConnection(regionUrl: 'wss://doh1.example');
    expect(await eventually(() => changes.isNotEmpty), isTrue);
    expect(room!.connectedUrl, 'wss://doh1.example');
    expect(changes.single.url, 'wss://doh1.example');
    expect(changes.single.previousUrl, 'wss://blr1.example');
    expect(changes.single.reason, RoomConnectedUrlChangeReason.rejoin);
  });

  test('connectedRegion from the start-up measurement when the server names none', () async {
    await gravixMeasureRegions(
      regionUrls: const [
        GravixRegionUrl(region: 'blr1', url: 'wss://blr1.example'),
        GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example'),
      ],
      sampler: (r) async => Duration(milliseconds: r.region == 'blr1' ? 80 : 260),
    );
    server = FakeSignalServer();
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs, url: 'wss://doh1.example/');
    expect(room!.connectedUrl, 'wss://doh1.example/');
    expect(room!.connectedRegion, 'doh1');
  });

  test('disconnected: no url', () async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs);
    await room!.disconnect();
    expect(room!.connectedUrl, isNull);
    expect(room!.connectedRegion, isNull);
  });

  // OBS-1 (REAL iPhone 2026-10-11, dev/d2_app.log: url=null for 35 s across a
  // resume, a second resume and a full reconnect): the signal client's cleanUp
  // sets `disconnected` for the whole resume dial, and the getter read that as
  // "not connected" -- against its own contract ("kept through a resume and
  // while reconnecting"). An app's server chip went blank on every network blip.
  test('OBS-1: the url and region stay while a resume dials (the signal client reads disconnected then)', () async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs, url: 'wss://blr1.example', serverRegion: 'blr1');
    final dial = Completer<void>();
    server.onDial = (u) async {
      if (u.queryParameters['reconnect'] == '1' && !dial.isCompleted) await dial.future;
    };
    await server.last.serverClose(); // the socket dies: a resume starts and its dial hangs
    final seen = <String>{};
    var sawDisconnectedSignal = false;
    for (var i = 0; i < 15; i++) {
      await settle(20);
      if (room!.engine.connectionState == ConnectionState.disconnected) sawDisconnectedSignal = true;
      seen.add('${room!.connectedUrl}|${room!.connectedRegion}');
    }
    expect(sawDisconnectedSignal, isTrue, reason: 'the case under test: the signal reads disconnected mid-resume');
    expect(seen, {'wss://blr1.example|blr1'});
    dial.complete();
    expect(await eventually(() => room!.engine.connectionState == ConnectionState.connected), isTrue);
    expect(room!.connectedUrl, 'wss://blr1.example');
  });

  test('OBS-1 guard: a session that ends after its reconnect gave up reads no url', () async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    room = await connectedFakeRoom(server, pcs, url: 'wss://blr1.example', serverRegion: 'blr1');
    server.onDial = (u) async => throw Exception('no route');
    server.joinResponse = null;
    await server.last.serverClose();
    expect(await eventually(() => room!.connectedUrl == null, timeout: const Duration(seconds: 20)), isTrue);
    expect(room!.connectedRegion, isNull);
  });
}

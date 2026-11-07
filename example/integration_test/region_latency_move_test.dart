// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// On-device proof for the 0.9.0 listener latency move (field 2026-11-08: a Doha
// viewer of a Dhaka room sat on dac1 at ~320 ms because nothing was measured at
// join time).
//
// The listener joins through a FAR region (GX_URL, e.g. wss://nyc1...) with
// homeRegion = that region and no measurement running, so the join dials it.
// Then the start-up measurement starts; its held region (the near one) must make
// the room move there once, by itself, without the app doing anything.
//
//   flutter test integration_test/region_latency_move_test.dart -d <device> \
//     --dart-define-from-file=<dir-outside-the-repo>/defines.json
//   # GX_URL, GX_TOKEN (listener, canPublish false), GX_HOME (region of GX_URL),
//   # GX_EXPECT (region the move must land on), GX_REGIONS_URL (console /v1/regions)
//
// Without GX_TOKEN the test is skipped. Every step prints `LATMOVE ...`.
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

const _url = String.fromEnvironment('GX_URL');
const _token = String.fromEnvironment('GX_TOKEN');
const _home = String.fromEnvironment('GX_HOME');
const _expect = String.fromEnvironment('GX_EXPECT');
const _regionsUrl = String.fromEnvironment('GX_REGIONS_URL');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a listener on a far region is moved to the near one once', (tester) async {
    if (_token.isEmpty) {
      markTestSkipped('GX_TOKEN not set');
      return;
    }
    final t0 = DateTime.now();
    void log(String s) => debugPrint('LATMOVE +${DateTime.now().difference(t0).inMilliseconds}ms $s');

    final svc = GravixRoomService();
    final ok = await svc.connect(url: _url, token: _token, homeRegion: _home, media: GravixRoomMedia.audio);
    expect(ok, isTrue, reason: 'join failed');
    final room = svc.room!;
    final first = room.connectedRegion;
    log('joined region=$first url=${room.connectedUrl}');
    expect(first, _home, reason: 'with nothing measured the join must dial the token url');

    final handle = gravixStartRegionMeasurement(regionsUrl: _regionsUrl);
    final m = await handle.ready;
    log('measured best=${m.best?.region} rtt=${m.best?.rttMs} '
        'all=${m.regions.map((r) => '${r.region}:${r.ok ? r.rttMs : 'x'}').join(',')}');

    String? region = room.connectedRegion;
    for (var i = 0; i < 120 && region != _expect; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final now = room.connectedRegion;
      if (now != region) log('region $region -> $now');
      region = now;
    }
    log('final region=$region state=${room.connectionState}');
    expect(region, _expect, reason: 'latency move did not land');

    // fixed for the session: no move back within the next 30 s
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(room.connectedRegion, _expect, reason: 'moved again');
    }
    log('stayed on $_expect for 30 s');

    handle.stop();
    await svc.disconnect();
  });

  testWidgets('a join right after the measurement starts waits for it and dials the near region', (tester) async {
    if (_token.isEmpty) {
      markTestSkipped('GX_TOKEN not set');
      return;
    }
    final t0 = DateTime.now();
    void log(String s) => debugPrint('LATWAIT +${DateTime.now().difference(t0).inMilliseconds}ms $s');
    final handle = gravixStartRegionMeasurement(regionsUrl: _regionsUrl);
    final svc = GravixRoomService();
    final ok = await svc.connect(url: _url, token: _token, homeRegion: _home, media: GravixRoomMedia.audio);
    expect(ok, isTrue, reason: 'join failed');
    final region = svc.room!.connectedRegion;
    log('joined region=$region');
    expect(region, _expect, reason: 'the join should have waited for the measurement');
    handle.stop();
    await svc.disconnect();
  });
}

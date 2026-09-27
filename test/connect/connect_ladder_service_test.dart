// Copyright Gravity Compile, Inc. Apache 2.0.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const sgp = 'wss://rtc.example.com';
const blr = 'wss://rtc-blr1.example.com';
const fra = 'wss://rtc-fra1.example.com';

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

  // blr answers the probe first, so it is the race winner in every test below.
  GravixRegionProber blrWins() => GravixRegionProber(
    probe: (url) async {
      if (url != blr) await Future<void>.delayed(const Duration(milliseconds: 40));
    },
  );

  // GravixRoomService.connect() through the REAL ladder wiring: the seam replaces
  // only the step where a url becomes a connection.
  test('every url is tried once, in ladder order, and total failure is reported ONCE', () async {
    final tried = <String>[];
    var disconnectedCalls = 0;
    final service = GravixRoomService(
      regionProber: blrWins(),
      connectRoom: (room, url, token) async {
        tried.add(url);
        throw StateError('ws refused: $url');
      },
    )..onDisconnected = () => disconnectedCalls++;

    final ok = await service.connect(url: sgp, token: 'jwt', regionProbe: true, regionUrls: const [sgp, blr, fra]);

    expect(ok, isFalse);
    expect(tried, [blr, fra, sgp], reason: 'winner, then the other candidate, then the pinned url');
    expect(service.isConnected.value, isFalse);
    // Not zero (the app must learn the join failed) and not three (it must not be
    // told "disconnected" once per region while the ladder was still going).
    expect(disconnectedCalls, 1);
  });

  test('with no ladder, a failed connect behaves exactly as before: one attempt', () async {
    final tried = <String>[];
    final service = GravixRoomService(
      connectRoom: (room, url, token) async {
        tried.add(url);
        throw StateError('down');
      },
    );
    expect(await service.connect(url: sgp, token: 'jwt'), isFalse);
    expect(tried, [sgp]);
  });

  test('a refused token stops the ladder at the first url', () async {
    final tried = <String>[];
    final service = GravixRoomService(
      regionProber: blrWins(),
      connectRoom: (room, url, token) async {
        tried.add(url);
        throw ConnectException('no', reason: ConnectionErrorReason.NotAllowed, statusCode: 401);
      },
    );
    expect(
      await service.connect(url: sgp, token: 'jwt', regionProbe: true, regionUrls: const [sgp, blr, fra]),
      isFalse,
    );
    expect(tried, [blr]);
  });

  test('the connection report names the url the ladder actually reached', () async {
    final tried = <String>[];
    final service = GravixRoomService(
      regionProber: blrWins(),
      connectRoom: (room, url, token) async {
        tried.add(url);
        // blr (the winner) refuses; fra then fails differently so connect() stops
        // after it has recorded where it got to.
        throw StateError('refused $url');
      },
    );
    await service.connect(url: sgp, token: 'jwt', regionProbe: true, regionUrls: const [sgp, blr, fra]);
    expect(tried.first, blr);
    expect(service.lastConnectionReport!.winningRegionUrl, blr, reason: 'the race result is not rewritten');
  });

  // regionDecisionCache (JS parity, 2026-09-19). The race costs a join up to the
  // probe timeout; a user's best region does not change between two joins a
  // minute apart, so a repeat join goes straight to it.
  group('region decision cache', () {
    late GravixRegionDecisionCache cache;
    late List<String> raced;
    late List<Stopwatch> raceStarted;
    setUp(() {
      cache = GravixRegionDecisionCache();
      raced = [];
      raceStarted = [];
      // These joins SUCCEED, which walks into flutter_webrtc's platform channel
      // (device enumeration for audio routing). There is no plugin in a unit test.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
      );
    });

    // blr answers first; every race takes ~150ms. Each race's start is recorded
    // (its first probe), so a join can be timed against the race it did or did
    // not wait for.
    GravixRegionProber slowRace() => GravixRegionProber(
      probe: (url) async {
        if (raced.length % 3 == 0) raceStarted.add(Stopwatch()..start());
        raced.add(url);
        await Future<void>.delayed(Duration(milliseconds: url == blr ? 150 : 190));
      },
    );

    // Default ON since 2026-09-19 (JS parity; measured to remove the probe's
    // round trips from repeat joins). `false` is the one-flag rollback.
    test('is on by default: a join is remembered without asking', () async {
      final service = GravixRoomService(
        regionProber: slowRace(),
        regionDecisionCache: cache,
        connectRoom: (_, _, _) async {},
      );
      await service.connect(url: sgp, token: 'jwt', regionProbe: true, regionUrls: const [sgp, blr, fra]);
      expect(cache.read(sgp, const [sgp, blr, fra])?.url, blr);
    });

    test('regionDecisionCache: false turns it off: nothing is remembered', () async {
      final service = GravixRoomService(
        regionProber: slowRace(),
        regionDecisionCache: cache,
        connectRoom: (_, _, _) async {},
      );
      await service.connect(
        url: sgp,
        token: 'jwt',
        regionProbe: true,
        regionDecisionCache: false,
        regionUrls: const [sgp, blr, fra],
      );
      expect(cache.read(sgp, const [sgp, blr, fra]), isNull);
    });

    test('a repeat join connects at once to the remembered region and reports "cached"', () async {
      final tried = <String>[];
      final joinAfterRaceStart = <Duration>[];
      final service = GravixRoomService(
        regionProber: slowRace(),
        regionDecisionCache: cache,
        connectRoom: (room, url, token) async {
          tried.add(url);
          joinAfterRaceStart.add(raceStarted.last.elapsed);
        },
      );

      await service.connect(
        url: sgp,
        token: 'jwt',
        regionProbe: true,
        regionDecisionCache: true,
        regionUrls: const [sgp, blr, fra],
      );
      expect(tried, [blr]);
      expect(cache.read(sgp, const [sgp, blr, fra])?.url, blr);

      await service.connect(
        url: sgp,
        token: 'jwt',
        regionProbe: true,
        regionDecisionCache: true,
        regionUrls: const [sgp, blr, fra],
      );
      expect(tried, [blr, blr]);
      expect(
        joinAfterRaceStart.first,
        greaterThanOrEqualTo(const Duration(milliseconds: 150)),
        reason: 'the first join waits for its race',
      );
      expect(raceStarted, hasLength(2), reason: 'the second join still races, in the background');
      expect(joinAfterRaceStart.last, lessThan(const Duration(milliseconds: 100)), reason: 'but does not wait for it');
      expect(service.regionReport.value?.reason, GravixRegionChoiceReason.cached);
      expect(service.regionReport.value?.probes, isEmpty);
    });

    test('a remembered region that refuses is forgotten, and the ladder still lands the join', () async {
      cache.recordLanded(sgp, url: blr, region: 'blr1');
      final tried = <String>[];
      final service = GravixRoomService(
        regionProber: slowRace(),
        regionDecisionCache: cache,
        connectRoom: (room, url, token) async {
          tried.add(url);
          if (url == blr) throw StateError('ws refused: $url');
        },
      );

      await service.connect(
        url: sgp,
        token: 'jwt',
        regionProbe: true,
        regionDecisionCache: true,
        regionUrls: const [sgp, blr, fra],
      );
      expect(tried, [blr, fra], reason: 'the remembered region, then the next candidate in gateway order');
      expect(cache.read(sgp, const [sgp, blr, fra])?.url, fra, reason: 'where the join landed');

      // The background race still sees blr answer its probe first. The penalty
      // keeps it from going straight back into the memory.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(cache.read(sgp, const [sgp, blr, fra])?.url, isNot(blr));
    });
  });
}

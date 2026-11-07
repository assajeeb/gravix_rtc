// 0.9.0: a join waits (bounded) for the start-up region measurement, then falls back to the
// gateway's est_rtt_ms (2026-11-08).
//
// Field, Tuki app: a viewer in Doha joining a room whose home is dac1 (Dhaka) landed on dac1 at
// ~320 ms instead of doh1 (~20 ms). The app had called gravixStartRegionMeasurement at start, but
// the join did not wait for that run, and with nothing measured the token's url (= home = dac1)
// stayed.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/backend/gravix_token_provider.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_join_wait.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';
import 'package:gravix_rtc/src/join/gravix_join.dart';
import 'package:gravix_rtc/src/join/gravix_join_url.dart';
import 'package:gravix_rtc/src/join/gravix_prejoin.dart';
import 'package:gravix_rtc/src/join/gravix_standby_pool.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';

const doh = GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example.test');
const blr = GravixRegionUrl(region: 'blr1', url: 'wss://blr1.example.test');
const dac = GravixRegionUrl(region: 'dac1', url: 'wss://dac1.example.test');

Future<String?> _wifi() async => 'wifi';

GravixJoinCredentials viewer({String url = 'wss://dac1.example.test', String? home = 'dac1'}) =>
    GravixJoinCredentials(token: 't', url: url, homeRegion: home, fetchedAt: DateTime(2026));

/// The console's answer from Doha: doh1 first, est_rtt_ms per region.
GravixRegionDirectory dohaDirectory({double ttlS = 600, bool dohAudioOnly = false}) => GravixRegionDirectory.fromJson({
  'regions': [
    {
      'region': 'doh1',
      'url': doh.url,
      'est_rtt_ms': 20,
      if (dohAudioOnly) 'media': ['audio'],
    },
    {'region': 'blr1', 'url': blr.url, 'est_rtt_ms': 150},
    {'region': 'dac1', 'url': dac.url, 'est_rtt_ms': 320},
  ],
  'shortlist': ['doh1', 'blr1', 'dac1'],
  'shortlist_ttl_s': ttlS,
});

void main() {
  final lines = <String>[];
  GravixRegionMeasurementHandle? handle;

  setUp(() {
    gravixClearRegionMeasurement();
    lines.clear();
    GravixRegionLog.sink = lines.add;
  });
  tearDown(() {
    handle?.stop();
    handle = null;
    GravixRegionLog.sink = null;
  });

  String log() => lines.join('\n');
  String? pickLine() => lines.where((l) => l.startsWith('[GravixRegion] pick join')).lastOrNull;

  /// A handle whose samples wait for [gate] (null: answer at once) and answer [ms].
  GravixRegionMeasurementHandle start({
    Map<String, int> ms = const {'doh1': 20, 'blr1': 150, 'dac1': 320},
    Completer<void>? gate,
    double ttlS = 600,
    bool failDirectory = false,
    void Function()? onFetch,
  }) => handle = gravixStartRegionMeasurement(
    regionsUrl: 'https://console.example.test/v1/regions',
    fetchDirectory: (_) async {
      onFetch?.call();
      if (failDirectory) throw StateError('gateway down (test)');
      return dohaDirectory(ttlS: ttlS);
    },
    sampler: (r) async {
      if (gate != null) await gate.future;
      final v = ms[r.region];
      return v == null ? null : Duration(milliseconds: v);
    },
    store: GravixMemoryRegionListStore(),
    watchNetwork: false,
    refresh: Duration.zero,
    budget: const Duration(seconds: 5),
    networkType: _wifi,
    networkKey: _wifi,
  );

  group('the wait', () {
    test('no handle registered: no wait, the token url as before', () async {
      final watch = Stopwatch()..start();
      final c = await gravixJoinUrlAsync(viewer(), wait: const Duration(seconds: 2));
      expect(watch.elapsedMilliseconds, lessThan(200));
      expect(c.source, GravixJoinUrlSource.token);
      expect(c.url, dac.url);
      expect(gravixActiveRegionMeasurement(), isNull);
    });

    test('a start-up run in flight is waited for, and the join goes to the measured region', () async {
      final gate = Completer<void>();
      start(gate: gate);
      Timer(const Duration(milliseconds: 100), gate.complete);
      final c = await gravixJoinUrlAsync(viewer(), wait: const Duration(seconds: 2));
      expect(c.region, 'doh1', reason: log());
      expect(c.source, GravixJoinUrlSource.measured);
      expect(pickLine(), contains('waited='), reason: log());
      expect(pickLine(), contains('cause=no-measurement'), reason: log());
    });

    test('the wait is bounded: past it, the directory est_rtt_ms decides (home dac1 too far: doh1)', () async {
      final gate = Completer<void>(); // the samples never answer within the bound
      start(gate: gate);
      final watch = Stopwatch()..start();
      final c = await gravixJoinUrlAsync(viewer(), wait: const Duration(milliseconds: 150));
      expect(watch.elapsedMilliseconds, lessThan(1000));
      expect(c.region, 'doh1', reason: log());
      expect(c.source, GravixJoinUrlSource.est);
      expect(pickLine(), contains('est-fallback'), reason: log());
      gate.complete();
    });

    test('est fallback: a viewer whose home is blr1 (est 150 vs doh1 20) goes to doh1', () async {
      final gate = Completer<void>();
      start(gate: gate);
      final c = await gravixJoinUrlAsync(
        viewer(url: blr.url, home: 'blr1'),
        wait: const Duration(milliseconds: 100),
      );
      // blr1 est 150 vs doh1 est 20: far outside the margin -> doh1
      expect(c.region, 'doh1', reason: log());
      gate.complete();
    });

    test('est fallback respects the media filter (a video join skips an audio-only doh1)', () async {
      final gate = Completer<void>();
      handle = gravixStartRegionMeasurement(
        regionsUrl: 'https://console.example.test/v1/regions',
        fetchDirectory: (_) async => dohaDirectory(dohAudioOnly: true),
        sampler: (r) async {
          await gate.future;
          return null;
        },
        store: GravixMemoryRegionListStore(),
        watchNetwork: false,
        refresh: Duration.zero,
        networkType: _wifi,
        networkKey: _wifi,
      );
      final c = await gravixJoinUrlAsync(
        viewer(),
        media: GravixRoomMedia.video,
        wait: const Duration(milliseconds: 100),
      );
      expect(c.region, 'blr1', reason: log());
      gate.complete();
    });

    test('a token url outside the fleet is never redirected by the estimate', () async {
      final gate = Completer<void>();
      start(gate: gate);
      final c = await gravixJoinUrlAsync(
        viewer(url: 'wss://app-own-server.example.test'),
        wait: const Duration(milliseconds: 100),
      );
      expect(c.source, GravixJoinUrlSource.token);
      expect(c.url, 'wss://app-own-server.example.test');
      gate.complete();
    });

    test('a host (no home region) keeps the token url with nothing measured', () async {
      final gate = Completer<void>();
      start(gate: gate);
      final c = await gravixJoinUrlAsync(viewer(home: null), wait: const Duration(milliseconds: 100));
      expect(c.source, GravixJoinUrlSource.token);
      expect(c.url, dac.url);
      gate.complete();
    });

    test('a fresh measurement: no wait, no refresh', () async {
      var fetches = 0;
      await start(onFetch: () => fetches++).ready;
      expect(fetches, 1);
      final watch = Stopwatch()..start();
      final c = await gravixJoinUrlAsync(viewer(), wait: const Duration(seconds: 2));
      expect(watch.elapsedMilliseconds, lessThan(200));
      expect(c.region, 'doh1');
      expect(fetches, 1);
    });

    test('a stale measurement with nothing in flight: a refresh is kicked and waited for', () async {
      var fetches = 0;
      // shortlist_ttl_s 1 ms: stale at once
      await start(ttlS: 0.001, onFetch: () => fetches++).ready;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final w = await gravixAwaitRegionForJoin(bound: const Duration(seconds: 2), refreshMinAge: Duration.zero);
      expect(fetches, 2, reason: 'the join kicked a refresh');
      expect(w.before, 'stale');
      expect(w.kicked, isTrue);
    });

    test('a failed run moments ago is not re-run by every join (no probe storm)', () async {
      var fetches = 0;
      await start(failDirectory: true, onFetch: () => fetches++).ready;
      final watch = Stopwatch()..start();
      final c = await gravixJoinUrlAsync(viewer(), wait: const Duration(seconds: 2));
      expect(watch.elapsedMilliseconds, lessThan(200));
      expect(fetches, 1);
      expect(c.source, GravixJoinUrlSource.token);
      expect(pickLine(), contains('refresh-skipped'), reason: log());
    });

    test('the wait never throws, whatever the run does', () async {
      start(failDirectory: true);
      final c = await gravixJoinUrlAsync(viewer(), wait: const Duration(milliseconds: 300));
      expect(c.url, dac.url);
    });

    test('a stopped handle is unregistered: no wait', () async {
      start(gate: Completer<void>()).stop();
      expect(gravixActiveRegionMeasurement(), isNull);
    });

    test('gravixClearRegionMeasurement drops the registry (test isolation)', () async {
      start(gate: Completer<void>());
      expect(gravixActiveRegionMeasurement(), isNotNull);
      gravixClearRegionMeasurement();
      expect(gravixActiveRegionMeasurement(), isNull);
    });
  });

  group('a refresh after a join that landed unmeasured', () {
    test('kicked when the last run is older than the floor, not when it is recent', () async {
      var fetches = 0;
      await start(onFetch: () => fetches++).ready;
      expect(gravixRefreshAfterJoin(GravixJoinUrlSource.token), isFalse, reason: 'the last run is seconds old');
      expect(fetches, 1);
      expect(
        gravixRefreshAfterJoin(GravixJoinUrlSource.token, now: DateTime.now().add(const Duration(seconds: 31))),
        isTrue,
      );
      await handle!.inFlight;
      expect(fetches, 2);
      expect(lines.any((l) => l.contains('refresh cause=join-source=token')), isTrue, reason: log());
    });

    test('a measured join kicks nothing', () async {
      await start().ready;
      expect(
        gravixRefreshAfterJoin(GravixJoinUrlSource.measured, now: DateTime.now().add(const Duration(minutes: 1))),
        isFalse,
      );
    });

    test('no handle: nothing', () {
      expect(gravixRefreshAfterJoin(GravixJoinUrlSource.token), isFalse);
    });
  });

  group('GravixJoin', () {
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

    tearDown(GravixPrejoin.debugEndAll);

    test('the tap waits for the start-up run; the room gets the home region', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final gate = Completer<void>();
      start(gate: gate);
      final dialled = <String>[];
      final rooms = <Room>[];
      final join = GravixJoin(
        tokenProvider: GravixTokenProvider.callback(
          (r) async => {'token': jwt(r.room), 'url': dac.url, 'home_region': 'dac1'},
        ),
        standbyPool: GravixStandbyPool(opener: (u, t, rtt) async => true, inForeground: () => true, autoTick: false),
        bindStandbyLifecycle: false,
        createRoom: () {
          final r = Room();
          rooms.add(r);
          return r;
        },
        connect: (room, t) async => dialled.add(t.url),
        leave: (room) async {},
        regionWait: const Duration(seconds: 2),
      );
      Timer(const Duration(milliseconds: 100), gate.complete);
      final h = join.prepare(const GravixTokenRequest(room: 'r1', identity: 'u1'));
      expect(await h.connected, isTrue);
      expect(dialled, [doh.url], reason: log());
      expect(rooms.single.gravixHomeRegion, 'dac1');
      for (final r in rooms) {
        await r.dispose();
      }
    });
  });

  group('completed runs are announced', () {
    test('gravixRegionMeasurementRuns carries each finished run', () async {
      final seen = <String?>[];
      final sub = gravixRegionMeasurementRuns.listen((r) => seen.add(r.best?.region));
      await start().ready;
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['doh1']);
      await sub.cancel();
    });
  });
}

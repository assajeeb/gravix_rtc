// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join: which url a join dials (moved from the apps). A lookup on the
// start-up region measurement, never a probe on the tap path:
//  - a viewer whose token names the room's home region joins it when it measures
//    within max(25 ms, 30 %) of the fastest (field 2026-10-04: a viewer joined
//    another region than its host a few ms away and the relay leg lost 2.9-3.4 %);
//  - everyone else joins the measured region (the token's url is not an anchor);
//  - a url outside the measured fleet is never redirected;
//  - a standby already open in another of the token's regions wins over a re-pick
//    between warm-up and tap (the measurement flipped between the two and the join
//    paid a cold WebSocket), but never over the home-region pick.
// And the region standby targets the measured best region, never the last token's.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
// ignore: implementation_imports
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart' show gravixClearRegionMeasurement;

const sgp = GravixRegionUrl(region: 'sgp1', url: 'wss://sgp1.example.test');
const blr = GravixRegionUrl(region: 'blr1', url: 'wss://blr1.example.test');
const fra = GravixRegionUrl(region: 'fra1', url: 'wss://fra1.example.test');

GravixJoinCredentials creds({required String url, String? home, bool regions = true}) => GravixJoinCredentials(
  token: 'a.b.c',
  url: url,
  regionEntries: regions ? const [blr, sgp, fra] : const [],
  homeRegion: home,
  fetchedAt: DateTime(2026, 10, 15),
);

Future<void> measured(Map<String, int> ms) async {
  final seen = <String>{};
  await gravixMeasureRegions(
    regionUrls: const [sgp, blr, fra],
    sampler: (r) async => Duration(milliseconds: ms[r.region]! + (seen.add(r.region) ? 300 : 0)),
    networkType: () async => 'wifi',
  );
}

void main() {
  setUp(gravixClearRegionMeasurement);

  group('gravixJoinUrl', () {
    test('host: the measured region, not the token url', () async {
      await measured({'sgp1': 56, 'blr1': 58, 'fra1': 186});
      final c = gravixJoinUrl(creds(url: blr.url));
      expect(c.region, 'sgp1');
      expect(c.url, sgp.url);
      expect(c.source, GravixJoinUrlSource.measured);
      expect(c.rttMs, isNotNull);
    });

    test('viewer: the home region within the margin', () async {
      await measured({'sgp1': 56, 'blr1': 70, 'fra1': 186});
      final c = gravixJoinUrl(creds(url: blr.url, home: 'blr1'));
      expect(c.region, 'blr1');
      expect(c.source, GravixJoinUrlSource.home);
      expect(c.homeRegion, 'blr1');
    });

    test('viewer: a far home region is not joined', () async {
      await measured({'sgp1': 56, 'blr1': 70, 'fra1': 186});
      final c = gravixJoinUrl(creds(url: fra.url, home: 'fra1'));
      expect(c.region, 'sgp1');
      expect(c.source, GravixJoinUrlSource.measured);
    });

    test('a url outside the measured fleet is never redirected', () async {
      await measured({'sgp1': 56, 'blr1': 70, 'fra1': 186});
      final c = gravixJoinUrl(creds(url: 'wss://other.example.test', regions: false));
      expect(c.url, 'wss://other.example.test');
      expect(c.source, GravixJoinUrlSource.token);
    });

    test('no measurement yet: the token url', () {
      final c = gravixJoinUrl(creds(url: blr.url));
      expect(c.url, blr.url);
      expect(c.source, GravixJoinUrlSource.token);
    });
  });

  group('standby override', () {
    GravixJoinUrlChoice pick(GravixJoinUrlSource source) => GravixJoinUrlChoice(
      url: sgp.url,
      region: 'sgp1',
      rttMs: 60,
      source: source,
      homeRegion: source == GravixJoinUrlSource.home ? 'sgp1' : null,
    );

    test('measured pick: an open standby in another region wins', () {
      final c = pick(
        GravixJoinUrlSource.measured,
      ).withStandby(standbyUrl: blr.url, pickedOpen: false, standbyOpen: true);
      expect(c.url, blr.url);
      expect(c.source, GravixJoinUrlSource.standby);
    });

    test('home pick: exempt', () {
      final c = pick(GravixJoinUrlSource.home).withStandby(standbyUrl: blr.url, pickedOpen: false, standbyOpen: true);
      expect(c.url, sgp.url);
      expect(c.source, GravixJoinUrlSource.home);
    });

    test('no override when the picked url is open, the standby is not, or it is the same url', () {
      final m = pick(GravixJoinUrlSource.measured);
      expect(m.withStandby(standbyUrl: blr.url, pickedOpen: true, standbyOpen: true).url, sgp.url);
      expect(m.withStandby(standbyUrl: blr.url, pickedOpen: false, standbyOpen: false).url, sgp.url);
      expect(m.withStandby(standbyUrl: sgp.url, pickedOpen: false, standbyOpen: true).source, m.source);
      expect(m.withStandby(standbyUrl: null, pickedOpen: false, standbyOpen: true).url, sgp.url);
    });
  });

  group('the region standby', () {
    GravixStandbyPool pool(List<String> opened) => GravixStandbyPool(
      opener: (url, token, rtt) async {
        opened.add(url);
        return true;
      },
      inForeground: () => true,
      autoTick: false,
    );

    test('targets the measured best region, not the last server a token was sent to', () async {
      await measured({'sgp1': 10, 'blr1': 30, 'fra1': 186});
      expect(gravixJoinUrl(creds(url: blr.url, home: 'blr1')).region, 'blr1'); // a viewer pick
      final opened = <String>[];
      final p = pool(opened);
      await p.warmRegion();
      final region = p.candidates.where((c) => c.role == GravixStandbyRole.ownRegion && c.token.isEmpty).single;
      expect(region.url, sgp.url);
      expect(opened, [sgp.url]);
    });

    test('no measurement yet: no region standby (never a guess)', () async {
      final opened = <String>[];
      final p = pool(opened);
      await p.warmRegion();
      expect(p.candidates.where((c) => c.token.isEmpty), isEmpty);
      expect(opened, isEmpty);
    });

    test('the rtt hint: at least 400 ms (a busy isolate reads the upgrade reply late)', () {
      expect(gravixStandbyRttHintMs(null), 400);
      expect(gravixStandbyRttHintMs(6), 400);
      expect(gravixStandbyRttHintMs(520), 520);
    });

    // Device run B-g 2026-10-15: two host joins of an app on the pool's standby
    // waited the 400 ms hint's 1.2 s window before the fresh dial (wsOpen +2.8 /
    // +3.1 s). The hint floor is for a busy app isolate reading the reply late;
    // with the socket in the signal isolate the measured RTT is passed as it is
    // (the upgrade bound is then 3 x RTT, at least 0.4 s).
    test('the rtt hint with the signal isolate: the measured RTT (unknown: 400 ms as before)', () {
      final was = GravixSignalIsolate.enabled;
      addTearDown(() => GravixSignalIsolate.enabled = was);
      GravixSignalIsolate.enabled = true;
      expect(gravixStandbyRttHintMs(10), 10);
      expect(gravixStandbyRttHintMs(110), 110);
      expect(gravixStandbyRttHintMs(null), 400);
      GravixSignalIsolate.enabled = false;
      expect(gravixStandbyRttHintMs(10), 400);
    });
  });
}

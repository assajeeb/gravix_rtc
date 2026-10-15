// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 0.4.19 fast join: the standby pre-connect POLICY, moved from the apps into the
// package. A pre-connect is the signalling host's TCP + TLS kept open; the token
// travels only in the WebSocket upgrade, so what matters is WHICH SERVER is warm.
// Field 2026-10-04: a list warmed "the first two cards"; both were on one server
// while the tapped card was on another: its WebSocket opened cold (965 ms) and the
// join took 2.6 s. One connection per server, for the servers the user is likeliest
// to need next: the card under the finger, the user's own region, the visible cards
// by position; at most 3 (the SDK keeps 4); closed in the background and when idle.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const fra1 = 'wss://fra1.example.test';
const blr1 = 'wss://blr1.example.test';
const sgp1 = 'wss://sgp1.example.test';
const doh1 = 'wss://doh1.example.test';

GravixStandbyCandidate card(String url, String token, int rank) =>
    GravixStandbyCandidate(url: url, token: token, role: GravixStandbyRole.visible, rank: rank);

void main() {
  group('gravixPlanStandbys', () {
    test('two cards of one server first, a card of another third -> both servers warm, one socket each', () {
      final plan = gravixPlanStandbys([card(fra1, 'fra-a', 0), card(fra1, 'fra-b', 1), card(blr1, 'gx-c', 2)]);
      expect(plan.picks.map((p) => p.host), [
        'fra1.example.test:443',
        'blr1.example.test:443',
      ], reason: 'one per server, by position');
      expect(plan.forHost('fra1.example.test:443')!.token, 'fra-a', reason: 'the first card of that server');
      expect(plan.dropped, isEmpty);
    });

    test('the card under the finger comes first and uses its own token', () {
      final plan = gravixPlanStandbys([
        card(blr1, 'gx-a', 0),
        GravixStandbyCandidate(
          url: blr1,
          token: 'gx-touched',
          role: GravixStandbyRole.touched,
          rank: 4,
          at: DateTime(2026),
        ),
        card(fra1, 'fra-b', 1),
      ]);
      expect(plan.picks.first.host, 'blr1.example.test:443');
      expect(plan.picks.first.token, 'gx-touched');
      expect(plan.picks.first.role, GravixStandbyRole.touched);
    });

    test('priority: touched, own region, visible by position; at most 3', () {
      final plan = gravixPlanStandbys([
        card(fra1, 'fra', 0),
        card(doh1, 'doh', 1),
        const GravixStandbyCandidate(url: blr1, token: '', role: GravixStandbyRole.ownRegion),
        GravixStandbyCandidate(url: sgp1, token: 'sgp', role: GravixStandbyRole.touched, at: DateTime(2026)),
      ]);
      expect(plan.picks.map((p) => p.url), [sgp1, blr1, fra1]);
      expect(plan.dropped, {'doh1.example.test:443'}, reason: 'the later card when there is no room');
    });

    test('a touched server is never dropped, even past the limit', () {
      final plan = gravixPlanStandbys([
        GravixStandbyCandidate(
          url: blr1,
          token: 't1',
          role: GravixStandbyRole.touched,
          at: DateTime(2026, 1, 1, 0, 0, 1),
        ),
        GravixStandbyCandidate(
          url: sgp1,
          token: 't2',
          role: GravixStandbyRole.touched,
          at: DateTime(2026, 1, 1, 0, 0, 2),
        ),
      ], maxHosts: 1);
      expect(plan.picks.map((p) => p.url), [sgp1, blr1], reason: 'most recent touch first; both kept');
    });

    test('own region: the own-room token beats the empty host token on the same server', () {
      final plan = gravixPlanStandbys([
        const GravixStandbyCandidate(url: blr1, token: '', role: GravixStandbyRole.ownRegion),
        const GravixStandbyCandidate(url: '$blr1/', token: 'own', role: GravixStandbyRole.ownRegion),
      ]);
      expect(plan.picks.single.token, 'own');
    });

    test('a visible card\'s token beats the empty host token (a 0.4.8 join needs an exact token)', () {
      final plan = gravixPlanStandbys([
        const GravixStandbyCandidate(url: blr1, token: '', role: GravixStandbyRole.ownRegion),
        card(blr1, 'gx-a', 3),
      ]);
      expect(plan.picks.single.token, 'gx-a');
      expect(plan.picks.single.role, GravixStandbyRole.visible);
    });

    test('host key: ws/http/wss/https and a trailing path are one server', () {
      expect(gravixStandbyHostKey('wss://a.example.test'), gravixStandbyHostKey('https://a.example.test/'));
      expect(gravixStandbyHostKey('ws://a.example.test'), 'a.example.test:80');
      expect(gravixStandbyHostKey('wss://a.example.test:7880/rtc'), 'a.example.test:7880');
    });

    test('empty input: nothing', () {
      final plan = gravixPlanStandbys(const []);
      expect(plan.picks, isEmpty);
      expect(plan.dropped, isEmpty);
    });
  });

  group('GravixStandbyPool', () {
    late DateTime clock;
    late List<String> opened;
    late int closes;
    late Set<String> open;
    late GravixStandbyPool pool;

    setUp(() {
      clock = DateTime(2026, 10, 5, 12);
      opened = [];
      closes = 0;
      open = {};
      pool = GravixStandbyPool(
        opener: (url, token, rtt) async {
          opened.add('${Uri.parse(url).host}|$token');
          open.add('$url|$token');
          return true;
        },
        closer: () async {
          closes++;
          open.clear();
        },
        stateOf: (url, token) => GravixStandbyState(open.contains('$url|$token') ? 'open' : 'none'),
        clock: () => clock,
        autoTick: false,
      );
    });

    test('mixed list: one socket per server, the tapped card finds its standby', () async {
      await pool.noteCard('fra-a', url: fra1, token: 'fra-a', rank: 0);
      await pool.noteCard('fra-b', url: fra1, token: 'fra-b', rank: 1);
      await pool.noteCard('gx-c', url: blr1, token: 'gx-c', rank: 2);
      expect(opened.toSet(), {'fra1.example.test|fra-a', 'blr1.example.test|gx-c'});
      expect(pool.explain(blr1, 'gx-c'), 'host=blr1.example.test exact=open');
    });

    test('tap-down warms the touched card\'s server with its own token at once', () async {
      await pool.noteCard('fra-a', url: fra1, token: 'fra-a', rank: 0);
      opened.clear();
      await pool.touchCard('gx-z', url: blr1, token: 'gx-z');
      expect(opened, contains('blr1.example.test|gx-z'));
      expect(pool.plan.picks.first.role, GravixStandbyRole.touched);
    });

    test('the touched card is not evicted by later list rebuilds', () async {
      await pool.touchCard('gx-z', url: blr1, token: 'gx-z');
      for (final (i, u) in [fra1, sgp1, doh1, 'wss://x.example.test'].indexed) {
        await pool.noteCard('c$i', url: u, token: 'c$i', rank: i);
      }
      expect(pool.plan.forHost('blr1.example.test:443')?.token, 'gx-z');
      // a re-note of the touched card (rebuild) keeps it touched
      await pool.noteCard('gx-z', url: blr1, token: 'gx-z', rank: 5);
      expect(pool.plan.picks.first.token, 'gx-z');
      expect(pool.plan.picks.first.role, GravixStandbyRole.touched);
    });

    test('a touch expires into a plain visible card after the touch TTL', () async {
      await pool.touchCard('gx-z', url: blr1, token: 'gx-z');
      clock = clock.add(kGravixStandbyTouchTtl + const Duration(seconds: 1));
      await pool.noteCard('c0', url: sgp1, token: 'c0', rank: 0);
      expect(pool.plan.forHost('blr1.example.test:443')?.role, GravixStandbyRole.visible);
    });

    test('why none: other server / evicted / not warmed / background / idle', () async {
      expect(pool.explain(blr1, 't'), 'host=blr1.example.test none why=not warmed');
      await pool.noteCard('fra-a', url: fra1, token: 'fra-a', rank: 3);
      expect(pool.explain(blr1, 't'), 'host=blr1.example.test none why=other server warm=fra1.example.test');
      // four servers on screen: the last card's server is dropped
      await pool.noteCard('a', url: blr1, token: 'a', rank: 0);
      await pool.noteCard('b', url: sgp1, token: 'b', rank: 1);
      await pool.noteCard('c', url: doh1, token: 'c', rank: 2);
      expect(
        pool.explain(fra1, 'fra-a'),
        startsWith('host=fra1.example.test exact=open'),
        reason: 'its socket is still open in this fake (the SDK closes it at its limit)',
      );
      expect(pool.explain(fra1, 'another'), startsWith('host=fra1.example.test none why=evicted'));
      // another token for a warm server: the same-host standby is named
      expect(pool.explain(blr1, 'z'), 'host=blr1.example.test exact=none sameHost=open via=visible');
      await pool.paused();
      expect(closes, 1);
      expect(pool.explain(blr1, 'a'), startsWith('host=blr1.example.test none why=background'));
    });

    test('background: everything closed, nothing re-opened until resumed', () async {
      await pool.noteCard('a', url: blr1, token: 'a', rank: 0);
      await pool.paused();
      expect(open, isEmpty);
      opened.clear();
      await pool.noteCard('b', url: sgp1, token: 'b', rank: 1);
      expect(opened, isEmpty, reason: 'no socket opened in the background');
      await pool.resumed();
      expect(opened.toSet(), {'blr1.example.test|a', 'sgp1.example.test|b'});
    });

    test('idle: after the idle window the tick closes all and stops re-opening', () async {
      await pool.noteCard('a', url: blr1, token: 'a', rank: 0);
      clock = clock.add(const Duration(minutes: 1));
      opened.clear();
      await pool.runTick();
      expect(closes, 0);
      expect(opened, ['blr1.example.test|a'], reason: 'the tick re-opens (rotation) while active');
      clock = clock.add(const Duration(minutes: 3));
      await pool.runTick();
      expect(closes, 1);
      expect(pool.explain(blr1, 'a'), startsWith('host=blr1.example.test none why=idle'));
      // the next activity re-opens
      opened.clear();
      await pool.touchCard('a', url: blr1, token: 'a');
      expect(opened, ['blr1.example.test|a']);
    });

    test('resumed after a long time away: nothing re-opened', () async {
      await pool.noteCard('a', url: blr1, token: 'a', rank: 0);
      await pool.paused();
      clock = clock.add(const Duration(minutes: 10));
      opened.clear();
      await pool.resumed();
      expect(opened, isEmpty);
    });
  });
}

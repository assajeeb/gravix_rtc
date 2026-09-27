// Copyright Gravity Compile, Inc. Apache 2.0.

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const a = 'wss://a.example.com';
const b = 'wss://b.example.com';
const c = 'wss://c.example.com';

void main() {
  /// A prober whose probes take [rtt] ms each and record when they STARTED.
  (GravixRegionProber, Map<String, int>) prober(
    Map<String, int> rtt, {
    Duration stagger = Duration.zero,
    Set<String> failing = const {},
  }) {
    final startedAt = <String, int>{};
    final watch = Stopwatch()..start();
    return (
      GravixRegionProber(
        stagger: stagger,
        timeout: const Duration(milliseconds: 400),
        probe: (url) async {
          startedAt[url] = watch.elapsedMilliseconds;
          await Future<void>.delayed(Duration(milliseconds: rtt[url]!));
          if (failing.contains(url)) throw StateError('503');
        },
      ),
      startedAt,
    );
  }

  test('stagger 0 (default): every probe starts together - the race as it always was', () async {
    final (p, startedAt) = prober({a: 30, b: 10, c: 30});
    expect(p.stagger, Duration.zero);
    final outcome = await p.race([a, b, c]);
    expect(outcome.winner, b);
    // The SPREAD between starts, not their distance from the stopwatch's zero:
    // "all within 5 ms of construction" failed once in a full-suite run on a busy
    // machine (2026-09-20) although the probes did start together. Unstaggered
    // probes are started in one synchronous loop; 10 ms is far below the 50 ms a
    // stagger would show.
    final starts = startedAt.values.toList()..sort();
    expect(starts.last - starts.first, lessThanOrEqualTo(10), reason: '$startedAt');
  });

  test('stagger 50ms: probe i starts at i*50ms', () async {
    final (p, startedAt) = prober({a: 20, b: 20, c: 20}, stagger: const Duration(milliseconds: 50));
    await p.race([a, b, c]);
    expect(startedAt[a], lessThan(15));
    expect(startedAt[b], inInclusiveRange(45, 80));
    expect(startedAt[c], inInclusiveRange(95, 130));
  });

  test('decided on RTT, not on arrival: the head start does not win the race', () async {
    // a answers FIRST (t=60) only because it started first; b, started 40ms
    // later, has the lower round trip (30 < 60) and answers at t=70.
    final (p, _) = prober({a: 60, b: 30}, stagger: const Duration(milliseconds: 40));
    final outcome = await p.race([a, b]);
    expect(outcome.winner, b);
    final rtts = {for (final r in outcome.results) r.url: r.elapsed.inMilliseconds};
    expect(
      rtts[b],
      inInclusiveRange(28, 55),
      reason: 'the recorded RTT is the probe\'s own clock, not time since the race began',
    );
  });

  test('the pinned url still wins a tie inside the 15ms window', () async {
    final (p, _) = prober({a: 40, b: 30}, stagger: const Duration(milliseconds: 40));
    final outcome = await p.race([a, b], pinnedUrl: a);
    expect(outcome.winner, a, reason: 'a is pinned and only 10ms slower than b');
  });

  test('does not wait for a slow region once it can no longer win', () async {
    final (p, _) = prober({a: 20, b: 350}, stagger: const Duration(milliseconds: 30));
    final outcome = await p.race([a, b]);
    expect(outcome.winner, a);
    // b started at 30 and could only win by answering before 30+20 = 50.
    expect(outcome.elapsed.inMilliseconds, lessThan(150));
  });

  test('a failed region does not win, and total failure falls back like the unstaggered race', () async {
    final (p, _) = prober({a: 10, b: 30}, stagger: const Duration(milliseconds: 20), failing: {a});
    expect((await p.race([a, b])).winner, b);

    final (q, _) = prober({a: 10, b: 10}, stagger: const Duration(milliseconds: 20), failing: {a, b});
    final none = await q.race([a, b]);
    expect(none.winner, isNull);
    expect(none.fallbackReason, GravixRegionFallbackReason.allProbesFailed);
  });

  test('each probe has the timeout from ITS OWN start; nobody answering is a timeout', () async {
    final (p, _) = prober({a: 2000, b: 2000}, stagger: const Duration(milliseconds: 50));
    final outcome = await p.race([a, b]);
    expect(outcome.winner, isNull);
    expect(outcome.fallbackReason, GravixRegionFallbackReason.timeout);
    // timeout 400 + (N-1)*50 stagger: the documented worst case.
    expect(outcome.elapsed.inMilliseconds, inInclusiveRange(440, 600));
  });

  test('a single candidate is never staggered', () async {
    final (p, startedAt) = prober({a: 10}, stagger: const Duration(milliseconds: 50));
    expect((await p.race([a])).winner, a);
    expect(startedAt[a], lessThan(15));
  });
}

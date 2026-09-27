import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  /// A prober whose probes resolve after a fixed delay, or throw.
  GravixRegionProber proberWith(Map<String, Object> behaviour, {Duration timeout = const Duration(seconds: 5)}) {
    return GravixRegionProber(
      timeout: timeout,
      probe: (url) async {
        final b = behaviour[url];
        if (b is Duration) {
          await Future<void>.delayed(b);
          return;
        }
        if (b is Duration Function()) {
          await Future<void>.delayed(b());
          return;
        }
        throw b ?? StateError('unreachable: $url');
      },
    );
  }

  group('race', () {
    test('the fastest region wins', () async {
      final prober = proberWith({
        'wss://slow.example': const Duration(milliseconds: 120),
        'wss://fast.example': const Duration(milliseconds: 10),
        'wss://mid.example': const Duration(milliseconds: 60),
      });

      final outcome = await prober.race(['wss://slow.example', 'wss://fast.example', 'wss://mid.example']);

      expect(outcome.winner, 'wss://fast.example');
      expect(outcome.fallbackReason, GravixRegionFallbackReason.none);
    });

    test('the race resolves on the first responder, not on all of them', () async {
      final prober = proberWith({
        'wss://fast.example': const Duration(milliseconds: 10),
        'wss://glacial.example': const Duration(seconds: 30),
      });

      final sw = Stopwatch()..start();
      final outcome = await prober.race(['wss://glacial.example', 'wss://fast.example']);
      sw.stop();

      expect(outcome.winner, 'wss://fast.example');
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('one failing region does not pull the join off a healthy one', () async {
      final prober = proberWith({
        'wss://broken.example': StateError('500'),
        'wss://healthy.example': const Duration(milliseconds: 50),
      });

      final outcome = await prober.race(['wss://broken.example', 'wss://healthy.example']);

      expect(outcome.winner, 'wss://healthy.example');
    });

    test('all probes failing reports allProbesFailed, not a winner', () async {
      final prober = proberWith({'wss://a.example': StateError('down'), 'wss://b.example': StateError('down')});

      final outcome = await prober.race(['wss://a.example', 'wss://b.example']);

      expect(outcome.winner, isNull);
      expect(outcome.fallbackReason, GravixRegionFallbackReason.allProbesFailed);
      expect(outcome.results.where((r) => !r.ok).length, 2);
    });

    test('no responder before the deadline reports timeout', () async {
      final prober = proberWith({
        'wss://glacial.example': const Duration(seconds: 30),
      }, timeout: const Duration(milliseconds: 50));

      final outcome = await prober.race(['wss://glacial.example']);

      expect(outcome.winner, isNull);
      expect(outcome.fallbackReason, GravixRegionFallbackReason.timeout);
    });

    test('an empty candidate list is noRegionUrls and sends nothing', () async {
      var probes = 0;
      final prober = GravixRegionProber(probe: (_) async => probes++);

      final outcome = await prober.race(const []);

      expect(probes, 0);
      expect(outcome.winner, isNull);
      expect(outcome.fallbackReason, GravixRegionFallbackReason.noRegionUrls);
    });

    test('records each probe outcome for the report', () async {
      final prober = proberWith({
        'wss://broken.example': StateError('500'),
        'wss://healthy.example': const Duration(milliseconds: 50),
      });

      final outcome = await prober.race(['wss://broken.example', 'wss://healthy.example']);

      expect(outcome.results.map((r) => r.url), containsAll(['wss://broken.example', 'wss://healthy.example']));
      expect(outcome.results.firstWhere((r) => r.url == 'wss://broken.example').error, isA<StateError>());
    });
  });

  // JS keeps the pinned region when its RTT is within 15ms of the fastest
  // (TIE_BREAK_MS): a marginally faster edge is not worth moving a join off the
  // region the gateway chose. Until 2026-09-19 this SDK took the first responder
  // outright. Probes start together, so "within 15ms of the fastest RTT" is
  // "answers within 15ms after the first responder" - the same winner as JS,
  // without waiting for every probe.
  group('race with a pinned url (15ms tie-break)', () {
    const pinned = 'wss://pinned.example';
    const other = 'wss://other.example';

    test('the pinned region keeps the join when it answers within 15ms of the fastest', () async {
      final prober = proberWith({other: const Duration(milliseconds: 20), pinned: const Duration(milliseconds: 28)});
      final outcome = await prober.race([other, pinned], pinnedUrl: pinned);
      expect(outcome.winner, pinned);
    });

    test('a clearly faster region still wins over the pinned one', () async {
      final prober = proberWith({other: const Duration(milliseconds: 10), pinned: const Duration(milliseconds: 120)});
      final outcome = await prober.race([other, pinned], pinnedUrl: pinned);
      expect(outcome.winner, other);
    });

    test('waiting for the pinned region costs at most the window, not its RTT', () async {
      final prober = proberWith({other: const Duration(milliseconds: 10), pinned: const Duration(seconds: 30)});
      final sw = Stopwatch()..start();
      final outcome = await prober.race([other, pinned], pinnedUrl: pinned);
      sw.stop();
      expect(outcome.winner, other);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('a pinned probe that already failed is not waited for', () async {
      final prober = proberWith({other: const Duration(milliseconds: 40), pinned: StateError('503')});
      final outcome = await prober.race([other, pinned], pinnedUrl: pinned);
      expect(outcome.winner, other);
    });

    test('a pinned url that is not a candidate changes nothing', () async {
      final prober = proberWith({
        other: const Duration(milliseconds: 10),
        'wss://b.example': const Duration(milliseconds: 15),
      });
      final outcome = await prober.race([other, 'wss://b.example'], pinnedUrl: pinned);
      expect(outcome.winner, other);
    });

    test('raceEntries honours the pinned url too', () async {
      final prober = proberWith({other: const Duration(milliseconds: 20), pinned: const Duration(milliseconds: 28)});
      final outcome = await prober.raceEntries(const [
        GravixRegionUrl(region: 'o', url: other),
        GravixRegionUrl(region: 'p', url: pinned),
      ], pinnedUrl: pinned);
      expect(outcome.winner, pinned);
    });
  });

  group('gravixRegionUrlsFrom', () {
    test('reads a list of strings', () {
      expect(
        gravixRegionUrlsFrom({
          'token': 'x',
          'region_urls': ['wss://a.example', 'wss://b.example'],
        }),
        ['wss://a.example', 'wss://b.example'],
      );
    });

    test('reads a list of objects carrying a url key', () {
      expect(
        gravixRegionUrlsFrom({
          'region_urls': [
            {'region': 'sin', 'url': 'wss://sin.example'},
            {'region': 'fra', 'url': 'wss://fra.example'},
          ],
        }),
        ['wss://sin.example', 'wss://fra.example'],
      );
    });

    // The "absent region_urls => identical behaviour" contract starts here:
    // every one of these must yield an empty list, which makes connect() skip
    // the race entirely.
    test('yields empty for anything that is not a usable list', () {
      expect(gravixRegionUrlsFrom(null), isEmpty);
      expect(gravixRegionUrlsFrom({}), isEmpty);
      expect(gravixRegionUrlsFrom({'token': 'x'}), isEmpty);
      expect(gravixRegionUrlsFrom({'region_urls': null}), isEmpty);
      expect(gravixRegionUrlsFrom({'region_urls': 'wss://a.example'}), isEmpty);
      expect(gravixRegionUrlsFrom({'region_urls': 42}), isEmpty);
      expect(gravixRegionUrlsFrom({'region_urls': []}), isEmpty);
      expect(
        gravixRegionUrlsFrom({
          'region_urls': [1, 2],
        }),
        isEmpty,
      );
      expect(
        gravixRegionUrlsFrom({
          'region_urls': [
            {'region': 'sin'},
          ],
        }),
        isEmpty,
      );
      expect(
        gravixRegionUrlsFrom({
          'region_urls': [''],
        }),
        isEmpty,
      );
    });

    test('skips unusable entries but keeps usable ones', () {
      expect(
        gravixRegionUrlsFrom({
          'region_urls': [
            'wss://a.example',
            42,
            '',
            {'url': 'wss://b.example'},
            {'no': 'url'},
          ],
        }),
        ['wss://a.example', 'wss://b.example'],
      );
    });
  });
}

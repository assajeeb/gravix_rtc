// Copyright Gravity Compile, Inc. Apache 2.0.

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const sgp = 'wss://rtc.example.com';
const blr = 'wss://rtc-blr1.example.com';
const fra = 'wss://rtc-fra1.example.com';
String probeOf(String host) => 'https://$host/v1/region-probe';

void main() {
  group('region_urls carries the gateway probe endpoint', () {
    // The token gateway sends `probe_url` per region: the SFU's
    // /v1/region-probe, which is uncached, lock-free and built for this. The SDK
    // used to drop the field and HEAD `https://host/` instead - on a real
    // deployment that is the load balancer's default handler, so the race could
    // be won by an edge with no SFU behind it.
    test('probe_url is parsed', () {
      final entries = gravixRegionEntriesFrom({
        'region_urls': [
          {'region': 'sgp1', 'url': sgp, 'probe_url': probeOf('rtc.example.com'), 'home': true},
          {'region': 'blr1', 'url': blr},
        ],
      });
      expect(entries[0].probeUrl, probeOf('rtc.example.com'));
      expect(entries[1].probeUrl, isNull, reason: 'a gateway that sends none still works');
    });
  });

  group('GravixRegionProber.raceEntries', () {
    test('probes the dedicated endpoint, not the signalling origin root', () async {
      final rootProbed = <String>[];
      final endpointProbed = <String>[];
      final prober = GravixRegionProber(
        probe: (url) async => rootProbed.add(url),
        verifiedProbe: (probeUrl) async {
          endpointProbed.add(probeUrl);
          return 'blr1';
        },
      );
      final outcome = await prober.raceEntries([
        GravixRegionUrl(region: 'blr1', url: blr, probeUrl: probeOf('rtc-blr1.example.com')),
      ]);
      expect(outcome.winner, blr);
      expect(endpointProbed, [probeOf('rtc-blr1.example.com')]);
      expect(rootProbed, isEmpty);
    });

    // The gateway contract: "the client verifies they agree, because a probe
    // that answers fast while naming a different region means a misrouted DNS/LB
    // entry, and a region that wins a race but cannot be joined is worse than a
    // slower one."
    test('an edge that names a different region cannot win', () async {
      final prober = GravixRegionProber(
        verifiedProbe: (probeUrl) async {
          if (probeUrl.contains('blr1')) return 'sgp1'; // instant, and lying
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return 'sgp1';
        },
      );
      final outcome = await prober.raceEntries([
        GravixRegionUrl(region: 'sgp1', url: sgp, probeUrl: probeOf('rtc.example.com')),
        GravixRegionUrl(region: 'blr1', url: blr, probeUrl: probeOf('rtc-blr1.example.com')),
      ]);
      expect(outcome.winner, sgp);
      final blrResult = outcome.results.firstWhere((r) => r.url == blr);
      expect(blrResult.ok, isFalse);
      expect('${blrResult.error}', contains('sgp1'));
    });

    test('an entry with no probeUrl is still probed the old way', () async {
      final rootProbed = <String>[];
      final prober = GravixRegionProber(probe: (url) async => rootProbed.add(url));
      final outcome = await prober.raceEntries([const GravixRegionUrl(region: 'sgp1', url: sgp)]);
      expect(outcome.winner, sgp);
      expect(rootProbed, [sgp]);
    });
  });

  group('gravixRegionFallbackLadder', () {
    GravixRegionRaceOutcome outcomeOf(String? winner, {List<String> failed = const []}) => GravixRegionRaceOutcome(
      winner: winner,
      elapsed: Duration.zero,
      fallbackReason: GravixRegionFallbackReason.none,
      results: [
        for (final u in failed) GravixRegionProbeResult(url: u, elapsed: Duration.zero, ok: false, error: 'down'),
        if (winner != null) GravixRegionProbeResult(url: winner, elapsed: Duration.zero, ok: true),
      ],
    );

    // A probe answers over HTTPS; the join goes over a WebSocket. An edge can
    // pass one and refuse the other. That used to turn a slow join into a FAILED
    // join: connect() tried the winner once and returned false, with the pinned
    // URL - always a valid destination - never tried.
    test('the other candidates in gateway order, always ending on the pinned url', () {
      expect(gravixRegionFallbackLadder(outcome: outcomeOf(blr), candidates: [sgp, blr, fra], pinnedUrl: sgp), [
        fra,
        sgp,
      ]);
    });

    test('a candidate whose probe already failed is not offered', () {
      expect(
        gravixRegionFallbackLadder(
          outcome: outcomeOf(blr, failed: [fra]),
          candidates: [sgp, blr, fra],
          pinnedUrl: sgp,
        ),
        [sgp],
      );
    });

    test('the pinned url is kept even if its own probe failed', () {
      // A failed HTTP probe is weak evidence against a WebSocket, and the pinned
      // url is the destination the gateway named.
      expect(
        gravixRegionFallbackLadder(
          outcome: outcomeOf(blr, failed: [sgp]),
          candidates: [sgp, blr],
          pinnedUrl: sgp,
        ),
        [sgp],
      );
    });

    test('empty when the pinned url was the one that was tried', () {
      expect(gravixRegionFallbackLadder(outcome: outcomeOf(null), candidates: [sgp], pinnedUrl: sgp), isEmpty);
      expect(gravixRegionFallbackLadder(outcome: outcomeOf(sgp), candidates: [sgp], pinnedUrl: sgp), isEmpty);
    });
  });

  group('gravixConnectWithLadder', () {
    test('lands on the next url when the first refuses', () async {
      final tried = <String>[];
      final landed = await gravixConnectWithLadder(
        urls: [blr, fra, sgp],
        attempt: (url) async {
          tried.add(url);
          if (url == blr) throw StateError('ws refused');
        },
      );
      expect(tried, [blr, fra]);
      expect(landed, fra);
    });

    test('rethrows the LAST error once every url has been tried exactly once', () async {
      final tried = <String>[];
      await expectLater(
        gravixConnectWithLadder(
          urls: [blr, sgp],
          attempt: (url) async {
            tried.add(url);
            throw StateError('down: $url');
          },
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'down: $sgp')),
      );
      expect(tried, [blr, sgp]);
    });

    test('an error another region cannot fix is not retried', () async {
      final tried = <String>[];
      await expectLater(
        gravixConnectWithLadder(
          urls: [blr, fra, sgp],
          attempt: (url) async {
            tried.add(url);
            throw ArgumentError('token refused');
          },
          isRetryable: (e) => e is! ArgumentError,
        ),
        throwsArgumentError,
      );
      expect(tried, [blr]);
    });

    test('a refused token is classified as not retryable', () {
      expect(gravixIsRegionRetryable(StateError('socket closed')), isTrue);
      expect(
        gravixIsRegionRetryable(ConnectException('no', reason: ConnectionErrorReason.NotAllowed, statusCode: 401)),
        isFalse,
      );
    });
  });
}

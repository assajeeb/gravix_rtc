import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

/// A port of the JS SDK's `test/regionCache.test.ts`, plus the one case only this
/// SDK has: the remembered region still in flight when the race decided.
void main() {
  const sgp = 'wss://rtc.example.com';
  const blr = 'wss://rtc-blr1.example.com';
  const fra = 'wss://rtc-fra1.example.com';
  const entries = [
    GravixRegionUrl(region: 'sgp1', url: sgp),
    GravixRegionUrl(region: 'blr1', url: blr),
    GravixRegionUrl(region: 'fra1', url: fra),
  ];
  const offered = [sgp, blr, fra];

  late DateTime now;
  late GravixRegionDecisionCache cache;

  setUp(() {
    now = DateTime.utc(2026, 9, 19);
    cache = GravixRegionDecisionCache(now: () => now);
  });

  /// A race `winner` won. A null RTT is a failed probe; a url left out of
  /// [rtts] was still in flight when the race decided.
  GravixRegionRaceOutcome raced(String? winner, Map<String, int?> rtts) => GravixRegionRaceOutcome(
    winner: winner,
    elapsed: Duration.zero,
    fallbackReason: winner == null ? GravixRegionFallbackReason.allProbesFailed : GravixRegionFallbackReason.none,
    results: [
      for (final e in rtts.entries)
        GravixRegionProbeResult(
          url: e.key,
          elapsed: Duration(milliseconds: e.value ?? 0),
          ok: e.value != null,
        ),
    ],
  );

  void record(String? winner, Map<String, int?> rtts) => cache.record(sgp, raced(winner, rtts), candidates: entries);
  void advance(Duration d) => now = now.add(d);

  test('a repeat join gets the previous decision without racing', () {
    record(blr, {sgp: 120, blr: 20});
    final hit = cache.read(sgp, offered);
    expect(hit?.url, blr);
    expect(hit?.region, 'blr1');
  });

  test('misses when nothing was recorded, and per gateway pin', () {
    expect(cache.read(sgp, offered), isNull);
    record(blr, {sgp: 120, blr: 20});
    expect(cache.read('wss://other-gateway.example.com', offered), isNull);
  });

  test('expires, so a user who travelled is re-raced', () {
    record(blr, {sgp: 120, blr: 20});
    advance(GravixRegionDecisionCache.ttl - const Duration(milliseconds: 1));
    expect(cache.read(sgp, offered)?.url, blr);
    advance(const Duration(milliseconds: 2));
    expect(cache.read(sgp, offered), isNull);
  });

  test('is ignored when the gateway no longer offers that region', () {
    record(blr, {sgp: 120, blr: 20});
    expect(cache.read(sgp, [sgp, fra]), isNull);
  });

  test('a race nobody answered is not a decision worth remembering', () {
    record(null, {sgp: null, blr: null});
    expect(cache.read(sgp, offered), isNull);
  });

  test('is forgotten when the remembered region refuses the connection', () {
    record(blr, {sgp: 120, blr: 20});
    cache.forget(sgp);
    expect(cache.read(sgp, offered), isNull);
  });

  group('a region that refused a connection', () {
    test('is kept out of the memory, so the next race cannot put it straight back', () {
      cache.forget(sgp, refusedUrl: blr);
      advance(const Duration(seconds: 1));
      record(blr, {blr: 10, fra: 90});
      expect(cache.read(sgp, offered)?.url, fra);
    });

    test('is eligible again once the penalty has passed - a drain ends', () {
      cache.forget(sgp, refusedUrl: blr);
      advance(GravixRegionDecisionCache.refusalPenalty + const Duration(milliseconds: 1));
      record(blr, {blr: 10, fra: 200});
      expect(cache.read(sgp, offered)?.url, blr);
    });

    test('the region the join actually landed on is remembered at once', () {
      cache.forget(sgp, refusedUrl: blr);
      cache.recordLanded(sgp, url: fra, region: 'fra1');
      expect(cache.read(sgp, offered)?.url, fra);
    });
  });

  group('hysteresis across connects', () {
    test('keeps the remembered region when a rival is only marginally faster', () {
      record(blr, {blr: 50, fra: 90});
      record(fra, {blr: 50, fra: 40});
      expect(cache.read(sgp, offered)?.url, blr);
    });

    test('switches when the rival is clearly better', () {
      record(blr, {blr: 200, fra: 250});
      record(fra, {blr: 200, fra: 60});
      expect(cache.read(sgp, offered)?.url, fra);
    });

    test('switches at once when the remembered region stopped answering', () {
      record(blr, {blr: 20, fra: 90});
      record(fra, {blr: null, fra: 90});
      expect(cache.read(sgp, offered)?.url, fra);
    });

    test('a remembered region still in flight is kept but not refreshed, so the TTL settles it', () {
      record(blr, {blr: 20, fra: 90});
      advance(const Duration(minutes: 6));
      record(fra, {fra: 40}); // blr's probe had not answered when fra won
      expect(cache.read(sgp, offered)?.url, blr);
      advance(const Duration(minutes: 5)); // 11 min after blr was last confirmed
      expect(cache.read(sgp, offered), isNull);
    });
  });
}

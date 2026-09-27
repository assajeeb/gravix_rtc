import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

/// The probe-race telemetry contract, which is shared byte for byte with the
/// JS SDK (`src/core/room/region/types.ts`). These tests pin the two things a
/// cross-SDK join depends on: the field names on the wire, and the split into
/// a region event that never waits and a first-audio event that follows.
void main() {
  const candidates = [
    GravixRegionUrl(region: 'sgp1', url: 'wss://sgp1.example.com'),
    GravixRegionUrl(region: 'blr1', url: 'wss://blr1.example.com'),
  ];
  final probeStartedAt = DateTime.utc(2026, 9, 12, 10, 4, 0);
  final connectStartedAt = DateTime.utc(2026, 9, 12, 10, 4, 0, 50);
  final connectedAt = DateTime.utc(2026, 9, 12, 10, 4, 1);

  GravixRegionReport build({
    String pinned = 'wss://sgp1.example.com',
    String chosen = 'wss://blr1.example.com',
    bool anyResponder = true,
    List<GravixRegionUrl> regions = candidates,
    Map<String, ({bool ok, Duration elapsed})> results = const {
      'wss://sgp1.example.com': (ok: true, elapsed: Duration(milliseconds: 120)),
      'wss://blr1.example.com': (ok: true, elapsed: Duration(milliseconds: 20)),
    },
  }) => buildGravixRegionReport(
    connectionId: 'cid-1',
    candidates: regions,
    pinnedUrl: pinned,
    chosenUrl: chosen,
    anyResponder: anyResponder,
    results: results,
    probeStartedAt: probeStartedAt,
    connectStartedAt: connectStartedAt,
    connectedAt: connectedAt,
  );

  group('region event — the wire contract', () {
    // If this list drifts from the JS SDK's RegionReport, the two SDKs' rows
    // stop joining and the telemetry is worthless. Change both or neither.
    test('carries exactly the JS SDK field names, no more and no fewer', () {
      expect(build().toJson().keys.toSet(), {
        'connectionId',
        'pinnedRegion',
        'chosenRegion',
        'chosenUrl',
        'fallbackUsed',
        'reason',
        'probes',
        'probeMethod',
        'probeStartedAt',
        'connectStartedAt',
        'connectedAt',
      });
    });

    test('each probe carries exactly the JS SDK RegionProbe field names', () {
      final probe = (build().toJson()['probes'] as List).first as Map<String, dynamic>;
      expect(probe.keys.toSet(), {'region', 'url', 'rttMs', 'ok', 'method', 'methodFallback'});
    });

    test('timestamps are UTC ISO-8601 with millisecond precision', () {
      final json = build().toJson();
      expect(json['probeStartedAt'], '2026-09-12T10:04:00.000Z');
      expect(json['connectStartedAt'], '2026-09-12T10:04:00.050Z');
      expect(json['connectedAt'], '2026-09-12T10:04:01.000Z');
    });

    test('microseconds are truncated so the two SDKs cannot disagree on precision', () {
      final report = buildGravixRegionReport(
        connectionId: 'cid-1',
        candidates: candidates,
        pinnedUrl: 'wss://sgp1.example.com',
        chosenUrl: 'wss://sgp1.example.com',
        anyResponder: true,
        results: const {'wss://sgp1.example.com': (ok: true, elapsed: Duration(milliseconds: 5))},
        probeStartedAt: DateTime.utc(2026, 9, 12, 10, 4, 0, 123, 456),
        connectStartedAt: connectStartedAt,
        connectedAt: connectedAt,
      );
      expect(report.toJson()['probeStartedAt'], '2026-09-12T10:04:00.123Z');
    });

    test('a local timestamp is normalised to UTC', () {
      final local = DateTime.utc(2026, 9, 12, 10, 4, 1).toLocal();
      final report = buildGravixRegionReport(
        connectionId: 'cid-1',
        candidates: candidates,
        pinnedUrl: 'wss://sgp1.example.com',
        chosenUrl: 'wss://sgp1.example.com',
        anyResponder: true,
        results: const {},
        probeStartedAt: local,
        connectStartedAt: local,
        connectedAt: local,
      );
      expect(report.toJson()['connectedAt'], '2026-09-12T10:04:01.000Z');
    });
  });

  group('region event — the decision', () {
    test('a faster far region wins and is reported as probe-winner', () {
      final json = build().toJson();
      expect(json['chosenRegion'], 'blr1');
      expect(json['pinnedRegion'], 'sgp1');
      expect(json['fallbackUsed'], isFalse);
      expect(json['reason'], 'probe-winner');
      expect(json['probeMethod'], 'HEAD');
    });

    test('the pinned url winning its own race is reported as pinned-tiebreak', () {
      expect(build(chosen: 'wss://sgp1.example.com').toJson()['reason'], 'pinned-tiebreak');
    });

    test('a single candidate is reported as single-region', () {
      final json = build(
        regions: const [GravixRegionUrl(region: 'sgp1', url: 'wss://sgp1.example.com')],
        chosen: 'wss://sgp1.example.com',
      ).toJson();
      expect(json['reason'], 'single-region');
    });

    test('no responder falls back to the pinned url with a null probeMethod', () {
      final json = build(
        chosen: 'wss://sgp1.example.com',
        anyResponder: false,
        results: const {
          'wss://sgp1.example.com': (ok: false, elapsed: Duration(milliseconds: 1500)),
          'wss://blr1.example.com': (ok: false, elapsed: Duration(milliseconds: 1500)),
        },
      ).toJson();
      expect(json['fallbackUsed'], isTrue);
      expect(json['reason'], 'no-responder');
      expect(json['probeMethod'], isNull, reason: 'no measurement produced the choice');
      expect((json['probes'] as List).every((p) => (p as Map)['rttMs'] == null), isTrue);
    });

    // A probe still in flight when the race was decided must still appear, or
    // the array length stops meaning "candidates the server offered".
    test('a candidate with no result is reported as a non-responder, not omitted', () {
      final json = build(
        results: const {'wss://blr1.example.com': (ok: true, elapsed: Duration(milliseconds: 20))},
      ).toJson();
      final probes = (json['probes'] as List).cast<Map<String, dynamic>>();
      expect(probes, hasLength(2));
      expect(probes.first['region'], 'sgp1');
      expect(probes.first['ok'], isFalse);
      expect(probes.first['rttMs'], isNull);
    });

    test('probes keep the order the server supplied', () {
      final probes = (build().toJson()['probes'] as List).cast<Map<String, dynamic>>();
      expect(probes.map((p) => p['region']), ['sgp1', 'blr1']);
    });

    test('a url outside the candidate list reports the unknown slug', () {
      expect(build(pinned: 'wss://elsewhere.example.com').toJson()['pinnedRegion'], 'unknown');
    });

    // HEAD stays the probe method. The JS SDK moved to HEAD to match this one;
    // GET exists only as a 405/501 retry and this SDK never issues it.
    test('HEAD is the probe method and methodFallback is always false', () {
      final probes = (build().toJson()['probes'] as List).cast<Map<String, dynamic>>();
      expect(probes.every((p) => p['method'] == 'HEAD'), isTrue);
      expect(probes.every((p) => p['methodFallback'] == false), isTrue);
    });
  });

  group('first-audio event — the separate, later half', () {
    test('carries exactly the JS SDK FirstAudioReport field names', () {
      final json = buildGravixFirstAudioReport(
        connectionId: 'cid-1',
        connectedAt: connectedAt,
        firstAudioAt: connectedAt.add(const Duration(milliseconds: 640)),
      ).toJson();
      expect(json.keys.toSet(), {'connectionId', 'connectedAt', 'firstAudioAt', 'joinToFirstAudioMs'});
    });

    test('measures from connectedAt, not from connect() entry', () {
      final json = buildGravixFirstAudioReport(
        connectionId: 'cid-1',
        connectedAt: connectedAt,
        firstAudioAt: connectedAt.add(const Duration(milliseconds: 640)),
      ).toJson();
      expect(json['joinToFirstAudioMs'], 640);
      expect(json['firstAudioAt'], '2026-09-12T10:04:01.640Z');
    });

    // The point of the split: a session that ends before audio arrives still
    // gets this event, so a consumer joining on connectionId is never left
    // waiting for a row that is never coming.
    test('a silent session still reports, with both audio fields null', () {
      final json = buildGravixFirstAudioReport(
        connectionId: 'cid-1',
        connectedAt: connectedAt,
        firstAudioAt: null,
      ).toJson();
      expect(json['firstAudioAt'], isNull);
      expect(json['joinToFirstAudioMs'], isNull);
      expect(json['connectedAt'], '2026-09-12T10:04:01.000Z', reason: 'the event stands on its own');
    });

    test('correlates with the region event on connectionId', () {
      final region = build();
      final audio = buildGravixFirstAudioReport(
        connectionId: region.connectionId,
        connectedAt: region.connectedAt,
        firstAudioAt: null,
      );
      expect(audio.connectionId, region.connectionId);
      expect(audio.toJson()['connectedAt'], region.toJson()['connectedAt']);
    });

    test('the 30s give-up window matches the JS SDK', () {
      expect(kGravixFirstAudioTimeout, const Duration(seconds: 30));
    });
  });

  group('gravixRegionEntriesFrom — region slugs survive the token response', () {
    test('keeps the slug that gravixRegionUrlsFrom throws away', () {
      final entries = gravixRegionEntriesFrom({
        'region_urls': [
          {'region': 'sgp1', 'url': 'wss://sgp1.example.com'},
          {'region': 'blr1', 'url': 'wss://blr1.example.com'},
        ],
      });
      expect(entries, candidates);
    });

    test('a bare string entry is kept with the unknown slug, not dropped', () {
      final entries = gravixRegionEntriesFrom({
        'region_urls': ['wss://a.example'],
      });
      expect(entries, const [GravixRegionUrl(region: 'unknown', url: 'wss://a.example')]);
    });

    test('is as tolerant as gravixRegionUrlsFrom about broken payloads', () {
      for (final payload in <Map<String, dynamic>>[
        {},
        {'region_urls': null},
        {'region_urls': 'wss://a.example'},
        {'region_urls': <dynamic>[]},
        {
          'region_urls': [
            {'region': 'sgp1'},
          ],
        },
        {
          'region_urls': [
            {'url': 42},
          ],
        },
      ]) {
        expect(gravixRegionEntriesFrom(payload), isEmpty, reason: 'payload $payload');
      }
    });

    test('a map entry with no region slug still yields the url', () {
      final entries = gravixRegionEntriesFrom({
        'region_urls': [
          {'url': 'wss://a.example'},
        ],
      });
      expect(entries.single, const GravixRegionUrl(region: 'unknown', url: 'wss://a.example'));
    });
  });
}

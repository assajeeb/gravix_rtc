import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  group('gravixEffectiveQuality', () {
    test('field 2026-10-02: excellent from the server, 43 % down loss + 7.9 s RTT -> lost', () {
      expect(
        gravixEffectiveQuality(ConnectionQuality.excellent, uplinkLossPct: 0.6, downlinkLossPct: 43.53, rttMs: 7951),
        ConnectionQuality.lost,
      );
      // the 25 % / 7.9 s sample alone: the RTT is enough
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, downlinkLossPct: 25.42, rttMs: 7951), ConnectionQuality.lost);
      // 67 % uplink loss with a sane RTT: lost on loss
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, uplinkLossPct: 67.4, rttMs: 120), ConnectionQuality.lost);
    });

    test('steps: good / poor / lost on loss and on RTT', () {
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, downlinkLossPct: 2.9, rttMs: 399), ConnectionQuality.excellent);
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, downlinkLossPct: 3), ConnectionQuality.good);
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, rttMs: 400), ConnectionQuality.good);
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, uplinkLossPct: 10), ConnectionQuality.poor);
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, rttMs: 1000), ConnectionQuality.poor);
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, rttMs: 3000), ConnectionQuality.lost);
    });

    test('never better than the server', () {
      expect(gravixEffectiveQuality(ConnectionQuality.poor, downlinkLossPct: 0, rttMs: 20), ConnectionQuality.poor);
      expect(gravixEffectiveQuality(ConnectionQuality.lost, downlinkLossPct: 4), ConnectionQuality.lost);
      expect(gravixEffectiveQuality(ConnectionQuality.good, downlinkLossPct: 12), ConnectionQuality.poor);
    });

    test('no local evidence: the server value stands, unknown included', () {
      expect(gravixEffectiveQuality(ConnectionQuality.excellent), ConnectionQuality.excellent);
      expect(gravixEffectiveQuality(ConnectionQuality.unknown), ConnectionQuality.unknown);
      expect(gravixEffectiveQuality(ConnectionQuality.unknown, rttMs: 1200), ConnectionQuality.poor);
      // RTT 0 / null and NaN loss are "not measured", not "perfect"
      expect(gravixEffectiveQuality(ConnectionQuality.good, rttMs: 0, downlinkLossPct: double.nan), ConnectionQuality.good);
    });

    test('reconnecting caps the label at poor', () {
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, reconnecting: true), ConnectionQuality.poor);
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, reconnecting: true, rttMs: 5000), ConnectionQuality.lost);
      expect(gravixLocalQuality(reconnecting: true), ConnectionQuality.poor);
      expect(gravixLocalQuality(), isNull);
    });

    test('custom thresholds', () {
      const t = GravixQualityThresholds(goodLossPct: 1, poorLossPct: 2, lostLossPct: 5);
      expect(gravixEffectiveQuality(ConnectionQuality.excellent, downlinkLossPct: 2.5, thresholds: t), ConnectionQuality.poor);
    });
  });
}

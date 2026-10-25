// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// uplinkFeedbackStallFor decision logic (GravixUplinkFeedbackWatch), on a fake
// clock with the 2 s stats cadence of the local tracks. Emulator 2026-10-11
// r402 / r407 (host, UDP died, libwebrtc moved the publisher PC to ICE-TCP
// without a restart): the host kept sending, but no receiver report came back
// from the SFU ("No RTCP RR received") for 12 s / 28 s until the SFU's ICE gave
// up; viewers saw black video meanwhile.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_uplink_watch.dart';

void main() {
  late DateTime now;
  late GravixUplinkFeedbackWatch w;
  const stall = Duration(seconds: 5);
  setUp(() {
    now = DateTime(2026, 10, 11, 6, 20);
    w = GravixUplinkFeedbackWatch(clock: () => now);
  });
  void tick([int ms = 2000]) => now = now.add(Duration(milliseconds: ms));
  bool s(String key, num sent, String? rr, {bool eligible = true, Duration stallFor = stall}) =>
      w.sample(key, eligible: eligible, packetsSent: sent, feedback: rr, stallFor: stallFor);

  test('sending with no new receiver report for 5 s -> a resume, once', () {
    expect(s('mic', 100, 'rr1'), isFalse);
    tick();
    expect(s('mic', 200, 'rr2'), isFalse, reason: 'a new report');
    tick();
    expect(s('mic', 300, 'rr2'), isFalse, reason: '2 s without a report');
    tick();
    expect(s('mic', 400, 'rr2'), isFalse, reason: '4 s');
    tick();
    expect(s('mic', 500, 'rr2'), isTrue, reason: '6 s without a report while 300 packets went out');
    tick();
    expect(s('mic', 600, 'rr2'), isFalse, reason: 'not again at once');
  });

  test('reports keep coming -> nothing', () {
    for (var i = 0; i < 20; i++) {
      expect(s('mic', 100 * i, 'rr$i'), isFalse);
      tick();
    }
  });

  test('nothing sent (muted, paused layer) -> nothing', () {
    s('mic', 100, 'rr1');
    for (var i = 0; i < 6; i++) {
      tick();
      expect(s('mic', 105, 'rr1'), isFalse, reason: 'only 5 packets went out');
    }
  });

  // Infinix 2026-10-25 (blr1, host alone in the room): 10 s after the join the
  // SFU paused both camera layers (nobody subscribed), so its receiver reports
  // stopped too. The packets sent between the last report and the pause still
  // counted, and 5 s later the watch resumed a healthy connection, once per join.
  test('layer paused by the server after sending -> nothing (it is not sending now)', () {
    expect(s('cam:h', 1000, 'rr1'), isFalse);
    tick();
    expect(s('cam:h', 1060, 'rr1'), isFalse, reason: '60 packets went out, then the layer was paused');
    for (var i = 0; i < 6; i++) {
      tick();
      expect(s('cam:h', 1060, 'rr1'), isFalse, reason: 'paused: nothing sent since the last sample');
    }
  });

  test('a paused layer resumed while the path is dead -> a resume', () {
    s('cam:h', 1000, 'rr1');
    tick();
    s('cam:h', 1060, 'rr1'); // then paused
    tick();
    s('cam:h', 1060, 'rr1');
    tick();
    expect(s('cam:h', 1200, 'rr1'), isTrue, reason: 'sending again, still no report for 6 s');
  });

  test('no report ever (none to compare) -> nothing', () {
    for (var i = 0; i < 6; i++) {
      expect(s('mic', 100 * i, null), isFalse);
      tick();
    }
  });

  test('another stream still gets reports -> the path is fine, nothing', () {
    s('mic', 100, 'a1');
    s('cam:f', 100, 'v1');
    for (var i = 2; i < 6; i++) {
      tick();
      expect(s('cam:f', 100 * i, 'v$i'), isFalse);
      expect(s('mic', 100 * i, 'a1'), isFalse, reason: 'the camera stream still gets reports');
    }
  });

  test('ineligible (not connected / muted) restarts the clock', () {
    s('mic', 100, 'rr1');
    tick();
    tick();
    s('mic', 300, 'rr1', eligible: false);
    tick();
    expect(s('mic', 400, 'rr1'), isFalse);
    tick();
    expect(s('mic', 500, 'rr1'), isFalse, reason: '4 s since it became eligible again');
    tick();
    expect(s('mic', 600, 'rr1'), isTrue);
  });

  test('at most once per 20 s; reset() (a resume) restarts the clocks', () {
    s('mic', 0, 'rr1');
    tick(6000);
    expect(s('mic', 300, 'rr1'), isTrue);
    tick(6000);
    expect(s('mic', 600, 'rr1'), isFalse, reason: 'within 20 s of the last');
    tick(16000);
    expect(s('mic', 900, 'rr1'), isTrue, reason: '22 s later, still no report');
    w.reset();
    tick(2000);
    expect(s('mic', 1000, 'rr1'), isFalse, reason: 'a fresh clock after the reset');
  });

  test('Duration.zero = off', () {
    s('mic', 0, 'rr1', stallFor: Duration.zero);
    tick(60000);
    expect(s('mic', 3000, 'rr1', stallFor: Duration.zero), isFalse);
  });
}

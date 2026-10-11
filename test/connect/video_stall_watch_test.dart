// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// R1 / S4 decision logic (GravixVideoStallWatch), on a fake clock with the 2 s
// stats cadence of the remote tracks. Field 2026-10-09: packets stopped at
// 03:49:52 and ICE noticed at 03:49:59; after the resume no new video arrived.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_media_watchdog.dart';
import 'package:gravix_rtc/src/rtc_core/src/gravix_recovery_options.dart';

void main() {
  late DateTime now;
  late GravixVideoStallWatch w;
  setUp(() {
    now = DateTime(2026, 10, 9, 21, 49, 50);
    w = GravixVideoStallWatch(options: const GravixRecoveryOptions(), clock: () => now);
  });
  void tick([int ms = 2000]) => now = now.add(Duration(milliseconds: ms));

  GravixStallAction v(num packets, {num frames = 0, bool eligible = true, String sid = 'TR_v'}) =>
      w.sample(sid, video: true, eligible: eligible, packetsReceived: packets, framesDecoded: frames);
  GravixStallAction a(num packets, {bool eligible = true}) =>
      w.sample('TR_a', video: false, eligible: eligible, packetsReceived: packets);

  test('R1: no packet on the video (and none on the audio) for 2 s -> one resume', () {
    expect(v(100), GravixStallAction.none);
    a(50);
    tick();
    a(60);
    expect(v(200), GravixStallAction.none); // flowing
    tick();
    a(60);
    expect(v(200), GravixStallAction.resume, reason: '2 s without a packet');
    tick();
    a(60);
    expect(v(200), GravixStallAction.none, reason: 'not again until media flowed');
  });

  test('R1: audio still flowing = the path is fine (a source stopped): no resume', () {
    v(100);
    a(10);
    tick();
    a(30);
    expect(v(100), GravixStallAction.none);
    tick();
    a(50);
    expect(v(100), GravixStallAction.none);
  });

  test('R1: at most once per 10 s even when media flowed in between', () {
    v(1);
    tick();
    expect(v(1), GravixStallAction.resume);
    tick(1000);
    v(2); // flows again
    tick(2000);
    expect(v(2), GravixStallAction.none, reason: 'within 10 s of the last');
    tick(8000);
    expect(v(2), GravixStallAction.resume);
  });

  test('ineligible (muted / disabled / paused / unsubscribed) never triggers', () {
    v(1, eligible: false);
    for (var i = 0; i < 10; i++) {
      tick();
      expect(v(1, eligible: false), GravixStallAction.none);
    }
    // becoming eligible restarts its clock
    tick();
    expect(v(1), GravixStallAction.none);
  });

  test('S4: after a resume, no new decoded frame for 4 s -> one full rejoin', () {
    v(100, frames: 10);
    tick();
    v(200, frames: 20);
    w.noteResumed();
    tick();
    expect(v(260, frames: 20), GravixStallAction.none, reason: 'packets (stale NACKs) but no new frame, 2 s');
    tick();
    expect(v(300, frames: 20), GravixStallAction.rejoin, reason: '4 s without a new frame');
    // once: the window closed
    tick();
    expect(v(300, frames: 20), isNot(GravixStallAction.rejoin));
  });

  test('S4: frames flowing after the resume = no rejoin; outside the 15 s window = no rejoin', () {
    v(1, frames: 1);
    w.noteResumed();
    for (var i = 2; i < 8; i++) {
      tick();
      expect(v(i * 10, frames: i), GravixStallAction.none);
    }
    // 16 s after the resume the video stops decoding: not S4's case any more
    tick(4000);
    expect(v(500, frames: 7), GravixStallAction.none);
    tick(4000);
    expect(v(600, frames: 7), GravixStallAction.none);
  });

  test('S4: at most one rejoin per 60 s', () {
    v(1, frames: 1);
    w.noteResumed();
    tick(4000);
    expect(v(2, frames: 1), GravixStallAction.rejoin);
    tick(10000);
    w.noteResumed();
    tick(4000);
    expect(v(3, frames: 1), GravixStallAction.none);
    tick(50000);
    w.noteResumed();
    tick(4000);
    expect(v(4, frames: 1), GravixStallAction.rejoin);
  });

  test('switches off', () {
    w.options = const GravixRecoveryOptions(earlyStallDetection: false, noVideoWatchdog: false);
    v(1, frames: 1);
    w.noteResumed();
    for (var i = 0; i < 10; i++) {
      tick();
      expect(v(1, frames: 1), GravixStallAction.none);
    }
  });
}

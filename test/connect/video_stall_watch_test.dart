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
    a(1);
    v(1);
    tick();
    a(1);
    expect(v(1), GravixStallAction.resume);
    tick(1000);
    a(2);
    v(2); // flows again
    tick(2000);
    a(2);
    expect(v(2), GravixStallAction.none, reason: 'within 10 s of the last');
    tick(8000);
    a(2);
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

  // Gulf test 2026-11-04, step b, host in Dhaka: the tester put the app in the background
  // (03:42:20.9), Android stopped its camera (frames frozen 03:42:34-54 on the tester's own
  // outbound stats; the SFU saw the same; no lane died). The tester's mic wasn't up, so that camera
  // was all the host received: "no packet" -> resume -> "no new frame" -> a healthy host did a
  // full rejoin and cut its own audio.
  test('R1: a lone video with nothing to compare it with is one source, not the path', () {
    expect(v(100), GravixStallAction.none);
    tick();
    expect(v(200), GravixStallAction.none);
    tick();
    expect(v(200), GravixStallAction.none, reason: 'the first quiet sample');
    for (var i = 0; i < 6; i++) {
      tick();
      expect(v(200), GravixStallAction.none, reason: 'ICE still watches the path (~7 s)');
    }
  });

  test('R1: a muted mic beside the video does not count as a second source', () {
    expect(v(100), GravixStallAction.none);
    a(50, eligible: false);
    tick();
    a(50, eligible: false);
    expect(v(200), GravixStallAction.none);
    tick();
    a(50, eligible: false);
    expect(v(200), GravixStallAction.none);
  });

  test('S4: another camera decoding after a resume: the path and the server work, no rejoin', () {
    GravixStallAction other(num frames) =>
        w.sample('TR_v2', video: true, eligible: true, packetsReceived: frames * 10, framesDecoded: frames);
    expect(v(100, frames: 10), GravixStallAction.none);
    other(10);
    w.noteResumed();
    for (var i = 0; i < 4; i++) {
      tick();
      other(20 + i);
      expect(v(100, frames: 10), GravixStallAction.none, reason: 'only this publisher stopped');
    }
  });

  test('S4: every camera dead after a resume still rejoins (field 2026-10-09)', () {
    GravixStallAction other() =>
        w.sample('TR_v2', video: true, eligible: true, packetsReceived: 100, framesDecoded: 10);
    expect(v(100, frames: 10), GravixStallAction.none);
    other();
    w.noteResumed();
    var acted = GravixStallAction.none;
    for (var i = 0; i < 4 && acted == GravixStallAction.none; i++) {
      tick();
      acted = other();
      if (acted == GravixStallAction.none) acted = v(100, frames: 10);
    }
    expect(acted, GravixStallAction.rejoin);
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

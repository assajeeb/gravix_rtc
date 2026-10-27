// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-12 (a real Android phone, 6 ms to its SFU, busy main isolate): the
// join's upgrade over the standby connection was read after the 0.5 s floor of
// the upgrade bound (3 x RTT = ~20 ms), the join dialled again
// (stalled_redialed) and paid +1.4 s. GravixStandby.lowRttUpgradeFloor (opt-in)
// raises the floor for an RTT under 30 ms only.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/standby_types.dart';

void main() {
  tearDown(() {
    GravixStandby.lowRttUpgradeFloor = kGravixStandbyLowRttUpgradeFloorDefault;
    gravixStandbyInSignalIsolate = false;
  });

  test('default (0.7.2): an RTT under 30 ms waits 1.5 s', () {
    expect(GravixStandby.lowRttUpgradeFloor, const Duration(milliseconds: 1500));
    expect(gravixStandbyUpgradeBound(6), const Duration(milliseconds: 1500));
    expect(gravixStandbyUpgradeBound(30), const Duration(milliseconds: 500));
  });

  test('off (null): the old floor', () {
    GravixStandby.lowRttUpgradeFloor = null;
    expect(gravixStandbyUpgradeBound(6), const Duration(milliseconds: 500));
    expect(gravixStandbyUpgradeBound(29), const Duration(milliseconds: 500));
    expect(gravixStandbyUpgradeBound(null), const Duration(milliseconds: 1500));
  });

  test('1 s: an RTT under 30 ms waits 1 s; 30 ms and up, and an unknown RTT, as before', () {
    GravixStandby.lowRttUpgradeFloor = const Duration(seconds: 1);
    expect(gravixStandbyUpgradeBound(6), const Duration(milliseconds: 1000));
    expect(gravixStandbyUpgradeBound(29), const Duration(milliseconds: 1000));
    expect(gravixStandbyUpgradeBound(30), const Duration(milliseconds: 500));
    expect(gravixStandbyUpgradeBound(171), const Duration(milliseconds: 513));
    expect(gravixStandbyUpgradeBound(null), const Duration(milliseconds: 1500));
    expect(gravixStandbyUpgradeBound(0), const Duration(milliseconds: 1500), reason: 'no RTT');
  });

  test('never above the upgrade timeout', () {
    GravixStandby.lowRttUpgradeFloor = const Duration(seconds: 3);
    expect(gravixStandbyUpgradeBound(6), kGravixStandbyUpgradeTimeout);
  });

  // Device run B-g 2026-10-15: with the socket in the signal isolate the reply
  // is no longer read late by a busy main isolate (the reason for the 0.5 s
  // floor); a stalled standby now gets its fresh dial after 0.4 s (above the
  // SFU's 65-360 ms join handling in the field data).
  test('in the signal isolate: the floor is 0.4 s; 3 x RTT above it and the cap unchanged', () {
    gravixStandbyInSignalIsolate = true;
    GravixStandby.lowRttUpgradeFloor = null;
    expect(gravixStandbyUpgradeBound(6), const Duration(milliseconds: 400));
    expect(gravixStandbyUpgradeBound(110), const Duration(milliseconds: 400));
    expect(gravixStandbyUpgradeBound(171), const Duration(milliseconds: 513));
    expect(gravixStandbyUpgradeBound(null), const Duration(milliseconds: 1500));
    GravixStandby.lowRttUpgradeFloor = const Duration(seconds: 1);
    expect(gravixStandbyUpgradeBound(6), const Duration(milliseconds: 1000), reason: "the app's opt-in still wins");
  });
}

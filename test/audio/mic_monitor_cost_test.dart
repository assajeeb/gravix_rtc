// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Owner rule (2026-10-10): no fix may slow joining. The mic monitor is attached
// from Room.connect's foreground-service hook; this measures what that adds
// (attach + detach, mocked channel) and the per-event cost of a state refresh.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_mic_state.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/gravix_foreground_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugLkPlatformOverride = PlatformType.android;
    messenger.setMockMethodCallHandler(Native.channel, (call) async => null);
    GravixMicMonitor.instance.resetForTest();
    GravixForegroundService.resetForTest();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Native.channel, null);
    GravixMicMonitor.instance.resetForTest();
    GravixForegroundService.resetForTest();
    debugLkPlatformOverride = null;
  });

  test('roomConnecting + roomReleased (service disabled) cost, and refresh cost', () async {
    const n = 2000;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      final room = Object();
      await GravixForegroundService.roomConnecting(room, null);
      GravixForegroundService.roomReleased(room);
    }
    sw.stop();
    final perJoinUs = sw.elapsedMicroseconds / n;

    GravixMicMonitor.instance.debugMicWanted = true;
    GravixMicMonitor.instance.attachRoom(Object());
    final sw2 = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      GravixMicMonitor.instance.refresh();
    }
    sw2.stop();
    final perRefreshUs = sw2.elapsedMicroseconds / n;
    // ignore: avoid_print
    print(
      'MIC_MONITOR_COST attach+detach=${perJoinUs.toStringAsFixed(1)}us '
      'refresh=${perRefreshUs.toStringAsFixed(2)}us (n=$n, JIT, host)',
    );
    // generous bounds: a join is hundreds of ms; this must stay far below 1 ms
    expect(perJoinUs, lessThan(1000));
    expect(perRefreshUs, lessThan(200));
  });
}

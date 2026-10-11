// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// PERF (2026-10-11, native sub-audit): disposing an AudioVisualizer that was
// started, without calling stop() first, never told the native side. Android
// kept the visualizer's audio sink (an FFT and a main-thread post every 10 ms
// frame, ~100 Hz) until the Flutter engine detached; iOS kept it for the life
// of the process (its plugin has no detach). Upstream has the same gap; the
// SDK's own waveform widget stops before it disposes, an app that only
// disposes did not.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/audio_visualizer.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/remote/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  setUp(() {
    installRecoveryChannelMocks();
    calls = [];
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      return call.method == 'startVisualizer' ? true : null;
    });
  });

  RemoteAudioTrack track() => RemoteAudioTrack(
    TrackSource.microphone,
    FakeMediaStream([]),
    FakeMediaTrack('TR_remote_mic'),
    receiver: FakeReceiver(),
  );

  test('dispose() of a started visualizer stops the native visualizer', () async {
    final v = createVisualizer(track());
    await v.start();
    expect(calls.map((c) => c.method), contains('startVisualizer'));
    await v.dispose();
    final stops = calls.where((c) => c.method == 'stopVisualizer').toList();
    expect(stops, hasLength(1), reason: 'the native sink keeps running (100 Hz) after dispose');
    expect((stops.single.arguments as Map)['visualizerId'], v.visualizerId);
  });

  test('stop() then dispose() stops once; dispose() of a visualizer never started calls nothing', () async {
    final v = createVisualizer(track());
    await v.start();
    await v.stop();
    await v.dispose();
    expect(calls.where((c) => c.method == 'stopVisualizer'), hasLength(1));

    calls.clear();
    final idle = createVisualizer(track());
    await idle.dispose();
    expect(calls.where((c) => c.method.contains('Visualizer')), isEmpty);
  });
}

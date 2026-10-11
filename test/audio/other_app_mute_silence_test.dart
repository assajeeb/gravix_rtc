// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Merge of 2026-10-11 (integ/sdk-2026-10-11): two opt-ins together.
// otherAppAudio: muteMicInBackground mutes the microphone in the audio engine
// (setMicrophoneMute), which zeroes the recorder's frames; silentCaptureDetection
// reads >= 3 s of digital silence as a dead recorder. Before the fix the
// automatic mute was reported as interrupted/silentCapture and the capture was
// restarted. The automatic mute is now treated like the user's own mute: not
// measured, and the silence window restarts when it begins and when it ends.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_audio_device.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_mic_state.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/stats/audio_source_stats.dart';
import 'package:gravix_rtc/src/rtc_core/src/stats/stats.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

class _FakeTrack implements rtc.MediaStreamTrack {
  @override
  bool enabled = true;
  @override
  String? get id => 'mic';
  @override
  String? get kind => 'audio';
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isSetter ? null : super.noSuchMethod(invocation);
}

class _FakeStream implements rtc.MediaStream {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AudioSenderStatsEvent _stats(num energy, num duration) {
  final s = AudioSenderStats('s', 0)
    ..audioSourceStats = AudioSourceStats(
      echoReturnLossEnhancement: null,
      audioLevel: null,
      totalAudioEnergy: energy,
      totalSamplesDuration: duration,
      echoReturnLoss: null,
      trackIdentifier: 'mic',
      remoteSource: false,
    );
  return AudioSenderStatsEvent(stats: s, currentBitrate: 0);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final monitor = GravixMicMonitor.instance;
  late List<MethodCall> calls;
  late LocalAudioTrack track;
  late int restarts;

  void lifecycle(AppLifecycleState s) => binding.handleAppLifecycleStateChanged(s);

  Future<void> otherApp(bool playing) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onOtherAppAudio', {'playing': playing, 'players': playing ? 1 : 0}),
    );
    await messenger.handlePlatformMessage(Native.channel.name, data, (_) {});
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> feed(num energy, num duration) async {
    track.events.emit(_stats(energy, duration));
    await Future<void>.delayed(Duration.zero);
  }

  List<String?> actions() => calls
      .where((c) => c.method == 'setOtherAppCaptureAction')
      .map((c) => (c.arguments as Map)['action'] as String?)
      .toList();

  setUp(() {
    calls = [];
    restarts = 0;
    monitor.resetForTest();
    GravixAudioDevice.options = const GravixAudioDeviceOptions();
    debugLkPlatformOverride = PlatformType.android;
    lifecycle(AppLifecycleState.resumed);
    messenger.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      // API 29: the background needs no call-service microphone type, so the
      // microphone is measured in the background (API 30+: the same with the
      // call service running with that type)
      if (call.method == 'startMicMonitor') return {'sdkInt': 29, 'recording': true, 'silenced': false};
      return null;
    });
    track = LocalAudioTrack(TrackSource.microphone, _FakeStream(), _FakeTrack(), const AudioCaptureOptions());
    monitor.debugMicWanted = true;
    monitor.debugMicTracks = [track];
    monitor.debugRestartCapture = () async => restarts++;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(Native.channel, null);
    monitor.resetForTest();
    GravixAudioDevice.options = const GravixAudioDeviceOptions();
    debugLkPlatformOverride = null;
    lifecycle(AppLifecycleState.resumed);
    await track.events.dispose();
  });

  test('the automatic background mute is not a silent capture (no report, no restart)', () async {
    GravixAudioDevice.options = const GravixAudioDeviceOptions(
      silentCaptureDetection: true,
      otherAppAudio: GravixOtherAppAudioMode.muteMicInBackground,
    );
    monitor.attachRoom(Object());
    await Future<void>.delayed(Duration.zero);
    var e = 0.0;
    await feed(e, 0);
    e += 4e-7;
    await feed(e, 2); // talking
    await otherApp(true);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(actions().last, 'mute');
    // the engine mute zeroes the frames: digital silence for 6 s
    await feed(e, 4);
    await feed(e, 6);
    await feed(e, 8);
    expect(GravixAudioDevice.micState.reason, isNot(GravixMicStateReason.silentCapture));
    expect(GravixAudioDevice.micState.state, GravixMicState.active);
    expect(restarts, 0);
  });

  test('when the automatic mute ends, the window starts over; a real silence is still reported', () async {
    GravixAudioDevice.options = const GravixAudioDeviceOptions(
      silentCaptureDetection: true,
      otherAppAudio: GravixOtherAppAudioMode.muteMicInBackground,
    );
    monitor.attachRoom(Object());
    await Future<void>.delayed(Duration.zero);
    var e = 0.0;
    await feed(e, 0);
    e += 4e-7;
    await feed(e, 2);
    await otherApp(true);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    await feed(e, 4); // muted: zeros
    await feed(e, 6);
    // back in the foreground: the automatic mute ends
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(actions().last, 'none');
    // the first interval after the unmute still covers muted time: not counted
    await feed(e, 7);
    expect(GravixAudioDevice.micState.reason, isNot(GravixMicStateReason.silentCapture));
    expect(restarts, 0);
    // now the recorder really delivers digital silence for >= 3 s
    await feed(e, 9);
    await feed(e, 11);
    expect(GravixAudioDevice.micState.reason, GravixMicStateReason.silentCapture);
    expect(restarts, 1);
  });

  test('detect only (no mute): digital silence in the background is still reported', () async {
    GravixAudioDevice.options = const GravixAudioDeviceOptions(
      silentCaptureDetection: true,
      otherAppAudio: GravixOtherAppAudioMode.detect,
    );
    monitor.attachRoom(Object());
    await Future<void>.delayed(Duration.zero);
    await otherApp(true);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(actions(), isEmpty);
    await feed(0, 0);
    await feed(0, 2);
    await feed(0, 4);
    expect(GravixAudioDevice.micState.reason, GravixMicStateReason.silentCapture);
    expect(restarts, 1);
  });
}

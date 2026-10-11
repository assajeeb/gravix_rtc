// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-10, interruption-sim run: a capture that looks healthy (recording,
// not silenced, published, unmuted) can still deliver DIGITAL silence (an
// emulator mic stall; on phones an OEM recorder that never comes back, or a
// silence the OS does not report). A real microphone always has a noise
// floor. Opt-in detector (default off): the outbound audio source's energy
// from the stats the track already polls (every 2 s, no extra getStats, no
// per-frame copies) below -90 dBFS for >= 3 s -> interrupted / silentCapture.
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

  group('GravixSilenceMeter (pure)', () {
    test('digital silence accumulates; a noise floor resets it', () {
      final m = GravixSilenceMeter();
      expect(m.feed(totalAudioEnergy: 0, totalSamplesDuration: 10), Duration.zero); // baseline
      expect(m.feed(totalAudioEnergy: 0, totalSamplesDuration: 12), const Duration(seconds: 2));
      expect(m.feed(totalAudioEnergy: 0, totalSamplesDuration: 14), const Duration(seconds: 4));
      // a quiet room through a real mic: ~-70 dBFS RMS -> mean square 1e-7
      expect(m.feed(totalAudioEnergy: 2e-7, totalSamplesDuration: 16), Duration.zero);
    });

    test('-90 dBFS is the line (mean square 1e-9)', () {
      final m = GravixSilenceMeter();
      m.feed(totalAudioEnergy: 0, totalSamplesDuration: 0);
      // 2 s at -95 dBFS (mean square ~3.2e-10): silent
      expect(m.feed(totalAudioEnergy: 6.4e-10, totalSamplesDuration: 2), const Duration(seconds: 2));
      // 2 s at -85 dBFS (mean square ~3.2e-9): not silent
      expect(m.feed(totalAudioEnergy: 6.4e-10 + 6.4e-9, totalSamplesDuration: 4), Duration.zero);
    });

    test('no samples flowing (duration did not advance) is not "silent capture"', () {
      final m = GravixSilenceMeter();
      m.feed(totalAudioEnergy: 0, totalSamplesDuration: 5);
      expect(m.feed(totalAudioEnergy: 0, totalSamplesDuration: 5), Duration.zero);
    });

    test('missing fields or a counter reset start over', () {
      final m = GravixSilenceMeter();
      m.feed(totalAudioEnergy: 0, totalSamplesDuration: 5);
      expect(m.feed(totalAudioEnergy: null, totalSamplesDuration: 7), Duration.zero);
      m.feed(totalAudioEnergy: 0, totalSamplesDuration: 9);
      expect(m.feed(totalAudioEnergy: 0, totalSamplesDuration: 1), Duration.zero); // new track/counters
    });

    test('classifier: silentCapture after the platform causes, before active', () {
      const w = GravixMicSignals(micWanted: true, recording: true, silentCapture: true);
      expect(gravixClassifyMic(w), (GravixMicState.interrupted, GravixMicStateReason.silentCapture));
      // an OS-reported cause wins
      expect(gravixClassifyMic(w.copyWith(silenced: true)).$2, GravixMicStateReason.silencedBySystem);
      expect(gravixClassifyMic(w.copyWith(phoneCall: true)).$2, GravixMicStateReason.phoneCall);
      // muted / not published: idle
      expect(gravixClassifyMic(w.copyWith(micWanted: false)).$1, GravixMicState.idle);
    });
  });

  group('monitor wiring (opt-in)', () {
    late List<MethodCall> calls;
    late LocalAudioTrack track;
    late int restarts;

    setUp(() {
      calls = [];
      restarts = 0;
      monitor.resetForTest();
      GravixAudioDevice.options = const GravixAudioDeviceOptions();
      debugLkPlatformOverride = PlatformType.android;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      messenger.setMockMethodCallHandler(Native.channel, (call) async {
        calls.add(call);
        if (call.method == 'startMicMonitor') return {'sdkInt': 35, 'recording': true, 'silenced': false};
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
      await track.events.dispose();
    });

    Future<void> feed(num e, num d) async {
      track.events.emit(_stats(e, d));
      await Future<void>.delayed(Duration.zero);
    }

    test('off (default): digital silence is not reported', () async {
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      for (var t = 0; t <= 8; t += 2) {
        await feed(0, t);
      }
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
    });

    test(
      'on: >= 3 s of digital silence -> interrupted/silentCapture, one restart; the noise floor clears it',
      () async {
        GravixAudioDevice.options = const GravixAudioDeviceOptions(silentCaptureDetection: true);
        monitor.attachRoom(Object());
        await Future<void>.delayed(Duration.zero);
        await feed(0, 0);
        await feed(0, 2);
        expect(GravixAudioDevice.micState.state, GravixMicState.active, reason: '2 s is not yet 3 s');
        await feed(0, 4);
        expect(GravixAudioDevice.micState.reason, GravixMicStateReason.silentCapture);
        expect(restarts, 1);
        // still silent: no second restart within 30 s
        await feed(0, 6);
        await feed(0, 8);
        expect(restarts, 1);
        // the mic is back (a noise floor)
        await feed(2e-7, 10);
        expect(GravixAudioDevice.micState.state, GravixMicState.active);
        // no audio-session re-assert for this cause (nothing reprogrammed it)
        expect(calls.map((c) => c.method), isNot(contains('reassertAudioSession')));
      },
    );

    // Phone run 2026-10-10 (Xiaomi, f079209, XA_cell_f_media / XA_wa_f_media):
    // after a cellular and a WhatsApp call the SDK reported
    // interrupted/silentCapture for 1.5-2 s, then active: the stats window
    // still covered the call's silenced (zeroed) capture.
    Future<void> signals(Map<String, Object?> m) async {
      final data = const StandardMethodCodec().encodeMethodCall(MethodCall('onMicSignals', m));
      await messenger.handlePlatformMessage(Native.channel.name, data, (_) {});
      await Future<void>.delayed(Duration.zero);
    }

    test('a call-shaped sequence never reports silentCapture', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(silentCaptureDetection: true);
      var now = DateTime.utc(2026, 10, 10, 14);
      monitor.debugNow = () => now;
      final seen = <GravixMicStateEvent>[];
      final sub = GravixAudioDevice.micStateChanges.listen(seen.add);
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      Future<void> at(int t, num energy) async {
        now = DateTime.utc(2026, 10, 10, 14).add(Duration(seconds: t));
        await feed(energy, t);
      }

      var e = 0.0;
      await at(0, e);
      e += 4e-7;
      await at(2, e); // talking
      // the call rings and is answered: the OS takes the mic, our frames are zeros
      await signals({'sdkInt': 35, 'recording': true, 'silenced': true, 'phoneCall': true, 'focus': 'lossTransient'});
      await at(4, e);
      await at(6, e);
      await at(8, e);
      // hang up; the OS lifts the silence, the capture re-opens
      now = DateTime.utc(2026, 10, 10, 14, 0, 9);
      await signals({'sdkInt': 35, 'recording': true, 'silenced': false, 'phoneCall': false, 'focus': 'gain'});
      await at(10, e); // this window still covers the end of the call's zeros
      e += 4e-7;
      await at(12, e); // voice back
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen.map((x) => x.reason), isNot(contains(GravixMicStateReason.silentCapture)));
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      await sub.cancel();
    });

    test('real digital silence after a call is still reported once a fresh window shows it', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(silentCaptureDetection: true);
      var now = DateTime.utc(2026, 10, 10, 14);
      monitor.debugNow = () => now;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      Future<void> at(int t) async {
        now = DateTime.utc(2026, 10, 10, 14).add(Duration(seconds: t));
        await feed(0, t);
      }

      await signals({'sdkInt': 35, 'recording': true, 'silenced': true, 'phoneCall': true});
      await at(2);
      await at(4);
      now = DateTime.utc(2026, 10, 10, 14, 0, 5);
      await signals({'sdkInt': 35, 'recording': true, 'silenced': false, 'phoneCall': false});
      await at(6); // baseline after the call
      await at(8); // 2 s fresh silence
      expect(GravixAudioDevice.micState.state, GravixMicState.active);
      await at(10); // 4 s fresh silence, 5 s after the call ended
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.silentCapture);
    });

    test('on, recoverMicAfterInterruption false: reported, not restarted', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(
        silentCaptureDetection: true,
        recoverMicAfterInterruption: false,
      );
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      for (var t = 0; t <= 4; t += 2) {
        await feed(0, t);
      }
      expect(GravixAudioDevice.micState.reason, GravixMicStateReason.silentCapture);
      expect(restarts, 0);
    });

    test('muted (not wanted): never silentCapture', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(silentCaptureDetection: true);
      monitor.debugMicWanted = false;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      for (var t = 0; t <= 6; t += 2) {
        await feed(0, t);
      }
      expect(GravixAudioDevice.micState.state, GravixMicState.idle);
    });

    test('cost: one stats event (per 2 s) is handled in microseconds', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(silentCaptureDetection: true);
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      const n = 5000;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        monitor.debugFeedSourceStats(track, totalAudioEnergy: 2e-7 * i, totalSamplesDuration: 2.0 * i);
      }
      sw.stop();
      final perEventUs = sw.elapsedMicroseconds / n;
      // ignore: avoid_print
      print('SILENT_CAPTURE_COST per stats event=${perEventUs.toStringAsFixed(2)}us (n=$n, host JIT)');
      expect(perEventUs, lessThan(200));
    });
  });

  test('option default off', () {
    expect(const GravixAudioDeviceOptions().silentCaptureDetection, isFalse);
  });
}

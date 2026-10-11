// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Other-app audio (owner report 2026-10-10): "a user is in a room with the mic
// on; if he plays YouTube or a game with sound, the microphone sends that sound
// too". In the media profile (MIC source, software AEC3) the echo canceller's
// reference is only WebRTC's own playout, so another app's audio on the
// loudspeaker goes to the room. The SDK can now see it (Android playback
// callback) and, per GravixAudioDeviceOptions.otherAppAudio, tell the app or
// act on the capture while it lasts. Default off = no monitor, no call.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_audio_device.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_mic_state.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_other_app_audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/managers/gravix_foreground_service.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/platform.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final monitor = GravixMicMonitor.instance;
  late List<MethodCall> calls;

  void lifecycle(AppLifecycleState s) => binding.handleAppLifecycleStateChanged(s);

  Future<void> otherApp(bool playing, {int players = 1}) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onOtherAppAudio', {'playing': playing, 'players': playing ? players : 0}),
    );
    await messenger.handlePlatformMessage(Native.channel.name, data, (_) {});
    await Future<void>.delayed(Duration.zero);
  }

  List<String> methods() => calls.map((c) => c.method).toList();
  List<String?> actions() => calls
      .where((c) => c.method == 'setOtherAppCaptureAction')
      .map((c) => (c.arguments as Map)['action'] as String?)
      .toList();

  setUp(() {
    calls = [];
    monitor.resetForTest();
    GravixForegroundService.resetForTest();
    GravixAudioDevice.options = const GravixAudioDeviceOptions();
    debugLkPlatformOverride = PlatformType.android;
    lifecycle(AppLifecycleState.resumed);
    messenger.setMockMethodCallHandler(Native.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'startMicMonitor':
          return {'sdkInt': 34, 'recording': true, 'silenced': false, 'focus': 'gain', 'phoneCall': false};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(Native.channel, null);
    monitor.resetForTest();
    GravixForegroundService.resetForTest();
    GravixAudioDevice.options = const GravixAudioDeviceOptions();
    debugLkPlatformOverride = null;
  });

  group('options', () {
    test('default is off (the old behaviour)', () {
      expect(const GravixAudioDeviceOptions().otherAppAudio, GravixOtherAppAudioMode.off);
    });

    test('copyWith / == / hashCode carry the mode', () {
      const a = GravixAudioDeviceOptions(otherAppAudio: GravixOtherAppAudioMode.detect);
      expect(a.copyWith(), a);
      expect(a.copyWith(otherAppAudio: GravixOtherAppAudioMode.off), const GravixAudioDeviceOptions());
      expect(a.hashCode, const GravixAudioDeviceOptions(otherAppAudio: GravixOtherAppAudioMode.detect).hashCode);
      expect(a.toString(), contains('otherAppAudio: detect'));
    });
  });

  group('gravixOtherAppCaptureAction', () {
    GravixOtherAppCaptureAction act(
      GravixOtherAppAudioMode mode, {
      bool playing = true,
      bool mic = true,
      bool bg = false,
    }) => gravixOtherAppCaptureAction(mode: mode, otherAppPlaying: playing, micWanted: mic, backgrounded: bg);

    test('off and detect never touch the capture', () {
      for (final m in [GravixOtherAppAudioMode.off, GravixOtherAppAudioMode.detect]) {
        expect(act(m), GravixOtherAppCaptureAction.none);
        expect(act(m, bg: true), GravixOtherAppCaptureAction.none);
      }
    });

    test('platformEffects / voiceCommunicationCapture: only while another app plays and our mic is live', () {
      expect(act(GravixOtherAppAudioMode.platformEffects), GravixOtherAppCaptureAction.platformEffects);
      expect(act(GravixOtherAppAudioMode.voiceCommunicationCapture), GravixOtherAppCaptureAction.voiceCommunication);
      for (final m in [GravixOtherAppAudioMode.platformEffects, GravixOtherAppAudioMode.voiceCommunicationCapture]) {
        expect(act(m, playing: false), GravixOtherAppCaptureAction.none);
        expect(act(m, mic: false), GravixOtherAppCaptureAction.none);
      }
    });

    test('muteMicInBackground: only in the background', () {
      expect(act(GravixOtherAppAudioMode.muteMicInBackground), GravixOtherAppCaptureAction.none);
      expect(act(GravixOtherAppAudioMode.muteMicInBackground, bg: true), GravixOtherAppCaptureAction.mute);
      expect(
        act(GravixOtherAppAudioMode.muteMicInBackground, bg: true, playing: false),
        GravixOtherAppCaptureAction.none,
      );
      expect(act(GravixOtherAppAudioMode.muteMicInBackground, bg: true, mic: false), GravixOtherAppCaptureAction.none);
    });
  });

  group('monitor', () {
    test('off (default): the native watcher is never started, no capture call', () async {
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await otherApp(true);
      expect(methods(), isNot(contains('startOtherAppAudioMonitor')));
      expect(methods(), isNot(contains('setOtherAppCaptureAction')));
      // the event still is not reported: nothing watches
      expect(GravixAudioDevice.otherAppAudioPlaying, isFalse);
    });

    test('detect: watcher runs only while a room is attached; events reach the app; capture untouched', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(otherAppAudio: GravixOtherAppAudioMode.detect);
      final seen = <bool>[];
      final sub = GravixAudioDevice.otherAppAudioPlayingChanged.listen(seen.add);
      final room = Object();
      monitor.debugMicWanted = true;
      monitor.attachRoom(room);
      await Future<void>.delayed(Duration.zero);
      expect(methods(), contains('startOtherAppAudioMonitor'));
      await otherApp(true, players: 2);
      expect(GravixAudioDevice.otherAppAudioPlaying, isTrue);
      await otherApp(true, players: 1); // same state: no second event
      await otherApp(false);
      expect(seen, [true, false]);
      expect(actions().where((a) => a != 'none'), isEmpty);
      monitor.detachRoom(room);
      await Future<void>.delayed(Duration.zero);
      expect(methods(), contains('stopOtherAppAudioMonitor'));
      expect(GravixAudioDevice.otherAppAudioPlaying, isFalse);
      await sub.cancel();
    });

    test('platformEffects: applied while another app plays with the mic live, released when it stops', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(
        otherAppAudio: GravixOtherAppAudioMode.platformEffects,
      );
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await otherApp(true);
      expect(actions().last, 'platformEffects');
      await otherApp(false);
      expect(actions().last, 'none');
      // one call per change, not per refresh
      monitor.refresh();
      monitor.refresh();
      expect(actions(), ['platformEffects', 'none']);
    });

    test('voiceCommunicationCapture: mic muted -> released; unmuted again -> applied', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(
        otherAppAudio: GravixOtherAppAudioMode.voiceCommunicationCapture,
      );
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await otherApp(true);
      expect(actions().last, 'voiceCommunication');
      monitor.debugMicWanted = false;
      monitor.refresh();
      expect(actions().last, 'none');
      monitor.debugMicWanted = true;
      monitor.refresh();
      expect(actions(), ['voiceCommunication', 'none', 'voiceCommunication']);
    });

    test('muteMicInBackground: mutes only in the background, unmutes on return', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(
        otherAppAudio: GravixOtherAppAudioMode.muteMicInBackground,
      );
      monitor.debugMicWanted = true;
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      await otherApp(true);
      expect(actions().where((a) => a == 'mute'), isEmpty);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(actions().last, 'mute');
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(actions().last, 'none');
    });

    test('room left while an action is applied: the capture is restored', () async {
      GravixAudioDevice.options = const GravixAudioDeviceOptions(
        otherAppAudio: GravixOtherAppAudioMode.platformEffects,
      );
      final room = Object();
      monitor.debugMicWanted = true;
      monitor.attachRoom(room);
      await Future<void>.delayed(Duration.zero);
      await otherApp(true);
      expect(actions().last, 'platformEffects');
      monitor.detachRoom(room);
      await Future<void>.delayed(Duration.zero);
      expect(actions().last, 'none');
    });

    test('not Android: nothing starts', () async {
      debugLkPlatformOverride = PlatformType.iOS;
      GravixAudioDevice.options = const GravixAudioDeviceOptions(otherAppAudio: GravixOtherAppAudioMode.detect);
      monitor.attachRoom(Object());
      await Future<void>.delayed(Duration.zero);
      expect(methods(), isNot(contains('startOtherAppAudioMonitor')));
    });
  });
}

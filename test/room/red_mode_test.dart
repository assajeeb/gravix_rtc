// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// RED doubled the audio upload in the field (2026-09-30: ~125 vs ~50 kbps). The mode
// is now a connect option: on (default), off, or auto (on once the uplink is lossy).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GravixRedAuto', () {
    test('four lossy 5 s windows in a row (20 s) switch RED on, once', () {
      final a = GravixRedAuto(thresholdPct: 3);
      expect(a.feed(0, 0), isFalse); // baseline
      expect(a.feed(250, 10), isFalse); // 3.8 %: first lossy window
      expect(a.lastLossPct, closeTo(3.85, 0.01));
      expect(a.feed(500, 20), isFalse);
      expect(a.feed(750, 30), isFalse);
      expect(a.feed(1000, 40), isTrue); // fourth
      expect(a.fired, isTrue);
      expect(a.feed(1250, 80), isFalse, reason: 'once per call');
    });

    test('a clean window resets the count (a roam / handover burst does not fire)', () {
      final a = GravixRedAuto(thresholdPct: 3);
      a.feed(0, 0);
      expect(a.feed(250, 10), isFalse);
      expect(a.feed(500, 20), isFalse);
      expect(a.feed(750, 30), isFalse);
      expect(a.feed(1000, 31), isFalse); // 0.4 %: reset
      expect(a.feed(1250, 41), isFalse); // lossy again, first
      expect(a.fired, isFalse);
    });

    test('an RTT above 1.5 s blocks it (bufferbloat: RED would add to the queue)', () {
      final a = GravixRedAuto(thresholdPct: 3);
      a.feed(0, 0);
      for (var i = 1; i <= 8; i++) {
        expect(a.feed(250 * i, 10 * i, rttMs: 2200), isFalse);
      }
      expect(a.fired, isFalse);
    });

    test('too few packets (muted / DTX) or missing counters say nothing', () {
      final a = GravixRedAuto(thresholdPct: 3);
      a.feed(0, 0);
      expect(a.feed(10, 5), isFalse);
      expect(a.lastLossPct, isNull);
      expect(a.feed(null, 5), isFalse);
      expect(a.feed(20, 10), isFalse);
      expect(a.fired, isFalse);
    });
  });

  group('connect(red:)', () {
    setUp(() {
      GravixAudioRouting.v2 = false;
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
      );
      m.setMockMethodCallHandler(const MethodChannel('gravity.music_mixer'), (call) async => true);
      m.setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);
      for (final name in const ['com.ryanheise.android_audio_manager', 'com.ryanheise.av_audio_session']) {
        m.setMockMethodCallHandler(
          MethodChannel(name),
          (call) async => switch (call.method) {
            'getDevices' => <dynamic>[],
            'getMode' => 0,
            'isBluetoothScoOn' => false,
            _ => null,
          },
        );
      }
    });

    Future<bool?> redOf(GravixRedMode? mode) async {
      final s = GravixRoomService(connectRoom: (room, url, token) async {}, applyMic: (_) async {});
      if (mode == null) {
        await s.connect(url: 'wss://a.example', token: 't');
      } else {
        await s.connect(url: 'wss://a.example', token: 't', red: mode);
      }
      final red = s.room?.roomOptions.defaultAudioPublishOptions.red;
      expect(s.redMode, mode ?? GravixRedMode.on);
      await s.disconnect();
      return red;
    }

    test('default: on (unchanged)', () async => expect(await redOf(null), isTrue));
    test('off', () async => expect(await redOf(GravixRedMode.off), isFalse));
    test('auto starts without RED', () async => expect(await redOf(GravixRedMode.auto), isFalse));
  });
}

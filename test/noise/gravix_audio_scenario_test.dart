// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// GravixAudioScenario.chatRoom (Agora ChatRoom parity, 2026-10-22): the
// WebRTC initialize options it adds and the AGC it turns off.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

class _FakeNative implements GravixNsNative {
  final calls = <Map<String, dynamic>>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<Map<String, dynamic>?> deviceFacts() async => {
    'model': 'x',
    'abi': 'arm64-v8a',
    'ramMb': 3644,
    'osBuild': 'x',
    'studioAvailable': false,
  };
  @override
  Future<Map<String, dynamic>?> benchmark(int budgetUs) async => null;
  @override
  Future<String?> readBenchmarkCache() async => null;
  @override
  Future<void> writeBenchmarkCache(String json) async {}
  @override
  Future<Map<String, dynamic>?> configure(Map<String, dynamic> args) async {
    calls.add(args);
    return {'ok': true, 'installed': true, 'route': 'speaker', 'rate': 16000};
  }

  @override
  Future<Map<String, dynamic>?> stats() async => null;
  @override
  Stream<Map<String, Object?>> get events => _events.stream;
}

const _base = AudioCaptureOptions(echoCancellation: true, noiseSuppression: true, autoGainControl: true);

void main() {
  tearDown(() => gravixUseAudioScenario(GravixAudioScenario.standard));

  group('initialize options', () {
    test('standard adds nothing', () {
      expect(gravixUseAudioScenario(GravixAudioScenario.standard), isEmpty);
      expect(gravixAudioScenario, GravixAudioScenario.standard);
    });

    test('chatRoom: communication profile, platform AEC, 16 kHz capture, 48 kHz playout', () {
      final o = gravixUseAudioScenario(GravixAudioScenario.chatRoom);
      expect(gravixAudioScenario, GravixAudioScenario.chatRoom);
      expect((o['androidAudioConfiguration'] as Map)['androidAudioMode'], 'inCommunication');
      expect(o['androidUseHardwareAudioProcessing'], isTrue);
      expect(o['audioSampleRate'], 16000);
      expect(o['audioOutputSampleRate'], 48000);
      expect(o.containsKey('bypassVoiceProcessing'), isFalse);
    });
  });

  group('AGC', () {
    test('agcOrder none: WebRTC AGC off as well', () {
      final o = gravixNsCaptureOptions(
        _base,
        const GravixNoiseSuppressionOptions(agcOrder: GravixNsAgcOrder.none),
        GravixNsEngine.rnnoise,
      );
      expect(o.autoGainControl, isFalse);
      expect(o.noiseSuppression, isFalse);
      expect(o.echoCancellation, isTrue);
    });

    test('chatRoom turns the default AGC off (native agcOrder none)', () async {
      gravixUseAudioScenario(GravixAudioScenario.chatRoom);
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(const GravixNoiseSuppressionOptions());
      expect(n.calls.single['agcOrder'], 'none');
      expect(c.adjustCapture(_base).autoGainControl, isFalse);
    });

    test('chatRoom keeps an explicit webrtcBeforeNs', () async {
      gravixUseAudioScenario(GravixAudioScenario.chatRoom);
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(const GravixNoiseSuppressionOptions(agcOrder: GravixNsAgcOrder.webrtcBeforeNs));
      expect(n.calls.single['agcOrder'], 'webrtcBeforeNs');
    });

    test('standard keeps ownAfterNs', () async {
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(const GravixNoiseSuppressionOptions());
      expect(n.calls.single['agcOrder'], 'ownAfterNs');
    });
  });
}

// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/noise/noise.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rnnoise = GravixNsResolution(engine: GravixNsEngine.rnnoise, reason: GravixNsReason.modeStandard);
  const dfn3 = GravixNsResolution(engine: GravixNsEngine.dfn3, reason: GravixNsReason.modeStudio);

  group('gravixNsConfigureArgs', () {
    test('defaults: ownAfterNs -> our AGC on, thresholds in us', () {
      final a = gravixNsConfigureArgs(const GravixNoiseSuppressionOptions(), rnnoise);
      expect(a['engine'], 'rnnoise');
      expect(a['agcOrder'], 'ownAfterNs');
      expect(a['agc'], true);
      expect(a['musicBypass'], true);
      expect(a['watchdogUs'], 8000);
      expect(a['watchdogConsecutive'], 3);
      expect(a['benchmarkP95Us'], 3000);
      expect(a['studioModel'], 'std');
      expect(a['studioDownload'], 'unmeteredIdle');
      expect(a.containsKey('benchmarkCachedP95Us'), false);
      expect(a['studioAttenLimitDb'], 40);
      expect(a['studioP95BudgetUs'], 3000);
      expect(a['studioP95WindowMs'], 2000);
      expect(a['studioLowLatency'], false);
    });

    test('LL is opt-in: without studioLowLatency the standard model is used', () {
      final a = gravixNsConfigureArgs(
        const GravixNoiseSuppressionOptions(),
        dfn3,
        studioModel: 'll',
        studioLlUrl: 'https://example.invalid/ll.zip',
      );
      expect(a['studioModel'], 'std');
      expect(a['studioLlUrl'], isNull);
      final b = gravixNsConfigureArgs(
        const GravixNoiseSuppressionOptions(studioAttenLimitDb: 0, studioP95Budget: Duration.zero),
        dfn3,
      );
      expect(b['studioAttenLimitDb'], 0);
      expect(b['studioP95BudgetUs'], 0);
    });

    test('webrtcBeforeNs -> our AGC off; off engine name', () {
      final a = gravixNsConfigureArgs(
        const GravixNoiseSuppressionOptions(agcOrder: GravixNsAgcOrder.webrtcBeforeNs),
        const GravixNsResolution(engine: GravixNsEngine.none, reason: GravixNsReason.modeOff),
      );
      expect(a['agc'], false);
      expect(a['engine'], 'off');
    });

    test('off / kill switch -> our AGC off even with ownAfterNs (review #1)', () {
      for (final reason in [GravixNsReason.modeOff, GravixNsReason.killSwitch]) {
        final a = gravixNsConfigureArgs(
          const GravixNoiseSuppressionOptions(),
          GravixNsResolution(engine: GravixNsEngine.none, reason: reason),
        );
        expect(a['engine'], 'off');
        expect(a['agcOrder'], 'ownAfterNs');
        expect(a['agc'], false, reason: reason);
      }
    });

    test('studio ll + cached benchmark (only when output was ok)', () {
      final ok = gravixNsConfigureArgs(
        const GravixNoiseSuppressionOptions(studioLowLatency: true),
        dfn3,
        cachedBenchmark: const GravixNsBenchmark(key: 'k', p95Us: 900, outputOk: true),
        studioModel: 'll',
        studioLlUrl: 'https://example.invalid/ll.zip',
      );
      expect(ok['engine'], 'dfn3');
      expect(ok['benchmarkCachedP95Us'], 900);
      expect(ok['studioModel'], 'll');
      expect(ok['studioLlUrl'], 'https://example.invalid/ll.zip');
      final bad = gravixNsConfigureArgs(
        const GravixNoiseSuppressionOptions(),
        dfn3,
        cachedBenchmark: const GravixNsBenchmark(key: 'k', p95Us: 900, outputOk: false),
      );
      expect(bad.containsKey('benchmarkCachedP95Us'), false);
    });
  });

  group('gravixNsWebRtcProcessing', () {
    const comm = AudioProcessingOptions.communication();

    test('ownAfterNs: WebRTC NS + AGC off, AEC/HPF kept', () {
      final p = gravixNsWebRtcProcessing(comm, const GravixNoiseSuppressionOptions(), GravixNsEngine.rnnoise);
      expect(p.noiseSuppression, false);
      expect(p.autoGainControl, false);
      expect(p.echoCancellation, comm.echoCancellation);
      expect(p.highPassFilter, comm.highPassFilter);
    });

    test('webrtcBeforeNs keeps WebRTC AGC; disableWebRtcNs=false keeps NS', () {
      final p = gravixNsWebRtcProcessing(
        comm,
        const GravixNoiseSuppressionOptions(agcOrder: GravixNsAgcOrder.webrtcBeforeNs, disableWebRtcNs: false),
        GravixNsEngine.dfn3,
      );
      expect(p.noiseSuppression, comm.noiseSuppression);
      expect(p.autoGainControl, comm.autoGainControl);
    });

    test('engine off -> unchanged', () {
      final p = gravixNsWebRtcProcessing(comm, const GravixNoiseSuppressionOptions(), GravixNsEngine.none);
      expect(identical(p, comm), true);
    });
  });

  group('GravixNoiseNative channel', () {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(Native.channel, null));

    test('no native side -> null, never throws', () async {
      messenger.setMockMethodCallHandler(Native.channel, null);
      expect(await GravixNoiseNative.getState(), isNull);
      expect(await GravixNoiseNative.configure({'engine': 'rnnoise'}), isNull);
      await GravixNoiseNative.setMusicBypass(true);
    });

    test('configure passes args and returns the state map', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(Native.channel, (call) async {
        seen = call;
        return {'platform': 'ios', 'active': 'rnnoise', 'rate': 48000};
      });
      final s = await GravixNoiseNative.configure(
        gravixNsConfigureArgs(const GravixNoiseSuppressionOptions(), rnnoise),
      );
      expect(seen!.method, 'nsConfigure');
      expect((seen!.arguments as Map)['engine'], 'rnnoise');
      expect(s!['active'], 'rnnoise');
    });

    test('Unimplemented -> null', () async {
      messenger.setMockMethodCallHandler(Native.channel, (call) async {
        throw PlatformException(code: 'Unimplemented');
      });
      expect(await GravixNoiseNative.getState(), isNull);
    });

    test('onNsEvent from native reaches the events stream', () async {
      final next = GravixNoiseNative.events.first;
      final codec = Native.channel.codec;
      await messenger.handlePlatformMessage(
        Native.channel.name,
        codec.encodeMethodCall(
          const MethodCall('onNsEvent', {
            'type': 'engineChanged',
            'from': 'dfn3',
            'to': 'rnnoise',
            'reason': 'watchdog',
          }),
        ),
        (_) {},
      );
      final e = await next;
      expect(e['type'], 'engineChanged');
      expect(e['reason'], 'watchdog');
    });
  });
}

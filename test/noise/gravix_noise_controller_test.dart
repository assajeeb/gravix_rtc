// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// WebRTC processing while our NS runs (decided before the capture) and the
// runtime controller against a fake native side.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/noise/gravix_noise_native.dart'
    show gravixNsNormalizeConfigureReply, gravixNsNormalizeIosEvent, gravixNsFlattenIosState;

class _FakeNative implements GravixNsNative {
  _FakeNative({
    this.reply = const {'ok': true, 'installed': true, 'route': 'speaker', 'rate': 48000},
    this.studio = false,
    this.bench,
    this.cache,
  });

  final Map<String, dynamic>? reply;
  final bool studio;
  final Map<String, dynamic>? bench;
  String? cache;
  int benchCalls = 0;
  final calls = <Map<String, dynamic>>[];
  int factsCalls = 0;
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<Map<String, dynamic>?> deviceFacts() async {
    factsCalls++;
    return {
      'model': '23127PN0CG',
      'manufacturer': 'Xiaomi',
      'abi': 'arm64-v8a',
      'ramMb': 8192,
      'osBuild': 'Xiaomi/x/x:14/UKQ1',
      'studioAvailable': studio,
      if (studio) 'studioSha': '0e4c4f4fc2c5f564528419957267f017fb3d0fc8f1bc33765d06dca67230e14d',
      if (studio) 'studioRuntime': 'ort-1.31.0',
      if (studio) 'studioModel': 'std',
    };
  }

  @override
  Future<Map<String, dynamic>?> benchmark(int budgetUs) async {
    benchCalls++;
    return bench;
  }

  @override
  Future<String?> readBenchmarkCache() async => cache;

  @override
  Future<void> writeBenchmarkCache(String json) async => cache = json;

  @override
  Future<Map<String, dynamic>?> configure(Map<String, dynamic> args) async {
    calls.add(args);
    return reply;
  }

  @override
  Future<Map<String, dynamic>?> stats() async => {'p50Us': 300, 'p95Us': 450, 'over': 0, 'eng': 'rnnoise'};

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  void emit(Map<String, Object?> e) => _events.add(e);
}

const _base = AudioCaptureOptions(
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
  highPassFilter: true,
);

void main() {
  group('gravixNsProcessing (before capture)', () {
    const ns = GravixNoiseSuppressionOptions();

    test('not ours -> unchanged', () {
      for (final e in [GravixNsEngine.none, GravixNsEngine.browser]) {
        final o = gravixNsCaptureOptions(_base, ns, e);
        expect(o.noiseSuppression, isTrue);
        expect(o.autoGainControl, isTrue);
      }
    });

    test('ownAfterNs (default): WebRTC NS and AGC off, AEC + HPF kept', () {
      final o = gravixNsCaptureOptions(_base, ns, GravixNsEngine.rnnoise);
      expect(o.noiseSuppression, isFalse);
      expect(o.autoGainControl, isFalse);
      expect(o.echoCancellation, isTrue);
      expect(o.highPassFilter, isTrue);
      expect(o.stopAudioCaptureOnMute, _base.stopAudioCaptureOnMute);
    });

    test('webrtcBeforeNs: NS off, WebRTC AGC kept', () {
      final o = gravixNsCaptureOptions(
        _base,
        ns.copyWith(agcOrder: GravixNsAgcOrder.webrtcBeforeNs),
        GravixNsEngine.rnnoise,
      );
      expect(o.noiseSuppression, isFalse);
      expect(o.autoGainControl, isTrue);
    });

    test('hardwareNs on: platform NS only', () {
      final o = gravixNsCaptureOptions(_base, ns.copyWith(hardwareNs: GravixHwNs.on), GravixNsEngine.rnnoise);
      expect(o.noiseSuppression, isTrue);
      expect(o.noiseSuppressionMode, AudioProcessingMode.platform);
    });

    test('disableWebRtcNs false keeps WebRTC NS', () {
      final o = gravixNsCaptureOptions(_base, ns.copyWith(disableWebRtcNs: false), GravixNsEngine.dfn3);
      expect(o.noiseSuppression, isTrue);
      expect(o.noiseSuppressionMode, AudioProcessingMode.automatic);
    });

    test('an app that turned NS off keeps it off (hardwareNs on does not turn it on)', () {
      final o = gravixNsCaptureOptions(
        _base.copyWith(noiseSuppression: false),
        ns.copyWith(hardwareNs: GravixHwNs.on),
        GravixNsEngine.rnnoise,
      );
      expect(o.noiseSuppression, isFalse);
    });

    test('music relax is a no-op once ours runs (NS and AGC already off)', () {
      final p = gravixNsProcessing(_base.processing, ns, GravixNsEngine.rnnoise);
      expect(!p.noiseSuppression && !p.autoGainControl, isTrue);
    });
  });

  group('GravixNoiseSuppression controller', () {
    test('unconfigured / legacy: capture untouched, no native call', () async {
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n);
      expect(c.adjustCapture(_base).noiseSuppression, isTrue);
      await c.configure(null);
      expect(n.calls, isEmpty);
      expect(c.adjustCapture(_base).noiseSuppression, isTrue);
    });

    test('auto on Android resolves to rnnoise (no studio pack) and configures native', () async {
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n);
      final s = await c.configure(const GravixNoiseSuppressionOptions());
      expect(s.engine, GravixNsEngine.rnnoise);
      expect(s.reason, GravixNsReason.studioUnavailable);
      expect(s.installed, isTrue);
      expect(s.route, GravixNsRoute.speaker);
      expect(s.rate, 48000);
      expect(n.calls.single['engine'], 'rnnoise');
      expect(n.calls.single['agcOrder'], 'ownAfterNs');
      expect(n.calls.single['musicBypass'], isTrue);
      expect(n.calls.single['watchdogFrameUs'], 8000);
      final o = c.adjustCapture(_base);
      expect(o.noiseSuppression, isFalse);
      expect(o.autoGainControl, isFalse);
    });

    test('studio without the pack -> rnnoise studio_unavailable', () async {
      final c = GravixNoiseSuppression.forTesting(_FakeNative());
      final s = await c.configure(const GravixNoiseSuppressionOptions(mode: GravixNoiseSuppressionMode.studio));
      expect(s.engine, GravixNsEngine.rnnoise);
      expect(s.reason, GravixNsReason.studioUnavailable);
    });

    test('native unavailable: engine none, WebRTC NS left as is', () async {
      final c = GravixNoiseSuppression.forTesting(_FakeNative(reply: {'ok': false, 'reason': 'library_missing'}));
      final s = await c.configure(const GravixNoiseSuppressionOptions(mode: GravixNoiseSuppressionMode.standard));
      expect(s.engine, GravixNsEngine.none);
      expect(s.reason, 'library_missing');
      expect(c.adjustCapture(_base).noiseSuppression, isTrue);
    });

    test('no native implementation (null reply) -> native_unavailable', () async {
      final c = GravixNoiseSuppression.forTesting(_FakeNative(reply: null));
      final s = await c.configure(const GravixNoiseSuppressionOptions(mode: GravixNoiseSuppressionMode.standard));
      expect(s.reason, GravixNsReason.nativeUnavailable);
      expect(c.adjustCapture(_base).noiseSuppression, isTrue);
    });

    test('web / other: platform_unsupported, capture untouched, no native call', () async {
      for (final p in ['web', 'other']) {
        final n = _FakeNative();
        final c = GravixNoiseSuppression.forTesting(n, platform: p);
        final s = await c.configure(const GravixNoiseSuppressionOptions());
        expect(s.engine, GravixNsEngine.none);
        expect(s.reason, GravixNsReason.platformUnsupported);
        expect(n.calls, isEmpty);
        expect(c.adjustCapture(_base).noiseSuppression, isTrue);
      }
    });

    test('kill switch policy -> none', () async {
      final c = GravixNoiseSuppression.forTesting(_FakeNative());
      final policy = gravixParseNsPolicy({
        'version': 1,
        'killSwitch': {'all': true},
      }).policy;
      final s = await c.configure(GravixNoiseSuppressionOptions(policy: policy));
      expect(s.engine, GravixNsEngine.none);
      expect(s.reason, GravixNsReason.killSwitch);
      expect(c.adjustCapture(_base).noiseSuppression, isTrue);
    });

    test('setMode off then standard; device facts fetched once', () async {
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(const GravixNoiseSuppressionOptions());
      var s = await c.setMode(GravixNoiseSuppressionMode.off);
      expect(s.engine, GravixNsEngine.none);
      expect(n.calls.last['engine'], 'off');
      s = await c.setMode(GravixNoiseSuppressionMode.standard);
      expect(s.engine, GravixNsEngine.rnnoise);
      expect(s.reason, GravixNsReason.modeStandard);
      expect(n.factsCalls, 3); // re-read per apply (the studio model can change)
    });

    test('music bypass (audible eng=off) does not bring WebRTC NS back on a new capture', () async {
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(const GravixNoiseSuppressionOptions());
      n.emit({'step': 'musicBypass', 'eng': 'off', 'reason': 'music_bypass', 'musicBypass': true});
      await Future<void>.delayed(Duration.zero);
      expect(c.state.value.engine, GravixNsEngine.none);
      final o = c.adjustCapture(_base);
      expect(o.noiseSuppression, isFalse);
      expect(o.autoGainControl, isFalse);
    });

    test('native events update the state and reach onReport', () async {
      final n = _FakeNative();
      final reports = <GravixNsReport>[];
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(GravixNoiseSuppressionOptions(onReport: reports.add));
      n.emit({'step': 'routeReset', 'eng': 'rnnoise', 'reason': 'route', 'route': 'earpiece', 'rate': 48000});
      n.emit({'step': 'musicBypass', 'eng': 'rnnoise', 'reason': 'music_bypass', 'musicBypass': true});
      await Future<void>.delayed(Duration.zero);
      expect(c.state.value.route, GravixNsRoute.earpiece);
      expect(c.state.value.musicBypass, isTrue);
      expect(reports.map((r) => r.step), containsAllInOrder(['init', 'routeReset', 'musicBypass']));
      final s = await c.refreshStats();
      expect(s.p95Us, 450);
    });
  });

  group('iOS through the same controller', () {
    test('iOS: rnnoise, iOS keys sent, WebRTC NS + AGC off for ownAfterNs', () async {
      final n = _FakeNative(
        reply: gravixNsNormalizeConfigureReply({
          'platform': 'ios',
          'installed': true,
          'enabled': true,
          'requested': 'rnnoise',
          'active': 'rnnoise',
          'route': 'speaker',
          'rate': 48000,
        }),
      );
      final c = GravixNoiseSuppression.forTesting(n, platform: 'ios');
      final s = await c.configure(
        const GravixNoiseSuppressionOptions(studioPackUrl: 'https://cdn.example/ns/v1/', studioLowLatency: true),
      );
      expect(s.engine, GravixNsEngine.rnnoise);
      expect(s.installed, isTrue);
      final a = n.calls.single;
      expect(a['agc'], isTrue);
      expect(a['watchdogUs'], 8000);
      expect(a['studioModel'], 'll');
      expect(a['studioLlUrl'], 'https://cdn.example/ns/v1/dfn3_ll_int8.mlpackage.zip');
      expect(a['studioLowLatency'], true);
      expect(a['studioAttenLimitDb'], 40);
      expect(a['studioP95BudgetUs'], 3000);
      expect(a['studioP95WindowMs'], 2000);
      final o = c.adjustCapture(_base);
      expect(o.noiseSuppression, isFalse);
      expect(o.autoGainControl, isFalse);
      expect(o.echoCancellation, isTrue);
    });

    test('iOS: kill switch sends agc=false (no own AGC next to WebRTC AGC)', () async {
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n, platform: 'ios');
      await c.configure(const GravixNoiseSuppressionOptions());
      expect(n.calls.last['agc'], isTrue);
      final policy = gravixParseNsPolicy({
        'version': 1,
        'killSwitch': {'all': true},
      }).policy;
      await c.configure(GravixNoiseSuppressionOptions(policy: policy));
      expect(n.calls.last['engine'], 'off');
      expect(n.calls.last['agc'], isFalse);
      await c.setMode(GravixNoiseSuppressionMode.off);
      expect(n.calls.last['engine'], 'off');
      expect(n.calls.last['agc'], isFalse);
    });

    test('iOS: LL is opt-in -- a pack URL alone keeps the standard model', () async {
      final n = _FakeNative(
        reply: gravixNsNormalizeConfigureReply({
          'platform': 'ios',
          'installed': true,
          'enabled': true,
          'requested': 'rnnoise',
          'active': 'rnnoise',
          'route': 'speaker',
          'rate': 48000,
        }),
      );
      final c = GravixNoiseSuppression.forTesting(n, platform: 'ios');
      await c.configure(const GravixNoiseSuppressionOptions(studioPackUrl: 'https://cdn.example/ns/v1/'));
      final a = n.calls.single;
      expect(a['studioModel'], 'std');
      expect(a['studioLlUrl'], isNull);
      expect(a['studioLowLatency'], false);
    });

    test('iOS create failure -> none, capture untouched', () async {
      final n = _FakeNative(
        reply: gravixNsNormalizeConfigureReply({
          'platform': 'ios',
          'installed': true,
          'enabled': false,
          'requested': 'rnnoise',
          'active': 'off',
        }),
      );
      final c = GravixNoiseSuppression.forTesting(n, platform: 'ios');
      final s = await c.configure(const GravixNoiseSuppressionOptions(mode: GravixNoiseSuppressionMode.standard));
      expect(s.engine, GravixNsEngine.none);
      expect(s.reason, 'create_failed');
      expect(c.adjustCapture(_base).noiseSuppression, isTrue);
    });

    test('iOS events are normalized to the shared shape', () {
      expect(
        gravixNsNormalizeIosEvent({'type': 'engineChanged', 'from': 'dfn3', 'to': 'rnnoise', 'reason': 'thermal'}),
        containsPair('eng', 'rnnoise'),
      );
      expect(gravixNsNormalizeIosEvent({'type': 'musicBypass', 'on': true}), containsPair('musicBypass', true));
      expect(gravixNsNormalizeIosEvent({'type': 'routeReset', 'route': 'bt-sco'})['step'], 'routeReset');
      final flat = gravixNsFlattenIosState({
        'active': 'rnnoise',
        'route': 'speaker',
        'rate': 48000,
        'stats': {'p50Us': 200, 'p95Us': 310, 'overBudget': 0},
      })!;
      expect(flat['p95Us'], 310);
      expect(flat['eng'], 'rnnoise');
    });
  });

  group('studio (DFN3 bundled) benchmark', () {
    const fast = {'ok': true, 'model': 'std', 'p95Us': 900, 'outputOk': true, 'paritySnrDb': 42.0};

    test('auto: RNNoise while the benchmark runs, then dfn3 with the chosen model', () async {
      final n = _FakeNative(studio: true, bench: fast);
      final c = GravixNoiseSuppression.forTesting(n);
      final s = await c.configure(const GravixNoiseSuppressionOptions());
      expect(s.engine, GravixNsEngine.rnnoise);
      expect(s.reason, GravixNsReason.benchmarkPending);
      await c.benchmarkDone;
      expect(n.benchCalls, 1);
      expect(c.state.value.engine, GravixNsEngine.dfn3);
      expect(c.state.value.reason, GravixNsReason.autoCapable);
      expect(n.calls.last['engine'], 'dfn3');
      expect(n.calls.last['studioModel'], 'std');
      expect(n.cache, contains('"p95Us":900'));
    });

    test('cached benchmark with the same key: no re-run, dfn3 at once', () async {
      final first = _FakeNative(studio: true, bench: fast);
      final c1 = GravixNoiseSuppression.forTesting(first);
      await c1.configure(const GravixNoiseSuppressionOptions());
      await c1.benchmarkDone;
      final n = _FakeNative(studio: true, bench: fast, cache: first.cache);
      final c = GravixNoiseSuppression.forTesting(n);
      final s = await c.configure(const GravixNoiseSuppressionOptions());
      expect(s.engine, GravixNsEngine.dfn3);
      expect(n.benchCalls, 0);
    });

    test('auto slow -> benchmark_slow; studio slow -> studio_too_slow', () async {
      const slow = {'ok': true, 'model': 'std', 'p95Us': 4200, 'outputOk': true};
      final n = _FakeNative(studio: true, bench: slow);
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(const GravixNoiseSuppressionOptions());
      await c.benchmarkDone;
      expect(c.state.value.engine, GravixNsEngine.rnnoise);
      expect(c.state.value.reason, GravixNsReason.benchmarkSlow);
      final s = await c.setMode(GravixNoiseSuppressionMode.studio);
      expect(s.engine, GravixNsEngine.rnnoise);
      expect(s.reason, GravixNsReason.studioTooSlow);
    });

    test('a failed benchmark counts as bad output and is not re-run', () async {
      final n = _FakeNative(studio: true, bench: {'ok': false, 'reason': 'load_failed'});
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(const GravixNoiseSuppressionOptions());
      await c.benchmarkDone;
      expect(c.state.value.reason, GravixNsReason.benchmarkBadOutput);
      await c.configure(const GravixNoiseSuppressionOptions());
      await c.benchmarkDone;
      expect(n.benchCalls, 1);
    });

    test('studio pack options reach native', () async {
      final n = _FakeNative();
      final c = GravixNoiseSuppression.forTesting(n);
      await c.configure(const GravixNoiseSuppressionOptions(studioPackUrl: 'https://cdn.example/ns/v1/'));
      expect(n.calls.single['studioPackUrl'], 'https://cdn.example/ns/v1/');
      expect(n.calls.single['studioSource'], 'auto');
      expect(n.calls.single['studioDownload'], 'unmeteredIdle');
    });
  });
}

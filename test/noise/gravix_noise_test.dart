// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// On-device noise suppression, platform-independent core (2026-10-21): options
// and defaults, remote policy parser, engine resolver, [GravixNS] log lines and
// the benchmark cache key. The shared fixture test/fixtures/ns_policy_cases.json
// is the same file in the React SDK; both must resolve it identically.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart' show RoomOptions, GravixRoomService;
import 'package:gravix_rtc/src/noise/noise.dart';

final _fixture = json.decode(File('test/fixtures/ns_policy_cases.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _map(Object? o) => Map<String, dynamic>.from(o as Map);

void main() {
  group('defaults (shared fixture)', () {
    final d = _map(_fixture['defaults']);
    const o = GravixNoiseSuppressionOptions();
    test('options match the fixture', () {
      expect(o.mode.name, d['mode']);
      expect(o.agcOrder.name, d['agcOrder']);
      expect(o.disableWebRtcNs, d['disableWebRtcNs']);
      expect(o.hardwareNs.name, d['hardwareNs']);
      expect(o.headsetNs.name, d['headsetNs']);
      expect(o.musicBypass, d['musicBypass']);
      expect(o.studioDownload.name, d['studioDownload']);
      expect(o.studioSource.name, d['studioSource']);
      expect(o.benchmarkP95.inMicroseconds, d['benchmarkP95Us']);
      expect(o.watchdogFrame.inMilliseconds, d['watchdogFrameMs']);
      expect(o.watchdogConsecutive, d['watchdogConsecutive']);
      expect(o.thermalFallback, d['thermalFallback']);
      expect(o.batterySaverFallback, d['batterySaverFallback']);
      expect(o.studioAttenLimitDb, d['studioAttenLimitDb']);
      expect(o.studioP95Budget.inMicroseconds, d['studioP95BudgetUs']);
      expect(o.studioP95Window.inMilliseconds, d['studioP95WindowMs']);
      expect(o.studioLowLatency, d['studioLowLatency']);
      expect(kGravixNsDefaultStudioAttenLimitDb, d['studioAttenLimitDb']);
      expect(o.policy, isNull);
      expect(o.policyUrl, isNull);
    });
    test('on by default in every entry point; explicit off still works', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(d['enabledByDefault'], isTrue);
      expect(const RoomOptions().noiseSuppression?.mode.name, d['mode']);
      expect(GravixRoomService().noiseSuppression?.mode.name, d['mode']);
      expect(
        const RoomOptions(noiseSuppression: GravixNoiseSuppressionOptions.off).noiseSuppression?.mode,
        GravixNoiseSuppressionMode.off,
      );
      expect(const RoomOptions(noiseSuppression: null).noiseSuppression, isNull);
      expect(
        GravixRoomService(noiseSuppression: GravixNoiseSuppressionOptions.off).noiseSuppression?.mode,
        GravixNoiseSuppressionMode.off,
      );
    });
    test('the AGC order default is the one constant', () {
      expect(kGravixNsDefaultAgcOrder.name, d['agcOrder']);
      expect(o.agcOrder, kGravixNsDefaultAgcOrder);
      expect(GravixNoiseSuppressionOptions.legacy.mode, GravixNoiseSuppressionMode.off);
      expect(GravixNoiseSuppressionOptions.legacy.agcOrder, kGravixNsDefaultAgcOrder);
    });
    test('copyWith keeps the rest', () {
      final c = o.copyWith(mode: GravixNoiseSuppressionMode.studio, watchdogConsecutive: 5);
      expect(c.mode, GravixNoiseSuppressionMode.studio);
      expect(c.watchdogConsecutive, 5);
      expect(c.agcOrder, o.agcOrder);
      expect(c.benchmarkP95, o.benchmarkP95);
    });
    test('names round-trip', () {
      for (final m in GravixNoiseSuppressionMode.values) {
        expect(gravixNsModeFromName(gravixNsModeName(m)), m);
      }
      for (final e in GravixNsEngine.values) {
        expect(gravixNsEngineFromName(gravixNsEngineName(e)), e);
      }
      expect(gravixNsEngineName(GravixNsEngine.none), 'off');
      expect(gravixNsModeFromName('loud'), isNull);
    });
  });

  final policies = <String, GravixNsPolicy>{
    for (final e in _map(_fixture['policies']).entries) e.key: gravixParseNsPolicy(e.value).policy!,
  };

  test('mid-call studio fallback reasons match the C core names', () {
    // gx_ns_reason_name(): GX_NS_REASON_EXT_SLOW / GX_NS_REASON_EXT_SUPPRESS
    expect(GravixNsReason.studioSlow, 'studio_slow');
    expect(GravixNsReason.studioSuppress, 'studio_suppress');
  });

  group('resolver (shared fixture)', () {
    for (final c in [for (final c in _fixture['resolve'] as List) _map(c)]) {
      test(c['name'] as String, () {
        final bench = c['benchmark'] == null ? null : GravixNsBenchmark.fromJson(_map(c['benchmark']));
        final r = gravixResolveNs(
          mode: gravixNsModeFromName(c['mode'] as String)!,
          facts: GravixNsDeviceFacts.fromJson(_map(c['facts'])),
          policy: c['policy'] == null ? null : policies[c['policy']]!,
          benchmark: bench,
          benchmarkKey: c['benchmarkKey'] as String?,
          studioAvailable: c['studioAvailable'] as bool,
          benchmarkP95: Duration(microseconds: (c['benchmarkP95Us'] as int?) ?? 3000),
        );
        expect(r.toJson(), _map(c['expect']));
      });
    }
  });

  group('policy parser (shared fixture)', () {
    for (final c in [for (final c in _fixture['parse'] as List) _map(c)]) {
      test(c['name'] as String, () {
        final r = gravixParseNsPolicy(c['source']);
        final e = _map(c['expect']);
        if (e['ok'] != true) {
          expect(r.policy, isNull);
          expect(r.error, startsWith(e['error'] as String));
          return;
        }
        expect(r.error, isNull);
        final p = r.policy!;
        expect(p.killAll, e['killAll']);
        expect(p.killStudio, e['killStudio']);
        expect(p.studioAllow.length, e['studioAllow']);
        expect(p.studioDeny.length, e['studioDeny']);
        expect(p.standardDeny.length, e['standardDeny']);
        expect(r.skippedRules, e['skipped']);
        expect(p.thresholds?.benchmarkP95Us, e['benchmarkP95Us']);
      });
    }
    test('toJson round-trips', () {
      final p = policies['fleet']!;
      final again = gravixParseNsPolicy(json.encode(p.toJson())).policy!;
      expect(again.toJson(), p.toJson());
    });
  });

  group('log lines (shared fixture)', () {
    for (final c in [for (final c in _fixture['log'] as List) _map(c)]) {
      test(c['expect'] as String, () {
        String? detail = c['detail'] as String?;
        if (c['switch'] != null) {
          final s = _map(c['switch']);
          detail = gravixNsSwitchDetail(
            gravixNsEngineFromName(s['from'] as String)!,
            gravixNsEngineFromName(s['to'] as String)!,
            s['reason'] as String,
          );
        }
        if (c['summary'] != null) {
          final s = _map(c['summary']);
          detail = gravixNsSummaryDetail(
            p50Us: s['p50Us'] as int,
            p95Us: s['p95Us'] as int,
            p99Us: s['p99Us'] as int,
            maxUs: s['maxUs'] as int,
            overBudget: s['overBudget'] as int,
            cpuPercent: (s['cpuPercent'] as num?)?.toDouble(),
          );
        }
        final line = gravixNsLogLine(
          c['step'] as String,
          engine: gravixNsEngineFromName(c['engine'] as String)!,
          route: gravixNsRouteFromName(c['route'] as String?),
          rate: c['rate'] as int?,
          elapsed: c['elapsedMs'] == null ? null : Duration(milliseconds: c['elapsedMs'] as int),
          detail: detail,
        );
        expect(line, c['expect']);
      });
    }
    test('route names round-trip', () {
      for (final r in GravixNsRoute.values) {
        expect(gravixNsRouteFromName(gravixNsRouteName(r)), r);
      }
    });
  });

  group('benchmark key + iOS chip (shared fixture)', () {
    for (final c in [for (final c in _fixture['benchmarkKey'] as List) _map(c)]) {
      test(c['expect'] as String, () {
        final i = _map(c['input']);
        expect(
          gravixNsBenchmarkKey(
            sdkVersion: i['sdkVersion'] as String,
            modelSha256: i['modelSha256'] as String,
            runtimeVersion: i['runtimeVersion'] as String,
            osBuild: i['osBuild'] as String,
          ),
          c['expect'],
        );
      });
    }
    for (final c in _fixture['iosChip'] as List) {
      test('${c[0]} -> ${c[1]}', () => expect(gravixIosChipFromModel(c[0] as String), c[1]));
    }
  });

  group('policy rules', () {
    test('glob, case and versions', () {
      final r = GravixNsRule.fromJson({'platform': 'Android', 'model': 'SM-S9*', 'osMin': '13', 'osMax': '14.1'})!;
      expect(r.matches(platform: 'android', model: 'sm-s918b', osVersion: '14'), isTrue);
      expect(r.matches(platform: 'android', model: 'sm-s918b', osVersion: '14.1.0'), isTrue);
      expect(r.matches(platform: 'android', model: 'sm-s918b', osVersion: '14.2'), isFalse);
      expect(r.matches(platform: 'android', model: 'sm-s918b', osVersion: '12'), isFalse);
      expect(
        r.matches(platform: 'android', model: 'sm-s918b'),
        isFalse,
        reason: 'os range set, os unknown',
      );
      expect(r.matches(platform: 'ios', model: 'sm-s918b', osVersion: '14'), isFalse);
      expect(r.matches(platform: 'android', model: 'pixel 8', osVersion: '14'), isFalse);
      final any = GravixNsRule.fromJson({'platform': '*'})!;
      expect(any.matches(platform: 'web'), isTrue);
      expect(gravixNsCompareVersions('17.4', '17.4.0'), 0);
      expect(gravixNsCompareVersions('x', '1'), isNull);
    });
  });

  test('report toJson carries wire names', () {
    const r = GravixNsReport(
      step: GravixNsStep.summary,
      mode: GravixNoiseSuppressionMode.auto,
      engine: GravixNsEngine.none,
      reason: GravixNsReason.modeOff,
      route: GravixNsRoute.btSco,
      p95Us: 120,
    );
    expect(r.toJson(), {
      'step': 'summary',
      'mode': 'auto',
      'engine': 'off',
      'reason': 'mode_off',
      'route': 'bt-sco',
      'p95Us': 120,
    });
  });
}

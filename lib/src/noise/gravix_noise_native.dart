// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// Native bridge for on-device noise suppression (shared by Android and iOS).
//
// Channel `gravix_client` (the plugin's existing channel), methods:
//   nsConfigure(map)          -> state map   (see [gravixNsConfigureArgs])
//   nsSetMusicBypass({on})    -> null        (iOS bypasses natively from the music mixer too)
//   nsGetState()              -> state map   (requested, active, reason, rate, route, stats{...})
// Native -> Dart: onNsEvent(map) with `type` = engineChanged | benchmark |
//   download | routeReset | musicBypass.
// A platform without the native side answers MissingPluginException /
// `Unimplemented`: every call here then returns null and never throws.

import 'dart:async';

import 'package:flutter/services.dart' show MissingPluginException, PlatformException;

import '../rtc_core/src/support/native.dart';
import '../rtc_core/src/track/options.dart';
import 'gravix_noise_capture.dart';
import 'gravix_noise_options.dart';
import 'gravix_noise_resolver.dart';

/// Arguments of `nsConfigure`, built from the options and the resolver's
/// decision (pure; unit-tested).
///
/// [studioModel]: `std` (bundled DFN3 standard) or `ll` (downloaded
/// low-latency pack from [studioLlUrl]; SHA-256 is compiled into the native
/// SDK). [cachedBenchmark] skips the native benchmark when its key matches.
Map<String, Object?> gravixNsConfigureArgs(
  GravixNoiseSuppressionOptions options,
  GravixNsResolution resolution, {
  GravixNsBenchmark? cachedBenchmark,
  String studioModel = 'std',
  String? studioLlUrl,
  String studioComputeUnits = 'cpuOnly',
}) {
  // off / kill switch: WebRTC's AGC is back on, ours must not stack on it
  final agcOwn = options.agcOrder == GravixNsAgcOrder.ownAfterNs && gravixNsIsOurs(resolution.engine);
  return <String, Object?>{
    'engine': gravixNsEngineName(resolution.engine),
    'reason': resolution.reason,
    'agcOrder': options.agcOrder.name,
    'agc': agcOwn,
    'musicBypass': options.musicBypass,
    'watchdogUs': options.watchdogFrame.inMicroseconds,
    'watchdogConsecutive': options.watchdogConsecutive,
    'thermalFallback': options.thermalFallback,
    'batterySaverFallback': options.batterySaverFallback,
    'benchmarkP95Us': options.benchmarkP95.inMicroseconds,
    'studioAttenLimitDb': options.studioAttenLimitDb,
    'studioP95BudgetUs': options.studioP95Budget.inMicroseconds,
    'studioP95WindowMs': options.studioP95Window.inMilliseconds,
    'studioLowLatency': options.studioLowLatency,
    if (cachedBenchmark != null && cachedBenchmark.outputOk) 'benchmarkCachedP95Us': cachedBenchmark.p95Us,
    'studioModel': options.studioLowLatency ? studioModel : 'std',
    'studioLlUrl': options.studioLowLatency ? studioLlUrl : null,
    'studioDownload': options.studioDownload.name,
    'studioComputeUnits': studioComputeUnits,
    'hardwareNs': options.hardwareNs.name,
  };
}

/// WebRTC processing to apply on the local audio track while ours runs
/// (plan §1c/§1d): software NS off when [GravixNoiseSuppressionOptions.disableWebRtcNs];
/// WebRTC AGC off for `ownAfterNs` (ours runs after NS), kept for
/// `webrtcBeforeNs`. AEC and the high-pass filter are untouched. With our
/// engine off, [current] is returned unchanged.
///
/// iOS: VPIO's own NS cannot be switched off alone (only the whole voice
/// processing unit, which also removes AEC), so ours runs after Apple's NS.
AudioProcessingOptions gravixNsWebRtcProcessing(
  AudioProcessingOptions current,
  GravixNoiseSuppressionOptions options,
  GravixNsEngine engine,
) => gravixNsProcessing(current, options, engine);

/// iOS `onNsEvent` (`type` = engineChanged | benchmark | download | routeReset |
/// musicBypass) in the Android `onNoiseSuppression` shape (`step`, `eng`, ...),
/// so one controller reads both.
Map<String, Object?> gravixNsNormalizeIosEvent(Map<String, Object?> e) {
  final out = <String, Object?>{...e};
  switch (e['type']) {
    case 'engineChanged':
      out['step'] = 'switch';
      out['eng'] = e['to'];
    case 'benchmark':
      out['step'] = 'bench';
    case 'download':
      out['step'] = 'pack';
    case 'routeReset':
      out['step'] = 'routeReset';
    case 'musicBypass':
      out['step'] = 'musicBypass';
      out['musicBypass'] = e['on'] == true;
    default:
      out['step'] = e['type'] ?? 'event';
  }
  return out;
}

/// Thin wrapper over the native NS methods.
class GravixNoiseNative {
  GravixNoiseNative._();

  static final StreamController<Map<String, Object?>> _events = StreamController.broadcast();

  /// Native events (`onNsEvent`).
  static Stream<Map<String, Object?>> get events => _events.stream;

  /// Called by the channel handler for `onNsEvent`.
  static void handleEvent(Object? args) {
    if (args is Map) _events.add(args.cast<String, Object?>());
  }

  static Future<Map<String, Object?>?> configure(Map<String, Object?> args) => _call('nsConfigure', args);

  static Future<void> setMusicBypass(bool on) async {
    await _call('nsSetMusicBypass', {'on': on});
  }

  static Future<Map<String, Object?>?> getState() => _call('nsGetState', const {});

  static Future<Map<String, Object?>?> _call(String method, Map<String, Object?> args) async {
    try {
      final r = await Native.channel.invokeMethod<Object?>(method, args);
      return r is Map ? r.cast<String, Object?>() : null;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      if (e.code == 'Unimplemented') return null;
      rethrow;
    }
  }
}

/// `nsConfigure` reply in one shape. Android: `{ok, installed, engine, reason,
/// route, rate}`; iOS: its state map (`platform: ios`, `active`, `installed`,
/// `route`, `rate`, ...) without `ok`: a reply at all means the native side
/// took it (a failed iOS create logs and stays pass-through: `enabled` false
/// while an engine was asked for).
Map<String, dynamic>? gravixNsNormalizeConfigureReply(Map<String, dynamic>? r) {
  if (r == null || r['platform'] != 'ios') return r;
  final requested = r['requested'] as String?;
  final enabled = r['enabled'] == true;
  return {...r, 'ok': requested == 'off' || enabled, if (!(requested == 'off' || enabled)) 'reason': 'create_failed'};
}

/// iOS `nsGetState` -> the flat `nsStats` shape.
Map<String, dynamic>? gravixNsFlattenIosState(Map<String, dynamic>? r) {
  if (r == null) return null;
  final st = r['stats'] is Map ? (r['stats'] as Map).cast<String, Object?>() : const <String, Object?>{};
  return {
    'eng': r['active'],
    'reason': r['reason'],
    'route': r['route'],
    'rate': r['rate'],
    'musicBypass': r['musicActive'],
    'p50Us': st['p50Us'],
    'p95Us': st['p95Us'],
    'p99Us': st['p99Us'],
    'maxUs': st['maxUs'],
    'over': st['overBudget'],
  };
}

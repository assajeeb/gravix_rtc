// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// Runtime controller for on-device noise suppression (plan §3). One per
// process: the native processor sits on the single capture stream of the
// audio device module.
//
// configure() runs before the microphone is created (RoomOptions /
// GravixRoomService), so the WebRTC processing it implies is part of the
// capture options (gravix_noise_capture.dart). Android only for now (Phase
// 2a); elsewhere the state is `none / platform_unsupported` and the capture
// options are left exactly as they were.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connect/gravix_join_timeline.dart' show kGravixSdkVersion;

import '../rtc_core/src/support/native.dart';
import '../rtc_core/src/track/local/audio.dart';
import '../rtc_core/src/track/options.dart';
import 'gravix_noise_capture.dart';
import 'gravix_noise_native.dart' show gravixNsNormalizeConfigureReply, gravixNsFlattenIosState;
import 'gravix_noise_options.dart';
import 'gravix_noise_report.dart';
import 'gravix_noise_resolver.dart';

/// Live state (ValueListenable on [GravixNoiseSuppression.state]).
@immutable
class GravixNsState {
  const GravixNsState({
    this.mode = GravixNoiseSuppressionMode.off,
    this.engine = GravixNsEngine.none,
    this.reason = GravixNsReason.modeOff,
    this.route = GravixNsRoute.unknown,
    this.rate,
    this.installed = false,
    this.musicBypass = false,
    this.p50Us,
    this.p95Us,
    this.overBudget,
  });

  /// What the app asked for.
  final GravixNoiseSuppressionMode mode;

  /// The engine producing the audio now.
  final GravixNsEngine engine;

  /// Why ([GravixNsReason] or a native reason such as `watchdog_frame`).
  final String reason;
  final GravixNsRoute route;

  /// APM capture rate seen by the processor (null before the first frame).
  final int? rate;

  /// The native processor is on the capture path.
  final bool installed;

  /// Room music is playing: the chain is bypassed (dry).
  final bool musicBypass;

  /// Frame time of the processor, last stats window (us).
  final int? p50Us;
  final int? p95Us;
  final int? overBudget;

  GravixNsState copyWith({
    GravixNoiseSuppressionMode? mode,
    GravixNsEngine? engine,
    String? reason,
    GravixNsRoute? route,
    int? rate,
    bool? installed,
    bool? musicBypass,
    int? p50Us,
    int? p95Us,
    int? overBudget,
  }) => GravixNsState(
    mode: mode ?? this.mode,
    engine: engine ?? this.engine,
    reason: reason ?? this.reason,
    route: route ?? this.route,
    rate: rate ?? this.rate,
    installed: installed ?? this.installed,
    musicBypass: musicBypass ?? this.musicBypass,
    p50Us: p50Us ?? this.p50Us,
    p95Us: p95Us ?? this.p95Us,
    overBudget: overBudget ?? this.overBudget,
  );

  @override
  bool operator ==(Object other) =>
      other is GravixNsState &&
      other.mode == mode &&
      other.engine == engine &&
      other.reason == reason &&
      other.route == route &&
      other.rate == rate &&
      other.installed == installed &&
      other.musicBypass == musicBypass &&
      other.p50Us == p50Us &&
      other.p95Us == p95Us &&
      other.overBudget == overBudget;

  @override
  int get hashCode => Object.hash(mode, engine, reason, route, rate, installed, musicBypass, p50Us, p95Us, overBudget);

  @override
  String toString() =>
      'GravixNsState(mode=${mode.name} eng=${gravixNsEngineName(engine)} reason=$reason '
      'route=${gravixNsRouteName(route)} rate=${rate ?? '?'} installed=$installed music=$musicBypass p95=${p95Us ?? '-'})';
}

/// The native side, a seam for tests.
abstract class GravixNsNative {
  /// Device facts for the resolver (`GravixNsDeviceFacts.fromJson` shape), or null.
  Future<Map<String, dynamic>?> deviceFacts();

  /// Applies the resolved configuration; returns `{installed, ok, reason?, route?, rate?}`.
  /// Null = no native implementation on this platform.
  Future<Map<String, dynamic>?> configure(Map<String, dynamic> args);

  /// `{p50Us, p95Us, p99Us, maxUs, over, frames, engine, reason, route, rate}` or null.
  Future<Map<String, dynamic>?> stats();

  /// Native events (`{step, eng, reason, route, rate, from, to, ...}`).
  Stream<Map<String, Object?>> get events;

  /// Studio first-run benchmark (background, seconds):
  /// `{ok, model, sha256, p50Us, p95Us, outputOk, paritySnrDb, reason?}`.
  Future<Map<String, dynamic>?> benchmark(int budgetUs);

  /// Persistent benchmark cache (one JSON value).
  Future<String?> readBenchmarkCache();
  Future<void> writeBenchmarkCache(String json);
}

class _ChannelNsNative implements GravixNsNative {
  @override
  Future<Map<String, dynamic>?> deviceFacts() => Native.nsCall('nsDeviceFacts');

  @override
  Future<Map<String, dynamic>?> configure(Map<String, dynamic> args) async =>
      gravixNsNormalizeConfigureReply(await Native.nsCall('nsConfigure', args));

  @override
  Future<Map<String, dynamic>?> stats() async {
    // Android: nsStats (flat); iOS: nsGetState (stats nested)
    final m = await Native.nsCall('nsStats');
    if (m != null) return m;
    return gravixNsFlattenIosState(await Native.nsCall('nsGetState'));
  }

  @override
  Stream<Map<String, Object?>> get events => Native.noiseSuppressionEvents;

  @override
  Future<Map<String, dynamic>?> benchmark(int budgetUs) => Native.nsCall('nsBenchmark', {'budgetUs': budgetUs});

  // v2 (2026-10-21): the studio benchmark gained the quiet-mic check (pre-gain);
  // results cached by older builds never ran it.
  static const _cacheKey = 'gravix_ns_benchmark_v2';

  @override
  Future<String?> readBenchmarkCache() async => (await SharedPreferences.getInstance()).getString(_cacheKey);

  @override
  Future<void> writeBenchmarkCache(String json) async =>
      (await SharedPreferences.getInstance()).setString(_cacheKey, json);
}

/// On-device noise suppression controller.
class GravixNoiseSuppression {
  GravixNoiseSuppression._(this._native, this._platform);

  /// Tests: a fake native side and platform (`android` | `ios` | `web` | `other`).
  @visibleForTesting
  factory GravixNoiseSuppression.forTesting(GravixNsNative native, {String platform = 'android'}) =>
      GravixNoiseSuppression._(native, platform);

  static final GravixNoiseSuppression instance = GravixNoiseSuppression._(_ChannelNsNative(), _currentPlatform());

  static String _currentPlatform() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => 'other',
    };
  }

  /// Platforms with a native processor today.
  static const supportedPlatforms = {'android', 'ios'};

  final GravixNsNative _native;
  final String _platform;
  final ValueNotifier<GravixNsState> _state = ValueNotifier(const GravixNsState());
  GravixNoiseSuppressionOptions? _options;
  Map<String, dynamic>? _facts;

  /// The engine the last configure/setMode resolved to. Decides WebRTC's
  /// processing of new captures; [state] shows the AUDIBLE engine, which is
  /// `off` during a music bypass or a route reset fade.
  GravixNsEngine _resolvedEngine = GravixNsEngine.none;
  Map<String, dynamic>? _bench; // {key, p95Us, outputOk, model}
  bool _benchLoaded = false;
  Future<void>? _benchRun;
  StreamSubscription<Map<String, Object?>>? _eventsSub;
  final Expando<AudioProcessingOptions> _trackBase = Expando('gravixNsBase');
  final List<WeakReference<LocalAudioTrack>> _tracks = [];

  /// Live state.
  ValueListenable<GravixNsState> get state => _state;

  /// The options of the last [configure] (null = not configured / legacy).
  GravixNoiseSuppressionOptions? get options => _options;

  /// The argument of the last [configure] ([setMode] does not change it). A
  /// join configures only when its options differ from this, so a runtime
  /// [setMode] survives the next join (the defaults are one const instance).
  GravixNoiseSuppressionOptions? get configuredWith => _configuredWith;
  GravixNoiseSuppressionOptions? _configuredWith;

  /// Whether a join with [options] (RoomOptions / GravixRoomService) should
  /// [configure]. Not for null or the options already configured, and the
  /// defaults never override an earlier configure: a Room built with
  /// `const RoomOptions()` (connection checker, agent session) must not turn
  /// NS back on after the app chose off (review 2026-10-21). Explicit
  /// options always apply.
  bool joinShouldConfigure(GravixNoiseSuppressionOptions? options) {
    if (options == null || identical(_configuredWith, options)) return false;
    if (_configuredWith != null && identical(options, const GravixNoiseSuppressionOptions())) return false;
    return true;
  }

  bool get _supported => supportedPlatforms.contains(_platform);

  /// Applies [options] (null = legacy: no Gravix NS). Call before the
  /// microphone is created; RoomOptions.noiseSuppression and
  /// GravixRoomService(noiseSuppression:) do. Never throws.
  Future<GravixNsState> configure(GravixNoiseSuppressionOptions? options) async {
    final prev = _options;
    final wasConfigured = prev != null;
    final before = _resolvedEngine;
    _options = options == null ? null : gravixScenarioNsOptions(options);
    _configuredWith = options;
    if (options == null && !wasConfigured) return _state.value;
    final o = _options ?? GravixNoiseSuppressionOptions.legacy;
    final s = await _apply(o, o.mode);
    // A live microphone keeps the WebRTC NS/AGC it was created with unless it is
    // re-applied: a runtime agcOrder / WebRTC-NS change must reach it too, or
    // webrtcBeforeNs mid-call leaves BOTH AGCs off (device run 2026-10-21).
    if (wasConfigured &&
        (gravixNsIsOurs(before) != gravixNsIsOurs(_resolvedEngine) ||
            prev.agcOrder != o.agcOrder ||
            prev.disableWebRtcNs != o.disableWebRtcNs ||
            prev.hardwareNs != o.hardwareNs)) {
      await _reapplyTrackProcessing();
    }
    return s;
  }

  /// Changes the mode at runtime (crossfaded natively). Also updates WebRTC's
  /// software NS / AGC on the live microphone. The Android platform NS is
  /// bound at capture start; a change of it applies to the next capture.
  Future<GravixNsState> setMode(GravixNoiseSuppressionMode mode) async {
    final o = gravixScenarioNsOptions(_options ?? const GravixNoiseSuppressionOptions()).copyWith(mode: mode);
    _options = o;
    final before = _resolvedEngine;
    final s = await _apply(o, mode);
    if (gravixNsIsOurs(before) != gravixNsIsOurs(_resolvedEngine)) await _reapplyTrackProcessing();
    return s;
  }

  Future<GravixNsState> _apply(GravixNoiseSuppressionOptions o, GravixNoiseSuppressionMode mode) async {
    final sw = Stopwatch()..start();
    if (!_supported) {
      final s = GravixNsState(
        mode: mode,
        reason: mode == GravixNoiseSuppressionMode.off ? GravixNsReason.modeOff : GravixNsReason.platformUnsupported,
      );
      _set(s, o, GravixNsStep.policy);
      return s;
    }
    try {
      // re-read each time: the studio model changes when the LL pack arrives
      _facts = await _native.deviceFacts() ?? _facts;
    } catch (e) {
      debugPrint('[GravixNS] facts unavailable: $e');
    }
    final facts = GravixNsDeviceFacts.fromJson({'platform': _platform, ...?_facts});
    final studioAvailable = _facts?['studioAvailable'] == true;
    final benchKey = _benchmarkKey();
    await _loadBenchmark();
    final cached = _bench;
    final bench = cached == null ? null : GravixNsBenchmark.fromJson(cached);
    final r = gravixResolveNs(
      mode: mode,
      facts: facts,
      policy: o.policy,
      studioAvailable: studioAvailable,
      benchmark: bench,
      benchmarkKey: benchKey,
      benchmarkP95: o.benchmarkP95,
    );
    if (r.needsBenchmark && benchKey != null) _startBenchmark(o, benchKey);
    debugPrint(
      gravixNsLogLine(
        GravixNsStep.policy,
        engine: r.engine,
        elapsed: sw.elapsed,
        detail:
            'mode=${mode.name} reason=${r.reason} studioEligible=${r.studioEligible} '
            'model=${facts.model ?? '?'} soc=${facts.soc ?? '?'} abi=${facts.abi ?? '?'} ram=${facts.ramMb ?? '?'}',
      ),
    );
    Map<String, dynamic>? reply;
    try {
      reply = await _native.configure({
        'mode': mode.name,
        'engine': gravixNsEngineName(r.engine),
        'reason': r.reason,
        'agcOrder': o.agcOrder.name,
        'musicBypass': o.musicBypass,
        'hardwareNs': o.hardwareNs.name,
        'headsetNs': o.headsetNs.name,
        'watchdogFrameUs': o.watchdogFrame.inMicroseconds,
        'watchdogConsecutive': o.watchdogConsecutive,
        'thermalFallback': o.thermalFallback,
        'batterySaverFallback': o.batterySaverFallback,
        'studioSource': o.studioSource.name,
        'studioDownload': o.studioDownload.name,
        'studioPackUrl': o.studioPackUrl,
        'studioAttenLimitDb': o.studioAttenLimitDb,
        'studioP95BudgetUs': o.studioP95Budget.inMicroseconds,
        'studioP95WindowMs': o.studioP95Window.inMilliseconds,
        'studioLowLatency': o.studioLowLatency,
        if (_platform == 'android' && cached != null && cached['key'] == benchKey)
          'studioModel': o.studioLowLatency ? cached['model'] : 'std',
        // iOS keys (GxNoiseProcessor.swift): its own names for the same settings
        if (_platform == 'ios') ...{
          'agc': o.agcOrder == GravixNsAgcOrder.ownAfterNs && gravixNsIsOurs(r.engine),
          'watchdogUs': o.watchdogFrame.inMicroseconds,
          'benchmarkP95Us': o.benchmarkP95.inMicroseconds,
          if (cached != null && cached['key'] == benchKey && cached['outputOk'] == true)
            'benchmarkCachedP95Us': cached['p95Us'],
          'studioModel': o.studioLowLatency && o.studioPackUrl != null ? 'll' : 'std',
          'studioLlUrl': !o.studioLowLatency || o.studioPackUrl == null
              ? null
              : '${o.studioPackUrl!.replaceAll(RegExp(r'/+$'), '')}/dfn3_ll_int8.mlpackage.zip',
        },
      });
    } catch (e) {
      debugPrint('[GravixNS] configure failed: $e');
    }
    _listen();
    var engine = r.engine;
    var reason = r.reason;
    if (gravixNsIsOurs(engine) && (reply == null || reply['ok'] != true)) {
      // no native processor (library missing, old plugin): leave WebRTC NS as is
      engine = GravixNsEngine.none;
      reason = (reply?['reason'] as String?) ?? GravixNsReason.nativeUnavailable;
    }
    _resolvedEngine = engine;
    final s = _state.value.copyWith(
      mode: mode,
      engine: engine,
      reason: reason,
      installed: reply?['installed'] == true,
      route: reply?['route'] is String ? gravixNsRouteFromName(reply!['route'] as String) : null,
      rate: reply?['rate'] is int ? reply!['rate'] as int : null,
    );
    _set(s, o, GravixNsStep.init, elapsed: sw.elapsed, detail: 'installed=${s.installed}');
    return s;
  }

  String? _benchmarkKey() {
    final sha = _facts?['studioSha'] as String?;
    if (sha == null) return null;
    return gravixNsBenchmarkKey(
      sdkVersion: kGravixSdkVersion,
      modelSha256: sha,
      runtimeVersion: (_facts?['studioRuntime'] as String?) ?? '?',
      osBuild: (_facts?['osBuild'] as String?) ?? '?',
    );
  }

  Future<void> _loadBenchmark() async {
    if (_benchLoaded) return;
    _benchLoaded = true;
    try {
      final raw = await _native.readBenchmarkCache();
      if (raw != null) _bench = (json.decode(raw) as Map).cast<String, dynamic>();
    } catch (e) {
      debugPrint('[GravixNS] benchmark cache unreadable: $e');
    }
  }

  /// The studio benchmark in the background (RNNoise meanwhile; never blocks a
  /// join). When it is done the current mode is re-applied with the result.
  void _startBenchmark(GravixNoiseSuppressionOptions o, String key) {
    if (_benchRun != null) return;
    final sw = Stopwatch()..start();
    _benchRun = () async {
      try {
        final m = await _native.benchmark(o.benchmarkP95.inMicroseconds);
        final ok = m != null && m['ok'] == true;
        debugPrint(
          gravixNsLogLine(
            GravixNsStep.bench,
            engine: _state.value.engine,
            route: _state.value.route,
            rate: _state.value.rate,
            elapsed: sw.elapsed,
            detail:
                'p95=${m?['p95Us'] ?? '?'} model=${m?['model'] ?? '?'} outputOk=${m?['outputOk'] ?? '?'} '
                'parity=${m?['paritySnrDb'] ?? '-'} ok=$ok reason=${m?['reason'] ?? '-'}',
          ),
        );
        // a failed run counts as bad output (no re-run until the key changes)
        _bench = ok
            ? {'key': key, 'p95Us': m['p95Us'], 'outputOk': m['outputOk'] == true, 'model': m['model']}
            : {'key': key, 'p95Us': 0, 'outputOk': false, 'model': null};
        await _native.writeBenchmarkCache(json.encode(_bench));
        o.onReport?.call(
          GravixNsReport(
            step: GravixNsStep.bench,
            mode: _state.value.mode,
            engine: _state.value.engine,
            reason: _state.value.reason,
            platform: _platform,
            benchmarkP95Us: m?['p95Us'] as int?,
            benchmarkCached: false,
          ),
        );
        final cur = _options;
        if (cur != null) await _apply(cur, _state.value.mode);
      } catch (e) {
        debugPrint('[GravixNS] benchmark failed: $e');
      } finally {
        _benchRun = null;
      }
    }();
  }

  /// Completes when a running studio benchmark is done (tests, example app).
  @visibleForTesting
  Future<void> get benchmarkDone => _benchRun ?? Future<void>.value();

  void _set(GravixNsState s, GravixNoiseSuppressionOptions o, String step, {Duration? elapsed, String? detail}) {
    _state.value = s;
    debugPrint(
      gravixNsLogLine(
        step,
        engine: s.engine,
        route: s.route,
        rate: s.rate,
        elapsed: elapsed,
        detail: [
          'mode=${s.mode.name} reason=${s.reason} agcOrder=${o.agcOrder.name} webrtcNs=${o.disableWebRtcNs ? 'off' : 'kept'}',
          ?detail,
        ].join(' '),
      ),
    );
    o.onReport?.call(
      GravixNsReport(
        step: step,
        mode: s.mode,
        engine: s.engine,
        reason: s.reason,
        platform: _platform,
        route: s.route,
        apmRate: s.rate,
      ),
    );
  }

  void _listen() {
    _eventsSub ??= _native.events.listen(_onEvent);
  }

  void _onEvent(Map<String, Object?> e) {
    final step = e['step'] as String? ?? '';
    final eng = gravixNsEngineFromName(e['eng'] as String?);
    final s = _state.value.copyWith(
      engine: eng,
      reason: e['reason'] as String?,
      route: e['route'] is String ? gravixNsRouteFromName(e['route'] as String) : null,
      rate: e['rate'] is int ? e['rate'] as int : null,
      musicBypass: e['musicBypass'] is bool ? e['musicBypass'] as bool : null,
      p50Us: e['p50Us'] is int ? e['p50Us'] as int : null,
      p95Us: e['p95Us'] is int ? e['p95Us'] as int : null,
      overBudget: e['over'] is int ? e['over'] as int : null,
    );
    _state.value = s;
    _options?.onReport?.call(
      GravixNsReport(
        step: step,
        mode: s.mode,
        engine: s.engine,
        reason: s.reason,
        platform: _platform,
        route: s.route,
        apmRate: s.rate,
        p50Us: s.p50Us,
        p95Us: s.p95Us,
        p99Us: e['p99Us'] is int ? e['p99Us'] as int : null,
        maxUs: e['maxUs'] is int ? e['maxUs'] as int : null,
        framesOverBudget: s.overBudget,
        cpuPercent: e['cpu'] is num ? (e['cpu'] as num).toDouble() : null,
      ),
    );
  }

  /// Fresh frame-time stats from the native processor (also updates [state]).
  Future<GravixNsState> refreshStats() async {
    if (!_supported) return _state.value;
    try {
      final m = await _native.stats();
      if (m != null) _onEvent({...m, 'step': 'stats'});
    } catch (_) {}
    return _state.value;
  }

  /// The capture options to create the microphone with (synchronous; uses the
  /// state of the last [configure]). Unchanged unless one of our engines runs.
  AudioCaptureOptions adjustCapture(AudioCaptureOptions base) {
    final o = _options;
    if (o == null) return base;
    return gravixNsCaptureOptions(base, o, _resolvedEngine);
  }

  /// A microphone track was created from [base] (before [adjustCapture]):
  /// remembered (weakly) so a runtime [setMode] can update its WebRTC processing.
  void trackCreated(LocalAudioTrack track, AudioCaptureOptions base) {
    _trackBase[track] = base.processing;
    _tracks.removeWhere((w) => w.target == null);
    _tracks.add(WeakReference(track));
  }

  Future<void> _reapplyTrackProcessing() async {
    final o = _options;
    if (o == null) return;
    for (final w in List.of(_tracks)) {
      final t = w.target;
      final base = t == null ? null : _trackBase[t];
      if (t == null || base == null || t.events.isDisposed) continue;
      final want = gravixNsProcessing(base, o, _resolvedEngine);
      try {
        await t.setAudioProcessingOptions(want);
        debugPrint(
          '[GravixNS] webrtc processing ns=${want.noiseSuppression} agc=${want.autoGainControl} track=${t.mediaStreamTrack.id}',
        );
      } catch (e) {
        debugPrint('[GravixNS] webrtc processing not changed: $e');
      }
    }
  }
}

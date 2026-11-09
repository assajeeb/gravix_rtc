// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// Voice effects of the local microphone. One per process: the native chain sits
// on the single capture stream, so the effect survives reconnects and region
// moves. Runs on the device, after noise suppression; listeners hear the
// changed voice and the servers are not involved.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rtc_core/src/support/native.dart';

/// A voice effect for [GravixVoiceEffects.set].
enum GravixVoiceEffect {
  none,
  studio,
  hall,
  robot,
  girl,
  transformer,

  /// Voice change.
  boy,
  child,
  woman,
  man,
  foreigner,
  ethereal,

  /// Voice character.
  magnetic,
  fresh,
  energetic,
  rich,
  muffled,
  round,
  falsetto,
  full,
  clear,
  resonant,
  loudClear,

  /// Rooms.
  softRoom,
  largeRoom,
  valley,
  basement,
  ktv,
  enhancedKtv,
  popular,
  rock,
  vocalConcert,
  gramophone,

  /// The voice snaps to the notes of a scale. C major and A minor share the same notes.
  autotuneMajorC,
  autotuneMinorA,
  autotuneHarmonicMinor,
}

/// Why the effect is, or is not, in the audio.
enum GravixVoiceEffectReason {
  ok,

  /// Not available on this platform (web and desktop for now).
  platformUnsupported,

  /// The native library did not load.
  libraryMissing,

  /// The device could not keep up; the effect is off until the next [GravixVoiceEffects.set].
  watchdog,

  failed,
}

/// Live state on [GravixVoiceEffects.state].
@immutable
class GravixVoiceEffectState {
  const GravixVoiceEffectState({
    this.effect = GravixVoiceEffect.none,
    this.active = GravixVoiceEffect.none,
    this.reason = GravixVoiceEffectReason.ok,
    this.musicBypass = false,
    this.latencyMs = 0,
  });

  /// What the app asked for.
  final GravixVoiceEffect effect;

  /// What the audio path runs now.
  final GravixVoiceEffect active;
  final GravixVoiceEffectReason reason;

  /// Room music is playing: the voice goes out without the effect, so the music is not pitch shifted.
  final bool musicBypass;

  /// Delay the effect adds to the microphone (0 unless the effect changes pitch, about 40 when it does).
  final int latencyMs;

  @override
  bool operator ==(Object other) =>
      other is GravixVoiceEffectState &&
      other.effect == effect &&
      other.active == active &&
      other.reason == reason &&
      other.musicBypass == musicBypass &&
      other.latencyMs == latencyMs;

  @override
  int get hashCode => Object.hash(effect, active, reason, musicBypass, latencyMs);

  @override
  String toString() =>
      'GravixVoiceEffectState(effect: ${effect.name}, active: ${active.name}, reason: ${reason.name}, '
      'musicBypass: $musicBypass, latencyMs: $latencyMs)';
}

/// Timing of one effect on this device, from [GravixVoiceEffects.benchmark].
@immutable
class GravixVoiceEffectBenchmark {
  const GravixVoiceEffectBenchmark({
    required this.effect,
    required this.p50Us,
    required this.p95Us,
    required this.maxUs,
    required this.latencyMs,
  });
  final GravixVoiceEffect effect;
  final int p50Us;
  final int p95Us;
  final int maxUs;
  final int latencyMs;
}

/// Voice effects of the local microphone.
///
/// ```dart
/// await GravixVoiceEffects.instance.set(GravixVoiceEffect.robot);
/// ```
class GravixVoiceEffects {
  GravixVoiceEffects._();

  /// The process-wide instance.
  static final GravixVoiceEffects instance = GravixVoiceEffects._();

  final ValueNotifier<GravixVoiceEffectState> _state = ValueNotifier(const GravixVoiceEffectState());
  StreamSubscription<Map<String, Object?>>? _events;

  /// Current state.
  ValueListenable<GravixVoiceEffectState> get state => _state;

  /// Applies [effect] to the microphone; [GravixVoiceEffect.none] turns it off.
  /// Can be called before joining and at any time in a room. Returns whether it was applied.
  Future<bool> set(GravixVoiceEffect effect) async {
    if (!_platformSupported) {
      _state.value = GravixVoiceEffectState(effect: effect, reason: GravixVoiceEffectReason.platformUnsupported);
      debugPrint('[GravixFX] step=set effect=${effect.name} result=platform_unsupported');
      return false;
    }
    _listen();
    final Map<String, dynamic>? reply;
    try {
      reply = await Native.nsCall('fxConfigure', {'effect': effect.name});
    } catch (e) {
      debugPrint('[GravixFX] step=set effect=${effect.name} result=failed error=$e');
      _state.value = GravixVoiceEffectState(effect: effect, reason: GravixVoiceEffectReason.failed);
      return false;
    }
    if (reply == null) {
      _state.value = GravixVoiceEffectState(effect: effect, reason: GravixVoiceEffectReason.platformUnsupported);
      debugPrint('[GravixFX] step=set effect=${effect.name} result=no_native');
      return false;
    }
    final ok = reply['ok'] == true;
    _state.value = _parse(reply, effect);
    debugPrint('[GravixFX] step=set effect=${effect.name} ok=$ok reply=$reply');
    return ok;
  }

  /// Times [effect] on this device for [seconds], off the audio path. Null when unavailable.
  Future<GravixVoiceEffectBenchmark?> benchmark(GravixVoiceEffect effect, {int seconds = 5}) async {
    if (!_platformSupported) return null;
    final m = await Native.nsCall('fxBenchmark', {'effect': effect.name, 'seconds': seconds});
    if (m == null || m['ok'] != true) return null;
    return GravixVoiceEffectBenchmark(
      effect: effect,
      p50Us: (m['p50Us'] as num).toInt(),
      p95Us: (m['p95Us'] as num).toInt(),
      maxUs: (m['maxUs'] as num).toInt(),
      latencyMs: (m['latencyMs'] as num).toInt(),
    );
  }

  bool get _platformSupported =>
      debugOverridePlatformSupported ??
      (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS));

  /// Tests only.
  @visibleForTesting
  bool? debugOverridePlatformSupported;

  /// Tests only.
  @visibleForTesting
  void debugReset() {
    _events?.cancel();
    _events = null;
    _state.value = const GravixVoiceEffectState();
  }

  void _listen() {
    _events ??= Native.voiceEffectEvents.listen((m) {
      final next = _parse(m, _state.value.effect);
      debugPrint('[GravixFX] step=event type=${m['type']} state=$next');
      _state.value = next;
    });
  }

  GravixVoiceEffectState _parse(Map<String, Object?> m, GravixVoiceEffect asked) {
    final watchdog = m['watchdog'] == true;
    final reasonName = m['reason'];
    final reason = watchdog
        ? GravixVoiceEffectReason.watchdog
        : reasonName == 'library_missing'
        ? GravixVoiceEffectReason.libraryMissing
        : (reasonName == null || reasonName == 'ok')
        ? GravixVoiceEffectReason.ok
        : GravixVoiceEffectReason.failed;
    return GravixVoiceEffectState(
      effect: _byName(m['effect']) ?? asked,
      active: _byName(m['active']) ?? GravixVoiceEffect.none,
      reason: reason,
      musicBypass: m['musicBypass'] == true,
      latencyMs: (m['latencyMs'] as num?)?.toInt() ?? 0,
    );
  }

  GravixVoiceEffect? _byName(Object? name) {
    for (final e in GravixVoiceEffect.values) {
      if (e.name == name) return e;
    }
    return null;
  }
}

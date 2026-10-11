// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart' show immutable, kIsWeb;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;

import '../logger.dart';
import '../support/native.dart';
import '../support/platform.dart';

/// Android capture source of WebRTC's recorder.
enum GravixCaptureAudioSource {
  /// `MediaRecorder.AudioSource.MIC`: the plain microphone. Other apps can
  /// still record while it runs; no platform voice processing.
  mic,

  /// `MediaRecorder.AudioSource.VOICE_COMMUNICATION`: the platform's voice
  /// path (usually its own echo canceller / noise suppressor and call gain).
  /// While it runs, other apps' recorders are silenced.
  voiceCommunication,
}

/// Android media-profile echo experiments (2026-10-10). EXPERIMENTAL.
///
/// Why: on the media profile (`AndroidAudioConfiguration.media` with
/// `bypassVoiceProcessing`: MIC source, stereo, no low-latency playout,
/// libwebrtc's software AEC3) an app could send the room's own playout back
/// almost uncancelled. flutter_webrtc builds
/// WebRTC's audio device module inside its own `initialize()` and has no
/// option for these settings, so they are applied to the built module
/// afterwards. Call [GravixMediaEcho.apply] once, AFTER `WebRTC.initialize()`
/// (or `GravixRtcClient.initialize()`) and BEFORE the first room connects.
///
/// Every field defaults to "leave the module as built"; the default tuning
/// makes no platform call at all.
@immutable
class GravixMediaEchoTuning {
  const GravixMediaEchoTuning({
    this.lowLatencyPlayout,
    this.captureSource,
    this.aec3FieldTrials = '',
    this.keepWarpTrial = false,
  });

  /// Low-latency playout (AudioTrack PERFORMANCE_MODE_LOW_LATENCY) instead of
  /// the media output's deep buffer (2026-10-10: ~205-310 ms playout latency
  /// measured on that path). null = as built (flutter_webrtc: off with
  /// `bypassVoiceProcessing`, on otherwise). Applies to the next playout start.
  final bool? lowLatencyPlayout;

  /// The recorder's capture source. With a mono module (WebRTC.initialize
  /// WITHOUT `bypassVoiceProcessing`), [GravixCaptureAudioSource.mic] gives a
  /// mono MIC capture with software AEC3, which flutter_webrtc cannot express
  /// itself. null = as built. Applies to the next capture start.
  final GravixCaptureAudioSource? captureSource;

  /// libwebrtc field trials for the echo canceller, e.g.
  /// `WebRTC-Aec3TransparentModeHmm/Enabled/`. Must be well formed
  /// (`Name/Group/` pairs). This REPLACES libwebrtc's whole process-wide
  /// field-trial string (set [keepWarpTrial] if the app turned WARP on);
  /// AEC3 reads it when it is created (the first capture). '' = untouched.
  final String aec3FieldTrials;

  /// Re-add flutter_webrtc's WARP trial (`enableWARP`) to [aec3FieldTrials].
  final bool keepWarpTrial;

  bool get isOff => lowLatencyPlayout == null && captureSource == null && aec3FieldTrials.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is GravixMediaEchoTuning &&
      other.lowLatencyPlayout == lowLatencyPlayout &&
      other.captureSource == captureSource &&
      other.aec3FieldTrials == aec3FieldTrials &&
      other.keepWarpTrial == keepWarpTrial;

  @override
  int get hashCode => Object.hash(lowLatencyPlayout, captureSource, aec3FieldTrials, keepWarpTrial);

  @override
  String toString() =>
      'GravixMediaEchoTuning(lowLatencyPlayout: $lowLatencyPlayout, captureSource: ${captureSource?.name}, '
      'aec3FieldTrials: "$aec3FieldTrials", keepWarpTrial: $keepWarpTrial)';
}

/// What [GravixMediaEcho.apply] did.
@immutable
class GravixMediaEchoReport {
  const GravixMediaEchoReport({required this.applied, this.reason = '', this.native = const {}});

  /// The platform received the tuning (see [native] for each setting).
  final bool applied;

  /// Why nothing was applied: `off`, `unsupported`, or the platform error.
  final String reason;

  /// Per setting: `applied`, `appliedFromNextPlayout` / `appliedFromNextCapture`,
  /// `refused: ...` or `failed: ...`, plus the previous values (`...Was`).
  final Map<String, Object?> native;

  @override
  String toString() => 'GravixMediaEchoReport(applied: $applied, reason: $reason, native: $native)';
}

/// libwebrtc's own check (FieldTrialsStringIsValid): `Name/Group/` pairs, a
/// name may repeat only with the same group.
bool gravixFieldTrialsValid(String trials) {
  if (trials.isEmpty) return true;
  final seen = <String, String>{};
  var next = 0;
  while (next < trials.length) {
    final nameEnd = trials.indexOf('/', next);
    if (nameEnd < 0 || nameEnd == next) return false;
    final groupEnd = trials.indexOf('/', nameEnd + 1);
    if (groupEnd < 0 || groupEnd == nameEnd + 1) return false;
    final name = trials.substring(next, nameEnd);
    final group = trials.substring(nameEnd + 1, groupEnd);
    final prev = seen[name];
    if (prev != null && prev != group) return false;
    seen[name] = group;
    next = groupEnd + 1;
  }
  return true;
}

/// Applies a [GravixMediaEchoTuning] to WebRTC's Android audio device module.
class GravixMediaEcho {
  GravixMediaEcho._();

  /// See [GravixMediaEchoTuning]. Android only; an off tuning or another
  /// platform makes no call. Throws [ArgumentError] for a malformed
  /// [GravixMediaEchoTuning.aec3FieldTrials]; platform failures are reported.
  static Future<GravixMediaEchoReport> apply(GravixMediaEchoTuning tuning) async {
    if (tuning.isOff) return const GravixMediaEchoReport(applied: false, reason: 'off');
    if (!gravixFieldTrialsValid(tuning.aec3FieldTrials)) {
      throw ArgumentError.value(tuning.aec3FieldTrials, 'aec3FieldTrials', 'not a Name/Group/ field-trial string');
    }
    if (kIsWeb || !lkPlatformIs(PlatformType.android)) {
      return const GravixMediaEchoReport(applied: false, reason: 'unsupported');
    }
    final args = <String, Object?>{
      if (tuning.lowLatencyPlayout != null) 'lowLatencyPlayout': tuning.lowLatencyPlayout,
      if (tuning.captureSource != null) 'captureSource': tuning.captureSource!.name,
      if (tuning.aec3FieldTrials.isNotEmpty) 'aec3FieldTrials': tuning.aec3FieldTrials,
      'keepWarpTrial': tuning.keepWarpTrial,
    };
    try {
      final reply = await Native.applyMediaEchoTuning(args);
      logger.info('media echo tuning $tuning -> $reply');
      return GravixMediaEchoReport(applied: true, native: reply);
    } on PlatformException catch (e) {
      logger.warning('media echo tuning failed: ${e.code} ${e.message}');
      return GravixMediaEchoReport(applied: false, reason: '${e.code}: ${e.message}');
    } on MissingPluginException {
      return const GravixMediaEchoReport(applied: false, reason: 'no native plugin');
    }
  }
}

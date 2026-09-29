// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:math' as math;

import '../options.dart' show VideoPublishOptions;
import 'video_dimensions.dart';
import 'video_parameters.dart';

/// Per-app maximum video resolution, as set by the Gravix SFU.
///
/// After join the SFU puts a server-owned attribute on the LOCAL participant,
/// [attributeKey] = decimal short-edge limit (e.g. `"540"`). The SFU enforces
/// it: simulcast layers above it are not forwarded and a camera track whose
/// smallest layer is above it is rejected at `addTrack`. The SDK clamps what
/// it publishes so a compliant app is never rejected.
///
/// "Resolution" here is always the SHORT edge, `min(width, height)`, so a
/// 540x960 portrait capture is 540p — the same rule the SFU applies.
///
/// All functions are pure; the publish path in `LocalParticipant` wires them in.
abstract final class GravixVideoCap {
  /// Server-owned local-participant attribute carrying the plan cap.
  static const attributeKey = 'gravix.max_video_height';

  /// Screen share is always allowed at least this short edge, whatever the
  /// plan: text at < 1080p is unreadable, and the SFU applies the same floor.
  static const screenShareFloor = 1080;

  /// The plan cap from participant [attributes], or null when absent or not a
  /// positive integer. Null means "no cap known": callers keep their defaults
  /// rather than guess, since a wrong guess would either reject or degrade.
  static int? parse(Map<String, String> attributes) {
    final raw = attributes[attributeKey]?.trim();
    if (raw == null || raw.isEmpty) return null;
    final v = int.tryParse(raw);
    return (v == null || v <= 0) ? null : v;
  }

  /// The short-edge limit that applies to a track: the plan cap for camera,
  /// `max(cap, 1080)` for screen share.
  static int effective(int cap, {required bool isScreenShare}) => isScreenShare ? math.max(cap, screenShareFloor) : cap;

  /// [d] scaled down (aspect kept) so its short edge is <= [cap]; unchanged
  /// when it already fits. Both sides are rounded DOWN to even: encoders want
  /// even sizes, and rounding down can never push the short edge over [cap].
  static VideoDimensions clampDimensions(VideoDimensions d, int cap) {
    if (d.width <= 0 || d.height <= 0 || d.min() <= cap) return d;
    final scale = d.min() / cap;
    int even(double v) => math.max(2, (v.floor() ~/ 2) * 2);
    return VideoDimensions(even(d.width / scale), even(d.height / scale));
  }

  /// [p] with its dimensions clamped to [cap]. The encoding is kept: capture
  /// params only drive getUserMedia; publish bitrates come from the publish
  /// options (or are re-derived from the clamped size).
  static VideoParameters clampParameters(VideoParameters p, int cap) {
    final d = clampDimensions(p.dimensions, cap);
    if (d == p.dimensions) return p;
    return VideoParameters(description: p.description, dimensions: d, encoding: p.encoding);
  }

  /// Simulcast rungs whose short edge is <= [cap]; rungs above it are dropped
  /// (the SFU would not forward them, so encoding them only burns CPU/uplink).
  static List<VideoParameters> clampLayers(List<VideoParameters> layers, int cap) =>
      layers.where((l) => l.dimensions.min() <= cap).toList();

  /// [o] with camera rungs clamped to [cap] and screen-share rungs to
  /// `max(cap, 1080)`. Everything else is untouched. Works for app-supplied
  /// options and for `GravixPublishPresets` alike.
  static VideoPublishOptions clampPublishOptions(VideoPublishOptions o, int cap) => o.copyWith(
    videoSimulcastLayers: clampLayers(o.videoSimulcastLayers, cap),
    screenShareSimulcastLayers: clampLayers(o.screenShareSimulcastLayers, effective(cap, isScreenShare: true)),
  );

  /// `scaleResolutionDownBy` that brings a [source]-sized frame to [clamped],
  /// computed on the long edge exactly like `Utils.encodingsFromPresets`, so a
  /// single-encoding publish lands on the same size a simulcast `f` would.
  static double scaleDownBy(VideoDimensions source, VideoDimensions clamped) =>
      clamped.max() <= 0 ? 1.0 : math.max(1.0, source.max() / clamped.max());
}

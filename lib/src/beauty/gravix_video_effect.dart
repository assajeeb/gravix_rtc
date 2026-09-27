// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.
//
// The local-camera video-effect hook (2026-09-27). Replaces the old
// `GravixBeautyFilter` stub, whose default implementation called a
// `gravity.beauty_filter` channel that no platform implemented and reported
// nothing about it.
import 'package:flutter/foundation.dart';

import '../rtc_core/gravix_client.dart' show LocalVideoTrack;

/// The local camera track an effect is asked to process.
///
/// [trackId] is the flutter_webrtc `MediaStreamTrack.id` — the key under which
/// the native side of flutter_webrtc keeps the track
/// (`FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)` on Android,
/// the plugin's `localTracks[trackId]` on iOS). A native effect registers its
/// frame processor on that track; see [GravixVideoEffect].
@immutable
class GravixVideoEffectTarget {
  const GravixVideoEffectTarget({required this.trackId, this.track});

  /// The target for a live SDK camera track.
  factory GravixVideoEffectTarget.fromTrack(LocalVideoTrack track) =>
      GravixVideoEffectTarget(trackId: track.mediaStreamTrack.id!, track: track);

  final String trackId;

  /// The SDK track, when the effect was attached by [GravixRoomService]. Null
  /// when an app attaches an effect to a bare track id.
  final LocalVideoTrack? track;

  @override
  bool operator ==(Object other) => other is GravixVideoEffectTarget && other.trackId == trackId;

  @override
  int get hashCode => trackId.hashCode;

  @override
  String toString() => 'GravixVideoEffectTarget($trackId)';
}

/// A real-time effect (beauty, background blur, filters …) on the LOCAL camera
/// track. The SDK ships no effect — this is the hook an effect package plugs
/// into, e.g. the separate `gravixEffect` package:
///
/// ```dart
/// final room = GravixRoomService(videoEffect: MyBeautyEffect());
/// ```
///
/// With no effect passed, the service calls nothing and claims nothing.
///
/// ## Lifecycle, as driven by [GravixRoomService]
///
/// 1. the camera track starts → [attach] with that track;
/// 2. if [attach] returned true → [setEnabled]`(true)`;
/// 3. the camera flips → [attach] again with the (possibly new) track — must be
///    idempotent for the same track id;
/// 4. the camera stops, the room disconnects, or the service is disposed →
///    [detach].
///
/// The app drives [setEnabled] / [setParams] through
/// [GravixRoomService.setVideoEffectEnabled] /
/// [GravixRoomService.setVideoEffectParams] at any time; the service remembers
/// the last values and replays them after every successful [attach], so an
/// effect never has to cache what the app set before the camera was on.
///
/// ## Honest results (no silent fake success)
///
/// [attach] returns whether frames of that track will now actually go through
/// the effect. An effect whose native side is missing (plugin not registered
/// on this platform, unsupported device, web) MUST return false or throw — the
/// service then reports [GravixRoomService.videoEffectActive] = false and does
/// not call [setEnabled]. It must never answer true for a pipeline that is not
/// there.
///
/// ## Implementing one natively (flutter_webrtc 1.6.x)
///
/// The camera frames are produced by flutter_webrtc, which exposes a
/// per-track frame-processor chain on both mobile platforms. An effect plugin's
/// [attach] sends [GravixVideoEffectTarget.trackId] over its own method channel;
/// the native side then does:
///
/// **Android** (`com.cloudwebrtc.webrtc`):
/// ```java
/// LocalTrack t = FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId);
/// if (!(t instanceof LocalVideoTrack)) { result.success(false); return; }
/// ((LocalVideoTrack) t).addProcessor(myProcessor); // ExternalVideoFrameProcessing
/// result.success(true);
/// // detach: ((LocalVideoTrack) t).removeProcessor(myProcessor);
/// ```
/// `ExternalVideoFrameProcessing.onFrame(VideoFrame)` runs on the capture thread
/// for every frame and returns the processed frame (e.g. a GL texture frame).
///
/// **iOS** (`flutter_webrtc`):
/// ```objc
/// LocalVideoTrack *t = (LocalVideoTrack *)[FlutterWebRTCPlugin sharedSingleton].localTracks[trackId];
/// if (![t isKindOfClass:LocalVideoTrack.class]) { result(@NO); return; }
/// [t addProcessing:myProcessor]; // id<ExternalVideoProcessingDelegate>
/// result(@YES);
/// // detach: [t removeProcessing:myProcessor];
/// ```
///
/// **Web**: flutter_webrtc gives no frame hook; use insertable streams /
/// `MediaStreamTrackProcessor` in the effect package, or return false.
///
/// The processor is attached to the track's video SOURCE, so it survives a
/// camera flip ([LocalVideoTrack.setCameraPosition] keeps the source) and the
/// service's data-saver republish (the capturer is not stopped on unpublish).
/// Simulcast layers are encoder downscales of the processed frame: the effect
/// runs once per frame, not once per layer.
abstract class GravixVideoEffect {
  /// A short name for logs, e.g. `beauty` or `blur`.
  String get name;

  /// The lowest capture frame rate this effect wants (a hint). When set, the
  /// service captures at no less than this — e.g. 24 so that dim-light
  /// auto-exposure cannot drag the sensor down to ~13 fps. Null = no opinion
  /// (the service's default capture rate).
  int? get minFps => null;

  /// Start processing [target]'s frames. Returns true only when frames of that
  /// track now really go through the effect. Idempotent for the same track id.
  Future<bool> attach(GravixVideoEffectTarget target);

  /// Stop processing and release whatever [attach] took. Safe to call when not
  /// attached.
  Future<void> detach();

  /// Turn the effect on/off without detaching (a bypass).
  Future<void> setEnabled(bool enabled);

  /// Effect-specific parameters, e.g. `{'smooth': 0.6, 'whiten': 0.3}`. The keys
  /// are the effect package's contract, not the SDK's.
  Future<void> setParams(Map<String, Object?> params);
}

/// Drives a [GravixVideoEffect] from the service's camera lifecycle. Internal
/// to the SDK (the service owns one; not exported from the package barrel);
/// kept separate so the lifecycle can be tested without a camera.
class GravixVideoEffectBinding {
  GravixVideoEffectBinding(this.effect);

  final GravixVideoEffect? effect;

  /// True while the effect reported that it is processing the current track.
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  bool _enabled = true;
  Map<String, Object?>? _params;
  GravixVideoEffectTarget? _target;
  bool _disposed = false;

  bool get enabled => _enabled;
  GravixVideoEffectTarget? get target => _target;

  /// The capture frame rate to ask for: [base], raised to the effect's
  /// [GravixVideoEffect.minFps] when that is higher.
  double captureFps(double base) {
    final min = effect?.minFps;
    return (min != null && min > base) ? min.toDouble() : base;
  }

  /// The camera track is live (first start or after a flip). Never throws.
  Future<bool> onCameraTrack(GravixVideoEffectTarget target) async {
    final fx = effect;
    if (fx == null || _disposed) return false;
    _target = target;
    bool ok;
    try {
      ok = await fx.attach(target);
    } catch (e) {
      debugPrint('video effect "${fx.name}" attach failed: $e');
      ok = false;
    }
    if (_disposed) return false;
    if (ok) {
      try {
        if (_params != null) await fx.setParams(_params!);
        await fx.setEnabled(_enabled);
      } catch (e) {
        debugPrint('video effect "${fx.name}" set-up failed: $e');
      }
    } else {
      debugPrint('video effect "${fx.name}" is not processing $target (attach answered false)');
    }
    active.value = ok;
    return ok;
  }

  /// The camera stopped / the room went away. Never throws.
  Future<void> onCameraStopped() async {
    final fx = effect;
    final wasAttached = _target != null;
    _target = null;
    if (!_disposed) active.value = false;
    if (fx == null || !wasAttached) return;
    try {
      await fx.detach();
    } catch (e) {
      debugPrint('video effect "${fx.name}" detach failed: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    final fx = effect;
    if (fx == null || !active.value) return;
    await fx.setEnabled(enabled);
  }

  Future<void> setParams(Map<String, Object?> params) async {
    _params = Map<String, Object?>.unmodifiable(params);
    final fx = effect;
    if (fx == null || !active.value) return;
    await fx.setParams(_params!);
  }

  Future<void> dispose() async {
    await onCameraStopped();
    _disposed = true;
    active.dispose();
  }
}

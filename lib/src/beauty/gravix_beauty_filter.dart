import 'gravix_video_effect.dart';

/// The pre-0.4 beauty extension point.
///
/// DEPRECATED (2026-09-27, removal no earlier than 2027-09): implement
/// [GravixVideoEffect] and pass it as `GravixRoomService(videoEffect: …)`.
/// A filter passed as `GravixRoomService(beauty: …)` still works: it is wrapped
/// in [GravixBeautyFilterEffect].
@Deprecated(
  'Implement GravixVideoEffect and pass GravixRoomService(videoEffect: ...). Removal no earlier than 2027-09.',
)
abstract class GravixBeautyFilter {
  /// Attach the beauty pipeline to the active camera track (idempotent).
  Future<void> attach();

  /// Attach the beauty pipeline to a specific media-stream track id.
  Future<void> attachToTrackId(String trackId);

  /// Enable/disable the beauty pass.
  Future<void> setEnabled(bool enabled);

  /// Push the current beauty parameters/uniforms to the native renderer.
  Future<void> setParams();

  /// Enforce a minimum capture framerate for the given track id.
  Future<void> setMinFps(String trackId, int fps);
}

/// Runs a legacy [GravixBeautyFilter] as a [GravixVideoEffect].
///
/// The old interface returns nothing, so the wrapper cannot know whether the
/// filter really attached: [attach] is true when `attachToTrackId` completed
/// without throwing. The exception is `DefaultGravixBeautyFilter`, whose channel
/// answer IS checked — a missing native plugin reports false.
class GravixBeautyFilterEffect implements GravixVideoEffect {
  GravixBeautyFilterEffect(this.filter, {this.minFps = 24});

  final GravixBeautyFilter filter;

  @override
  String get name => 'beauty(legacy)';

  /// The old service forced a 24 fps floor through `setMinFps`; kept.
  @override
  final int? minFps;

  @override
  Future<bool> attach(GravixVideoEffectTarget target) async {
    final f = filter;
    if (f is GravixBeautyChannelProbe) {
      final ok = await (f as GravixBeautyChannelProbe).attachToTrackIdChecked(target.trackId);
      if (!ok) return false;
    } else {
      await f.attachToTrackId(target.trackId);
    }
    await f.setParams();
    if (minFps != null) await f.setMinFps(target.trackId, minFps!);
    return true;
  }

  /// The legacy interface has no detach; the native side released the processor
  /// with the track.
  @override
  Future<void> detach() async {}

  @override
  Future<void> setEnabled(bool enabled) => filter.setEnabled(enabled);

  /// Legacy filters keep their own parameters; the map is not forwarded.
  @override
  Future<void> setParams(Map<String, Object?> params) => filter.setParams();
}

/// Implemented by `DefaultGravixBeautyFilter`: an attach whose answer is
/// checked, so a missing native plugin is reported instead of swallowed.
abstract interface class GravixBeautyChannelProbe {
  Future<bool> attachToTrackIdChecked(String trackId);
}

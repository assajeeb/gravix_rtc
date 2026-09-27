import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'gravix_beauty_filter.dart';

/// The pre-0.4 platform bridge over the `gravity.beauty_filter` method channel:
///
///   attach / attachToTrackId {trackId}
///   setEnabled {enabled} / setParams / setMinFps {trackId, fps}
///
/// The SDK does NOT implement that channel on any platform; only an app that
/// registers its own `BeautyFilterPlugin` on it gets any effect. Since
/// 2026-09-27 it is no longer the service's default (the default is no effect),
/// and when passed explicitly a missing plugin is reported
/// (`GravixRoomService.videoEffectActive` stays false) instead of swallowed.
///
/// DEPRECATED: implement `GravixVideoEffect`. Removal no earlier than 2027-09.
@Deprecated(
  'Implement GravixVideoEffect and pass GravixRoomService(videoEffect: ...). Removal no earlier than 2027-09.',
)
class DefaultGravixBeautyFilter implements GravixBeautyFilter, GravixBeautyChannelProbe {
  DefaultGravixBeautyFilter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('gravity.beauty_filter');

  final MethodChannel _channel;

  @override
  Future<void> attach() async {
    await _invoke('attach');
  }

  @override
  Future<void> attachToTrackId(String trackId) async {
    await _invoke('attachToTrackId', {'trackId': trackId});
  }

  /// True only when a native plugin answered and did not answer `false`.
  @override
  Future<bool> attachToTrackIdChecked(String trackId) => _invoke('attachToTrackId', {'trackId': trackId});

  @override
  Future<void> setEnabled(bool enabled) async {
    await _invoke('setEnabled', {'enabled': enabled});
  }

  @override
  Future<void> setParams() async {
    await _invoke('setParams');
  }

  @override
  Future<void> setMinFps(String trackId, int fps) async {
    await _invoke('setMinFps', {'trackId': trackId, 'fps': fps});
  }

  Future<bool> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      final result = await _channel.invokeMethod<dynamic>(method, args);
      // The native plugin may answer false: "not supported on this pipeline".
      return !(result is bool && !result);
    } on MissingPluginException {
      debugPrint('gravity.beauty_filter: no native plugin registered — no beauty processing');
      return false;
    } on PlatformException catch (e) {
      debugPrint('gravity.beauty_filter $method failed: ${e.message}');
      return false;
    }
  }
}

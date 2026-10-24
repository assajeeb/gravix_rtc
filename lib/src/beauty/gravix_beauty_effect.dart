// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.
//
// The built-in beauty effect (2026-10-24): Gravix Effects (looks, reshape,
// makeup, stickers, 3D) as a GravixCameraEffect. Android only; elsewhere, or
// when the app stripped the native SDK, it declines and the room opens its
// normal camera.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gravix_effects_webrtc/gravix_effects_webrtc.dart';

import '../rtc_core/gravix_client.dart' show CameraCaptureOptions, CameraPosition, LocalVideoTrack, TrackSource;
import 'gravix_video_effect.dart';

/// Real-time beauty effects from Gravix Effects: looks, face reshape, makeup,
/// stickers and 3D effects, on Android.
///
/// ```dart
/// final room = GravixRoomService(videoEffect: GravixBeautyEffect(licenseToken: token));
/// await room.setVideoEffectParams({'look': 'glow'});
/// ```
///
/// [licenseToken] is the App ID's effects token from your server (the Gravix
/// console issues it for apps with effects enabled). The native SDK checks it;
/// without a valid one the effects still run, with a watermark.
///
/// Parameters ([GravixRoomService.setVideoEffectParams]):
/// - `look`: a built-in look name (see [camera] → `builtinLooks()`);
/// - `lookBytes`: a `.gfx` look file exported from Gravix Studio;
/// - `tone`, `region`, `reshape`: `Map<String, double?>` adjustments, as
///   `GravixCamera.setAdjustments`.
///
/// For everything else (a preview widget, overlays, LUTs) use [camera] while
/// it is open.
///
/// Size: the native SDK adds about 13 MB to an Android app. An app that does
/// not use it can strip it; see the package README ("Beauty effects: removing
/// them"). [canOwnCamera] then answers false and the room uses its normal
/// camera.
class GravixBeautyEffect extends GravixCameraEffect {
  GravixBeautyEffect({this.licenseToken, this.fps = 30, this.textureFrames = false});

  /// The App ID's effects license token (null = watermarked).
  final String? licenseToken;

  /// Engine frame rate when the room asks for none.
  final int fps;

  /// See `GravixWebRtc.attach`: true only when the video encoder is known to
  /// be hardware.
  final bool textureFrames;

  static const MethodChannel _probe = MethodChannel('com.gravitycompile.gravix_rtc/effects');

  /// Test seam: replaces the platform + native-SDK check.
  @visibleForTesting
  static Future<bool> Function()? debugNativeAvailable;

  static bool? _available;

  GravixCamera? _camera;
  LocalVideoTrack? _track;
  bool _licensed = false;

  /// The running Gravix camera, while the room's camera is on.
  GravixCamera? get camera => _camera;

  @override
  String get name => 'gravix-beauty';

  @override
  int? get minFps => 24;

  /// Loads the face model and the engine ahead of the first camera open
  /// (about 1 s on a mid-range phone; without it the first video after app
  /// start arrives seconds late). Call it when the screen that will join
  /// opens. Safe to call more than once, and a no-op where the effect cannot
  /// run (other platforms, a stripped native SDK). Returns whether it loaded.
  Future<bool> preload() async {
    if (!await canOwnCamera()) return false;
    try {
      return await GravixCamera.preload();
    } catch (e) {
      debugPrint('gravix-beauty: preload failed: $e');
      return false;
    }
  }

  @override
  Future<bool> canOwnCamera() async {
    final seam = debugNativeAvailable;
    if (seam != null) return seam();
    if (!GravixCamera.isSupported) return false;
    if (_available != null) return _available!;
    try {
      _available = (await _probe.invokeMethod<bool>('nativeAvailable')) ?? false;
    } catch (e) {
      debugPrint('gravix-beauty: native check failed: $e');
      _available = false;
    }
    if (!_available!) debugPrint('gravix-beauty: the Gravix Effects SDK is not in this app; using the normal camera');
    return _available!;
  }

  @override
  Future<LocalVideoTrack> openCamera(CameraCaptureOptions options) async {
    await _close();
    if (!_licensed) {
      final status = await GravixCamera.setLicense(licenseToken);
      debugPrint('gravix-beauty: license $status');
      _licensed = true;
    }
    if (!await GravixCamera.requestPermission()) {
      throw GravixException('E_PERMISSION', 'camera permission denied');
    }
    final d = options.params.dimensions;
    final shortSide = d.width < d.height ? d.width : d.height;
    final cam = await GravixCamera.start(
      lens: options.cameraPosition == CameraPosition.back ? GravixLens.back : GravixLens.front,
      fps: options.maxFrameRate?.round() ?? fps,
      streamResolution: shortSide,
    );
    try {
      final out = await GravixWebRtc.attach(cam, textureFrames: textureFrames);
      // ignore: invalid_use_of_internal_member
      final track = LocalVideoTrack(TrackSource.camera, out.stream, out.videoTrack, options);
      _camera = cam;
      _track = track;
      return track;
    } catch (_) {
      await cam.stop();
      rethrow;
    }
  }

  @override
  Future<bool> attach(GravixVideoEffectTarget target) async =>
      _track != null && target.trackId == _track!.mediaStreamTrack.id;

  @override
  Future<void> detach() => _close();

  @override
  Future<CameraPosition> switchCamera() async {
    final cam = _camera;
    if (cam == null) throw StateError('gravix-beauty: the camera is not open');
    final lens = await cam.switchCamera();
    return lens == GravixLens.back ? CameraPosition.back : CameraPosition.front;
  }

  @override
  Future<void> setEnabled(bool enabled) async => _camera?.setEnabled(enabled);

  @override
  Future<void> setParams(Map<String, Object?> params) async {
    final cam = _camera;
    if (cam == null) return;
    final look = params['look'];
    if (look is String) await cam.setBuiltinLook(look);
    final bytes = params['lookBytes'];
    if (bytes is Uint8List) await cam.setLookBytes(bytes);
    Map<String, double?>? adj(Object? v) => v is Map ? v.map((k, x) => MapEntry('$k', (x as num?)?.toDouble())) : null;
    final tone = adj(params['tone']), region = adj(params['region']), reshape = adj(params['reshape']);
    if (tone != null || region != null || reshape != null) {
      final warnings = await cam.setAdjustments(tone: tone, region: region, reshape: reshape);
      if (warnings.isNotEmpty) debugPrint('gravix-beauty: $warnings');
    }
  }

  Future<void> _close() async {
    final cam = _camera;
    _camera = null;
    _track = null;
    if (cam != null) await cam.stop(); // also detaches the WebRTC output (its stop hook)
  }
}

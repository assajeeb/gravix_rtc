import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'gravix_music_channel.dart';

/// Snapshot of the native music mixer's state.
class MusicState {
  const MusicState({
    required this.active,
    required this.paused,
    required this.positionMs,
    required this.durationMs,
    this.captureReady = false,
    this.captureLive = false,
    this.captureSampleRate = 0,
  });

  /// A decoded session is running (playing or paused).
  final bool active;

  /// The running session is paused.
  final bool paused;

  /// Playback position in milliseconds of the samples actually consumed by
  /// the outgoing capture stream (i.e. what listeners have heard).
  final int positionMs;

  /// Total decoded duration in milliseconds, or -1 while unknown.
  final int durationMs;

  /// The capture callback has run at least once (the mix format is known).
  final bool captureReady;

  /// The capture callback ran within the last 500 ms (the recorder is live).
  final bool captureLive;

  /// The live capture rate the music is resampled to (0 while unknown).
  final int captureSampleRate;

  factory MusicState.fromMap(Map<dynamic, dynamic> map) {
    return MusicState(
      active: map['active'] == true,
      paused: map['paused'] == true,
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? -1,
      captureReady: map['captureReady'] == true,
      captureLive: map['captureLive'] == true,
      captureSampleRate: (map['captureSampleRate'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Low-level Dart bridge for the background-music mixer (Android and iOS).
///
/// Apps: use [GravixRoomMusic] (state machine, mute integration, publish
/// settings, room lifecycle). This bridge only forwards calls.
///
/// Native side: the `com.gravitycompile.gravix_rtc/music` method channel
/// (`gravity.music_mixer` up to 0.4.9; see [kGravixMusicChannel]).
///  - Android: `com.gravitycompile.gravix_cloud.music.MusicMixerPlugin` decodes
///    a local audio file and mixes the PCM into the WebRTC microphone capture
///    buffer. Gain 0.0–2.0.
///  - iOS: `GravixMusicMixer` plays the file on an `AVAudioPlayerNode` inside
///    WebRTC's audio engine, connected to the engine's input mixer. Gain is
///    clamped to 0.0–1.0 and playback begins once the audio engine runs.
///
/// Either way **listeners** hear the music, and with `monitor` the host does
/// too.
///
/// ```dart
/// final music = GravixMusicController();
/// await music.start(path: file.path, gain: 0.6, monitor: true);
/// music.onCompleted.listen((_) => debugPrint('track finished'));
/// ```
class GravixMusicController {
  GravixMusicController({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(kGravixMusicChannel) {
    // Native -> Dart: `onCompleted` fires when a track finishes on its own.
    _hub = GravixMusicEventHub.of(_channel)..add(_handleNativeEvent);
  }

  final MethodChannel _channel;
  late final GravixMusicEventHub _hub;
  final StreamController<void> _onCompleted = StreamController.broadcast();

  bool _installed = false;
  bool _disposed = false;

  /// Broadcast stream that emits once every time the playing track ends
  /// naturally (native `onCompleted` event).
  Stream<void> get onCompleted => _onCompleted.stream;

  /// Installs the [AudioBufferCallback] into flutter_webrtc's audio device
  /// module (reflection-based, native side).
  ///
  /// Should run after `Room.connect` and BEFORE the microphone starts
  /// recording. [GravixRoomService.connect] calls this automatically; you only
  /// need to call it yourself when using the controller standalone.
  Future<bool> install() async {
    if (_installed) return true;
    // Before recording starts or after; the native side handles both with a
    // mic-cycle hint when needed.
    final ok = await _invoke<bool>('install') ?? false;
    if (ok) _installed = true;
    return ok;
  }

  /// Starts decoding [path] and mixing it into the outbound mic stream.
  ///
  /// [gain] is the music volume mixed into the capture buffer (0.0–2.0;
  /// 1.0 ≈ unity).
  ///
  /// [monitor] also plays the exact same samples locally so the HOST hears the
  /// music (devices with hardware echo cancellation strip this playout from
  /// the mic signal, so listeners won't hear it doubled/echoed).
  Future<bool> start({required String path, double gain = 1.0, bool monitor = true}) async {
    await install();
    final ok = await _invoke<bool>('start', {'path': path, 'gain': gain, 'monitor': monitor}) ?? false;
    return ok;
  }

  /// Pauses playback without stopping the decoded session.
  Future<void> pause() => _invoke<void>('pause');

  /// Resumes a paused session.
  Future<void> resume() => _invoke<void>('resume');

  /// Stops and tears down the current session, releasing native resources.
  Future<void> stop() async {
    await _invoke<void>('stop');
    _installed = false;
  }

  /// Adjusts the mix gain of a running session.
  Future<void> setVolume(double gain) => _invoke<void>('setVolume', {'gain': gain});

  /// Seeks the current track to [positionMs].
  Future<void> seekTo(int positionMs) => _invoke<void>('seekTo', {'positionMs': positionMs});

  /// Whether a music session is currently active.
  Future<bool> get isActive async => await _invoke<bool>('isActive') ?? false;

  /// Full mixer snapshot.
  Future<MusicState> getState() async {
    final map = await _invoke<Map<dynamic, dynamic>>('getState');
    if (map == null) {
      return const MusicState(active: false, paused: false, positionMs: 0, durationMs: -1);
    }
    return MusicState.fromMap(map);
  }

  Future<void> _handleNativeEvent(MethodCall call) async {
    switch (call.method) {
      case 'onCompleted':
        if (!_onCompleted.isClosed) _onCompleted.add(null);
      default:
        break;
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    if (_disposed) {
      throw StateError('GravixMusicController is disposed');
    }
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      if (kDebugMode) {
        debugPrint(
          '$kGravixMusicChannel unavailable — the gravix_rtc native plugin '
          'is not registered on this platform (music mixing runs on Android and iOS)',
        );
      }
      return null;
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('$kGravixMusicChannel $method failed: ${e.message}');
      }
      rethrow;
    }
  }

  /// Releases the broadcast stream. Waiting/currently-decoding native sessions
  /// are stopped via the plugin's engine detach; call [stop] explicitly to
  /// stop music deterministically.
  void dispose() {
    _disposed = true;
    _hub.remove(_handleNativeEvent);
    unawaited(_onCompleted.close());
  }
}

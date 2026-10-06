// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../rtc_core/gravix_client.dart';
import '../rtc_core/src/core/signal_client.dart' show SignalClientRequests;
import '../rtc_core/src/track/local/mic_uplink_pause.dart' show MicUplinkPause;
import '../rtc_core/src/track/local/mic_republish.dart';
import '../rtc_core/src/track/local/music_voice_mute.dart';
import 'gravix_music_channel.dart';

/// Where a room-music session is.
enum GravixMusicStatus { idle, loading, playing, paused, error }

/// Why a room-music call failed.
enum GravixMusicErrorCode {
  /// No mixer on this platform, or an Android-only call on iOS.
  unsupported,

  /// No connected room.
  notConnected,

  /// The local microphone is not published (music rides on the mic track).
  noMicrophone,

  /// The microphone capture did not run within the wait (format unknown).
  captureNotReady,

  /// The source is missing or unreadable, has no audio track, or the device
  /// has no decoder for it.
  openFailed,

  /// The native capture hook could not be installed.
  installFailed,

  /// The decoder failed in the middle of a track.
  decodeFailed,

  /// Any other native error.
  platform,
}

/// A room-music failure. [code] is stable; [message] is for logs.
class GravixMusicException implements Exception {
  const GravixMusicException(this.code, this.message);

  final GravixMusicErrorCode code;
  final String message;

  @override
  String toString() => 'GravixMusicException(${code.name}): $message';
}

enum _SourceKind { file, contentUri, asset }

/// What to play: a local file, an Android `content://` URI or a Flutter asset.
@immutable
class GravixMusicSource {
  /// An absolute file path (mp3, aac/m4a, wav, ogg, flac: what the device's
  /// decoders support).
  const GravixMusicSource.file(String path) : this._(_SourceKind.file, path, null);

  /// An Android `content://` URI (e.g. a document picker result), read in place.
  const GravixMusicSource.contentUri(String uri) : this._(_SourceKind.contentUri, uri, null);

  /// A Flutter asset, copied once to the app's cache directory.
  const GravixMusicSource.asset(String key, {String? package}) : this._(_SourceKind.asset, key, package);

  const GravixMusicSource._(this._kind, this.value, this.package);

  final _SourceKind _kind;

  /// The path, URI or asset key.
  final String value;

  /// The asset's package (assets only).
  final String? package;

  bool get isFile => _kind == _SourceKind.file;
  bool get isContentUri => _kind == _SourceKind.contentUri;
  bool get isAsset => _kind == _SourceKind.asset;

  @override
  bool operator ==(Object other) =>
      other is GravixMusicSource && other._kind == _kind && other.value == value && other.package == package;

  @override
  int get hashCode => Object.hash(_kind, value, package);

  @override
  String toString() => 'GravixMusicSource.${_kind.name}($value${package == null ? '' : ', package: $package'})';
}

/// Defaults for a [GravixRoomMusic].
@immutable
class GravixMusicOptions {
  const GravixMusicOptions({
    this.musicVolume = 1.0,
    this.micVolume = 1.0,
    this.ducking = false,
    this.duckLevel = 0.35,
    this.loop = false,
    this.monitor = true,
    this.musicMaxBitrate = 96000,
    this.continueWhileMicMuted = true,
    this.pauseOnInterruption = true,
    this.disableDtxWhileMusic = true,
    this.relaxVoiceProcessing = true,
  });

  /// Music level, 0..1, in the mix and in the host's monitor.
  final double musicVolume;

  /// Voice level in the mix, 0..1 (Android).
  final double micVolume;

  /// Lower the music while the host talks (Android).
  final bool ducking;

  /// The music gain while ducked (0..1).
  final double duckLevel;

  /// Play the track again from the start when it ends.
  final bool loop;

  /// The host hears the music locally.
  final bool monitor;

  /// The microphone sender's maxBitrate while music plays (bps), set through
  /// RTP sender parameters (no republish) and restored when the music stops.
  /// RED, when on, doubles the rate on the wire. 0 = leave the bitrate alone.
  final int musicMaxBitrate;

  /// While music plays, a mic mute removes only the voice and the music keeps
  /// reaching the room (Android). False: a mute silences voice and music.
  final bool continueWhileMicMuted;

  /// Pause on a phone call or an audio-focus loss; a transient interruption
  /// resumes by itself (Android).
  final bool pauseOnInterruption;

  /// A microphone published with DTX on is republished once with DTX off for
  /// the music (Opus DTX treats quiet music as silence) and once with DTX back
  /// on when it stops. Nothing happens for a DTX-off microphone (the default).
  final bool disableDtxWhileMusic;

  /// Software noise suppression and auto gain control off while music plays
  /// (they run after the mixer and flatten / pump the music); restored after.
  /// Echo cancellation stays on.
  final bool relaxVoiceProcessing;
}

/// A snapshot of the room music.
@immutable
class GravixMusicState {
  const GravixMusicState({
    this.status = GravixMusicStatus.idle,
    this.source,
    this.position = Duration.zero,
    this.duration,
    this.interrupted = false,
    this.musicVolume = 1.0,
    this.micVolume = 1.0,
    this.ducking = false,
    this.loop = false,
    this.error,
  });

  final GravixMusicStatus status;

  /// The current (or last) track.
  final GravixMusicSource? source;

  /// What listeners have heard of the track so far.
  final Duration position;

  /// The track's length, null while unknown.
  final Duration? duration;

  /// Paused by a phone call or an audio-focus loss; resumes by itself.
  final bool interrupted;

  final double musicVolume;
  final double micVolume;
  final bool ducking;
  final bool loop;

  /// The failure, when [status] is [GravixMusicStatus.error].
  final GravixMusicException? error;

  /// Playing or paused (a session holds the native decoder).
  bool get isActive => status == GravixMusicStatus.playing || status == GravixMusicStatus.paused;

  GravixMusicState copyWith({
    GravixMusicStatus? status,
    GravixMusicSource? source,
    Duration? position,
    Duration? duration,
    bool clearDuration = false,
    bool? interrupted,
    double? musicVolume,
    double? micVolume,
    bool? ducking,
    bool? loop,
    GravixMusicException? error,
    bool clearError = false,
  }) => GravixMusicState(
    status: status ?? this.status,
    source: source ?? this.source,
    position: position ?? this.position,
    duration: clearDuration ? null : (duration ?? this.duration),
    interrupted: interrupted ?? this.interrupted,
    musicVolume: musicVolume ?? this.musicVolume,
    micVolume: micVolume ?? this.micVolume,
    ducking: ducking ?? this.ducking,
    loop: loop ?? this.loop,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  String toString() =>
      'GravixMusicState(${status.name}, $source, ${position.inMilliseconds}/${duration?.inMilliseconds} ms'
      '${interrupted ? ', interrupted' : ''}${error == null ? '' : ', $error'})';
}

/// Room music: a local file mixed into the published microphone on the phone.
///
/// One published audio stream (the host's mic carries voice + music), no
/// second track, no server bot, no upload. Android mixes in WebRTC's capture
/// callback; iOS plays into the WebRTC audio engine's input mixer.
///
/// ```dart
/// final music = GravixRoomMusic(room);
/// await music.start(GravixMusicSource.file(path));
/// music.state.addListener(() => print(music.state.value));
/// await music.stop();
/// ```
///
/// Behaviour (see the README "Room music" section for details):
///  - needs a connected room with the local microphone published;
///  - a mic mute while music plays is a voice-only mute (Android,
///    [GravixMusicOptions.continueWhileMicMuted]): the music keeps going out and
///    remote participants see the mic as on;
///  - the mic sender's bitrate is raised to [GravixMusicOptions.musicMaxBitrate]
///    while music plays and restored after;
///  - phone calls / audio-focus loss pause the music (Android);
///  - a room disconnect stops the music and releases the native decoder.
class GravixRoomMusic {
  /// Binds to [room] now, or later with [attach] (GravixRoomService does that
  /// for every connect).
  GravixRoomMusic(
    Room? room, {
    this.options = const GravixMusicOptions(),
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting Duration pollInterval = const Duration(milliseconds: 250),
    @visibleForTesting Duration captureTimeout = const Duration(seconds: 3),
    @visibleForTesting Future<String> Function(GravixMusicSource source)? assetResolver,
    @visibleForTesting Future<bool> Function(String path)? fileExists,
    @visibleForTesting Future<LocalAudioTrack> Function(AudioCaptureOptions options)? createMicTrack,
    @visibleForTesting Future<void> Function(LocalAudioTrack track, AudioPublishOptions options)? publishMicTrack,
    @visibleForTesting Future<void> Function(String sid)? unpublishMicTrack,
    @visibleForTesting Duration republishRetryDelay = const Duration(milliseconds: 400),
  }) : _fileExists = fileExists ?? ((p) => File(p).exists()),
       _createMicTrack = createMicTrack,
       _publishMicTrack = publishMicTrack,
       _unpublishMicTrack = unpublishMicTrack,
       _republishRetryDelay = republishRetryDelay,
       _channel = channel ?? const MethodChannel(kGravixMusicChannel),
       _pollInterval = pollInterval,
       _captureTimeout = captureTimeout,
       _assetResolver = assetResolver {
    _state = ValueNotifier(
      GravixMusicState(
        musicVolume: options.musicVolume.clamp(0.0, 1.0),
        micVolume: options.micVolume.clamp(0.0, 1.0),
        ducking: options.ducking,
        loop: options.loop,
      ),
    );
    _hub = GravixMusicEventHub.of(_channel)..add(_onNative);
    if (room != null) attach(room);
  }

  /// The defaults this object was created with.
  final GravixMusicOptions options;

  final MethodChannel _channel;
  final Duration _pollInterval;
  final Duration _captureTimeout;
  final Future<String> Function(GravixMusicSource source)? _assetResolver;
  final Future<bool> Function(String path) _fileExists;
  late final GravixMusicEventHub _hub;
  late final ValueNotifier<GravixMusicState> _state;
  final _states = StreamController<GravixMusicState>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<GravixMusicException>.broadcast();

  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  bool _disposed = false;
  Timer? _poll;
  bool _polling = false;
  Future<void> _queue = Future<void>.value();

  // tests: the republish's track/publish seams (null = the real ones)
  final Future<LocalAudioTrack> Function(AudioCaptureOptions options)? _createMicTrack;
  final Future<void> Function(LocalAudioTrack track, AudioPublishOptions options)? _publishMicTrack;
  final Future<void> Function(String sid)? _unpublishMicTrack;
  final Duration _republishRetryDelay;

  // the music session's hold on the microphone
  LocalAudioTrack? _sessionTrack;
  bool Function(Object track)? _voicePredicate;
  bool _dtxSwapped = false;
  Object? _bitrateSender;
  int? _bitrateBefore;
  bool _bitrateApplied = false;

  /// Platform override for tests (null: the real platform).
  @visibleForTesting
  static PlatformType? debugPlatform;

  static PlatformType? get _platform {
    final p = debugPlatform;
    if (p != null) return p;
    if (kIsWeb || lkPlatformIsTest()) return null;
    return lkPlatform();
  }

  static bool get _android => _platform == PlatformType.android;

  /// Android and iOS have a mixer; other platforms throw `unsupported`.
  static bool get isSupported => _platform == PlatformType.android || _platform == PlatformType.iOS;

  /// The current state; listen for changes.
  ValueListenable<GravixMusicState> get state => _state;

  /// Every state change, as a stream.
  Stream<GravixMusicState> get states => _states.stream;

  /// A track ended on its own (not emitted while looping, nor on [stop]).
  Stream<void> get completed => _completed.stream;

  /// Failures, including asynchronous ones (a decoder failing mid-track).
  Stream<GravixMusicException> get errors => _errors.stream;

  /// The room the music is bound to.
  Room? get room => _room;

  /// Binds to [room]. A session on another room is stopped first.
  void attach(Room room) {
    _checkUsable();
    if (identical(_room, room)) return;
    final old = _room;
    if (old != null) unawaited(_serial(() => _teardown(roomGone: true)));
    unawaited(_roomListener?.dispose());
    _room = room;
    // Early: from now on the native side installs the hook before every
    // microphone capture start, so a capture started later picks it up with
    // certainty. Best effort (no room / no plugin yet is fine).
    if (isSupported) {
      unawaited(_channel.invokeMethod<bool>('install').then<void>((_) {}, onError: (Object _) {}));
    }
    _roomListener = room.createListener()
      ..on<RoomDisconnectedEvent>((_) {
        if (!identical(_room, room)) return;
        unawaited(_serial(() => _teardown(roomGone: true)));
      })
      ..on<LocalTrackPublishedEvent>((e) {
        // a republish (RED auto, DTX swap, full reconnect) brings a new sender
        if (!identical(_room, room) || e.publication.source != TrackSource.microphone) return;
        final t = e.publication.track;
        if (_sessionTrack == null || t is! LocalAudioTrack) return;
        _sessionTrack = t;
        _bitrateApplied = false;
        unawaited(_applyBitrate(t));
      });
  }

  // ---------------------------------------------------------------- control

  /// Starts [source], replacing a running track. Throws [GravixMusicException].
  Future<void> start(GravixMusicSource source, {bool? loop, double? volume}) =>
      _serial(() => _start(source, loop: loop, volume: volume));

  /// Pauses (the session and the publish settings stay).
  Future<void> pause() => _serial(() async {
    if (!_state.value.isActive) return;
    await _invoke<void>('pause');
    _set(_state.value.copyWith(status: GravixMusicStatus.paused, interrupted: false));
  });

  /// Resumes a paused (or interrupted) track.
  Future<void> resume() => _serial(() async {
    if (!_state.value.isActive) return;
    await _invoke<void>('resume');
    _set(_state.value.copyWith(status: GravixMusicStatus.playing, interrupted: false));
  });

  /// Stops and releases the decoder; restores the microphone's settings.
  Future<void> stop() => _serial(() async {
    if (_state.value.status == GravixMusicStatus.idle) return;
    await _stopNative();
    await _endSession();
    _set(_state.value.copyWith(status: GravixMusicStatus.idle, interrupted: false, clearError: true));
  });

  /// The room is being left (GravixRoomService.disconnect, 0.4.12): the mixer
  /// stops and the session ends without touching the microphone (no DTX
  /// republish, no restore); the leave unpublishes and stops the mic itself.
  @internal
  Future<void> stopForLeave() => _serial(() => _teardown(roomGone: true));

  /// Jumps within the current track (no-op when idle).
  Future<void> seek(Duration position) => _serial(() async {
    if (!_state.value.isActive) return;
    final ms = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
    await _invoke<void>('seek', {'positionMs': ms});
    _set(_state.value.copyWith(position: Duration(milliseconds: ms)));
  });

  /// Music level, 0..1 (kept for the next track when idle).
  Future<void> setMusicVolume(double volume) => _serial(() async {
    final v = volume.clamp(0.0, 1.0).toDouble();
    if (_state.value.isActive) await _invoke<void>('setMusicVolume', {'volume': v});
    _set(_state.value.copyWith(musicVolume: v));
  });

  /// Voice level in the mix, 0..1 (Android).
  Future<void> setMicVolume(double volume) => _serial(() async {
    _requireAndroid('setMicVolume');
    final v = volume.clamp(0.0, 1.0).toDouble();
    if (_state.value.isActive) await _invoke<void>('setMicVolume', {'volume': v});
    _set(_state.value.copyWith(micVolume: v));
  });

  /// Music dips while the host talks (Android).
  Future<void> setDucking(bool on) => _serial(() async {
    _requireAndroid('setDucking');
    if (_state.value.isActive) await _invoke<void>('setDucking', {'on': on, 'level': options.duckLevel});
    _set(_state.value.copyWith(ducking: on));
  });

  /// Loop the track.
  Future<void> setLoop(bool on) => _serial(() async {
    if (_state.value.isActive) await _invoke<void>('setLoop', {'on': on});
    _set(_state.value.copyWith(loop: on));
  });

  /// Stops the music, releases everything; the object is unusable after.
  Future<void> dispose() async {
    if (_disposed) return;
    await _serial(() async {
      if (_state.value.status != GravixMusicStatus.idle) {
        await _stopNative();
        await _endSession();
      }
    });
    _disposed = true;
    _stopPolling();
    _hub.remove(_onNative);
    await _roomListener?.dispose();
    _roomListener = null;
    _room = null;
    await _states.close();
    await _completed.close();
    await _errors.close();
    _state.dispose();
  }

  // ---------------------------------------------------------------- internals

  Future<void> _start(GravixMusicSource source, {bool? loop, double? volume}) async {
    _checkUsable();
    if (!isSupported) {
      throw _raise(const GravixMusicException(GravixMusicErrorCode.unsupported, 'room music needs Android or iOS'));
    }
    final room = _room;
    if (room == null || room.connectionState == ConnectionState.disconnected) {
      throw _raise(const GravixMusicException(GravixMusicErrorCode.notConnected, 'no connected room'));
    }
    final pub = room.localParticipant?.getTrackPublicationBySource(TrackSource.microphone);
    final track = pub?.track;
    if (pub == null || track is! LocalAudioTrack) {
      throw _raise(
        const GravixMusicException(GravixMusicErrorCode.noMicrophone, 'publish the microphone before playing music'),
      );
    }
    final s0 = _state.value;
    final musicVolume = (volume ?? s0.musicVolume).clamp(0.0, 1.0).toDouble();
    final doLoop = loop ?? s0.loop;
    _set(
      s0.copyWith(
        status: GravixMusicStatus.loading,
        source: source,
        position: Duration.zero,
        clearDuration: true,
        interrupted: false,
        musicVolume: musicVolume,
        loop: doLoop,
        clearError: true,
      ),
    );
    try {
      final path = await _resolve(source);
      // a missing file fails here, before the microphone is touched (a DTX
      // swap would otherwise republish it twice for nothing; phone 2026-10-06)
      if (source.isFile && !await _fileExists(path)) {
        throw GravixMusicException(GravixMusicErrorCode.openFailed, 'no such file: $path');
      }
      await _beginSession(pub, track);
      final installed = await _invoke<bool>('install') ?? false;
      if (!installed) {
        throw const GravixMusicException(
          GravixMusicErrorCode.installFailed,
          'the native capture hook could not be installed',
        );
      }
      if (_android) await _waitForCapture();
      final res = await _invoke<Object?>('start', {
        'source': path,
        'contentUri': source.isContentUri,
        'loop': doLoop,
        'monitor': options.monitor,
        'musicVolume': musicVolume,
        'micVolume': _state.value.micVolume,
        'ducking': _state.value.ducking,
        'duckLevel': options.duckLevel,
        'holdOnMute': !options.continueWhileMicMuted,
        'pauseOnInterruption': options.pauseOnInterruption,
      });
      final durMs = res is Map ? (res['durationMs'] as num?)?.toInt() : null;
      _set(
        _state.value.copyWith(
          status: GravixMusicStatus.playing,
          duration: durMs != null && durMs > 0 ? Duration(milliseconds: durMs) : null,
        ),
      );
      _startPolling();
    } on GravixMusicException catch (e) {
      await _abortStart();
      throw _raise(e);
    } on PlatformException catch (e) {
      await _abortStart();
      throw _raise(_map(e));
    } on MissingPluginException {
      await _abortStart();
      throw _raise(const GravixMusicException(GravixMusicErrorCode.unsupported, 'the music plugin is not registered'));
    }
  }

  Future<void> _abortStart() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
    await _endSession();
  }

  Future<String> _resolve(GravixMusicSource source) async {
    if (!source.isAsset) return source.value;
    final custom = _assetResolver;
    if (custom != null) return custom(source);
    final key = source.package == null ? source.value : 'packages/${source.package}/${source.value}';
    try {
      final data = await rootBundle.load(key);
      final dir = Directory('${Directory.systemTemp.path}/gravix_music');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/${key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}');
      if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
        await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      return file.path;
    } catch (e) {
      throw GravixMusicException(GravixMusicErrorCode.openFailed, 'asset $key: $e');
    }
  }

  Future<void> _waitForCapture() async {
    final deadline = DateTime.now().add(_captureTimeout);
    while (true) {
      final st = await _invoke<Map<dynamic, dynamic>>('getState');
      if (st?['captureLive'] == true) return;
      if (DateTime.now().isAfter(deadline)) {
        throw const GravixMusicException(
          GravixMusicErrorCode.captureNotReady,
          'the microphone capture is not running (is the mic published?)',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Takes the microphone for music: voice-only mute, relaxed voice
  /// processing, DTX off, music bitrate.
  Future<void> _beginSession(LocalTrackPublication pub, LocalAudioTrack track) async {
    if (identical(_sessionTrack, track)) return;
    if (_sessionTrack != null) await _endSession();
    _sessionTrack = track;
    if (options.continueWhileMicMuted && _android) {
      // Any local microphone track while the session runs: the app (or a
      // republish) may replace the track object in the middle of a session.
      bool p(Object t) => _sessionTrack != null && t is LocalAudioTrack && t.source == TrackSource.microphone;
      _voicePredicate = p;
      GravixMusicVoiceMute.predicate = p;
      debugPrint('room music: voice-only mute armed (a mic mute keeps the music)');
      if (track.muted && await track.enterMusicVoiceMute()) {
        debugPrint('room music: mic was muted; voice stays muted, music goes out');
        _sendMute(pub.sid, false);
      }
    }
    if (options.relaxVoiceProcessing) await _relaxProcessing(track);
    if (options.disableDtxWhileMusic && (track.lastPublishOptions?.dtx ?? false)) {
      final (fresh, swapped) = await _republish(track, dtx: false);
      if (fresh != null) _sessionTrack = fresh;
      _dtxSwapped = swapped;
    }
    final current = _sessionTrack;
    if (current != null) await _applyBitrate(current);
  }

  /// Gives the microphone back: bitrate, mute signal, voice processing, DTX.
  Future<void> _endSession({bool roomGone = false}) async {
    final pub = _room?.localParticipant?.getTrackPublicationBySource(TrackSource.microphone);
    final live = pub?.track;
    // the published mic (the app may have replaced the session's track)
    final track = live is LocalAudioTrack ? live : _sessionTrack;
    final sessionTrack = _sessionTrack;
    _sessionTrack = null;
    if (identical(GravixMusicVoiceMute.predicate, _voicePredicate)) GravixMusicVoiceMute.predicate = null;
    _voicePredicate = null;
    _stopPolling();
    final dtxSwapped = _dtxSwapped;
    _dtxSwapped = false;
    final processingBefore = _processingBefore;
    _processingBefore = null;
    if (track == null) return;
    // GRAVIX(0.4.12): a room that is leaving (or gone) gets nothing back: no
    // DTX republish, no bitrate or processing restore. Field 2026-10-06: the
    // app's leave stopped the music, the stop republished the mic during the
    // disconnect, and the failed republish left the microphone open after the
    // leave. The leave unpublishes and stops the microphone itself.
    final room = _room;
    if (!roomGone && (room == null || !room.gravixCanRepublish)) {
      debugPrint('room music: ended while the room is leaving; the mixer stops, the microphone is left to the leave');
      roomGone = true;
    }
    if (roomGone) {
      _bitrateApplied = false;
      await track.leaveMusicVoiceMute();
      if (sessionTrack != null && !identical(sessionTrack, track)) await sessionTrack.leaveMusicVoiceMute();
      return;
    }
    // bitrate first: the mute cap below remembers the rate it replaces
    await _restoreBitrate(track);
    if (await track.leaveMusicVoiceMute()) {
      if (pub != null && identical(pub.track, track)) _sendMute(pub.sid, true);
      debugPrint('room music: ended while muted -> a normal mute now');
    }
    if (processingBefore != null) await _setProcessing(track, processingBefore);
    if (dtxSwapped) await _republish(track, dtx: true);
  }

  AudioProcessingOptions? _processingBefore;

  /// Software noise suppression and AGC run AFTER the mixer (WebRTC's APM is
  /// native, the mix happens in the Java capture callback): they flatten a
  /// steady tone within seconds and pump the music. Off while music plays;
  /// echo cancellation and the high-pass filter stay as they were.
  Future<void> _relaxProcessing(LocalAudioTrack track) async {
    final before = track.currentOptions.processing;
    if (!before.noiseSuppression && !before.autoGainControl) return;
    final relaxed = AudioProcessingOptions(
      echoCancellation: before.echoCancellation,
      noiseSuppression: false,
      autoGainControl: false,
      highPassFilter: before.highPassFilter,
      echoCancellationMode: before.echoCancellationMode,
      noiseSuppressionMode: before.noiseSuppressionMode,
      autoGainControlMode: before.autoGainControlMode,
      highPassFilterMode: before.highPassFilterMode,
    );
    if (await _setProcessing(track, relaxed)) _processingBefore = before;
  }

  Future<bool> _setProcessing(LocalAudioTrack track, AudioProcessingOptions o) async {
    try {
      await track.setAudioProcessingOptions(o);
      return true;
    } catch (e) {
      debugPrint('room music: voice processing not changed: $e');
      return false;
    }
  }

  void _sendMute(String sid, bool muted) {
    try {
      _room?.engine.signalClient.sendMuteTrack(sid, muted);
    } catch (e) {
      debugPrint('room music: mute signal failed: $e');
    }
  }

  /// The microphone again with [dtx] on a NEW track (removePublishedTrack
  /// disposes the old one; the capture and the mixer hook are the audio device
  /// module's, so they carry on). Returns the published track and whether it
  /// went out with [dtx]. The host is never left without a microphone: a
  /// failed publish is retried with the original options.
  Future<(LocalAudioTrack?, bool)> _republish(LocalAudioTrack track, {required bool dtx}) async {
    final room = _room;
    final local = room?.localParticipant;
    if (room == null || local == null) return (null, false);
    final base = track.lastPublishOptions ?? room.roomOptions.defaultAudioPublishOptions;
    final (fresh, ok) = await gravixRepublishMic(
      local,
      track,
      wanted: base.copyWith(dtx: dtx),
      fallback: base,
      createTrack: _createMicTrack,
      publish: _publishMicTrack,
      unpublish: _unpublishMicTrack,
      retryDelay: _republishRetryDelay,
      // the room still connected and not leaving (0.4.12): a republish racing
      // a leave must not leave a track or a capture behind
      stillWanted: () => identical(_room, room) && room.gravixCanRepublish,
    );
    debugPrint('room music: microphone republished=${fresh != null} dtx=${ok ? dtx : base.dtx}');
    return (fresh, ok);
  }

  Future<void> _applyBitrate(LocalAudioTrack track) async {
    final target = options.musicMaxBitrate;
    if (target <= 0 || _bitrateApplied || track.wireMuted) return;
    final sender = track.sender;
    if (sender == null) return;
    try {
      final params = sender.parameters;
      final enc = params.encodings;
      if (enc == null || enc.isEmpty) return;
      final before = enc.first.maxBitrate;
      if (before != null && before >= target) return; // already as high
      enc.first.maxBitrate = target;
      if (await sender.setParameters(params)) {
        _bitrateSender = sender;
        _bitrateBefore = before;
        _bitrateApplied = true;
      } else {
        enc.first.maxBitrate = before; // the cache must match the native side
      }
    } catch (e) {
      debugPrint('room music: bitrate not applied: $e');
    }
  }

  Future<void> _restoreBitrate(LocalAudioTrack track) async {
    final sender = track.sender;
    final applied = _bitrateApplied && identical(_bitrateSender, sender);
    final before = _bitrateBefore;
    _bitrateApplied = false;
    _bitrateSender = null;
    _bitrateBefore = null;
    if (!applied || sender == null) return;
    try {
      final params = sender.parameters;
      final enc = params.encodings;
      if (enc == null || enc.isEmpty) return;
      // someone else (the audio-first policy) moved it meanwhile: theirs now
      if (enc.first.maxBitrate != options.musicMaxBitrate) return;
      enc.first.maxBitrate = before ?? MicUplinkPause.opusMaxBitrate;
      if (!await sender.setParameters(params)) enc.first.maxBitrate = options.musicMaxBitrate;
    } catch (e) {
      debugPrint('room music: bitrate not restored: $e');
    }
  }

  Future<void> _teardown({required bool roomGone}) async {
    if (_state.value.status == GravixMusicStatus.idle && _sessionTrack == null) return;
    await _stopNative();
    await _endSession(roomGone: roomGone);
    _set(_state.value.copyWith(status: GravixMusicStatus.idle, interrupted: false));
  }

  Future<void> _stopNative() async {
    _stopPolling();
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('room music: native stop failed: $e');
    }
  }

  Future<void> _onNative(MethodCall call) async {
    if (_disposed) return;
    switch (call.method) {
      case 'onCompleted':
        await _serial(() async {
          if (!_state.value.isActive) return;
          await _stopNative();
          await _endSession();
          _set(
            _state.value.copyWith(
              status: GravixMusicStatus.idle,
              position: _state.value.duration ?? _state.value.position,
              interrupted: false,
            ),
          );
          if (!_completed.isClosed) _completed.add(null);
        });
      case 'onError':
        final args = call.arguments is Map ? call.arguments as Map : const {};
        final e = _mapCode(args['code']?.toString(), args['message']?.toString() ?? 'native error');
        await _serial(() async {
          if (_state.value.status == GravixMusicStatus.idle) return;
          await _stopNative();
          await _endSession();
          _raise(e);
        });
      case 'onInterruption':
        final args = call.arguments is Map ? call.arguments as Map : const {};
        final active = args['active'] == true;
        final reason = args['reason']?.toString();
        if (!_state.value.isActive) return;
        if (active) {
          _set(_state.value.copyWith(status: GravixMusicStatus.paused, interrupted: reason != 'focusLoss'));
        } else {
          _set(_state.value.copyWith(status: GravixMusicStatus.playing, interrupted: false));
        }
      default:
        break;
    }
  }

  void _startPolling() {
    _stopPolling();
    _poll = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _pollOnce() async {
    if (_polling || _disposed || !_state.value.isActive) return;
    _polling = true;
    try {
      final st = await _channel.invokeMethod<Map<dynamic, dynamic>>('getState');
      if (st == null || _disposed || !_state.value.isActive) return;
      if (st['active'] != true) return; // the completion event handles the end
      final pos = (st['positionMs'] as num?)?.toInt() ?? -1;
      final dur = (st['durationMs'] as num?)?.toInt() ?? -1;
      final paused = st['paused'] == true;
      final interrupted = st['interrupted'] != null;
      final cur = _state.value;
      _set(
        cur.copyWith(
          position: pos >= 0 ? Duration(milliseconds: pos) : cur.position,
          duration: dur > 0 ? Duration(milliseconds: dur) : cur.duration,
          status: paused ? GravixMusicStatus.paused : GravixMusicStatus.playing,
          interrupted: interrupted,
        ),
      );
    } catch (_) {
      // a failed poll is not a failed track
    } finally {
      _polling = false;
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw _map(e);
    } on MissingPluginException {
      throw const GravixMusicException(GravixMusicErrorCode.unsupported, 'the music plugin is not registered');
    }
  }

  static GravixMusicException _map(PlatformException e) => _mapCode(e.code, e.message ?? e.code);

  static GravixMusicException _mapCode(String? code, String message) {
    final c = switch (code) {
      'NOT_INSTALLED' => GravixMusicErrorCode.installFailed,
      'CAPTURE_NOT_READY' => GravixMusicErrorCode.captureNotReady,
      'OPEN_FAILED' => GravixMusicErrorCode.openFailed,
      'DECODE_FAILED' => GravixMusicErrorCode.decodeFailed,
      'UNSUPPORTED' => GravixMusicErrorCode.unsupported,
      _ => GravixMusicErrorCode.platform,
    };
    return GravixMusicException(c, message);
  }

  void _requireAndroid(String what) {
    _checkUsable();
    // not a failed track: the state is left alone
    if (!_android) throw GravixMusicException(GravixMusicErrorCode.unsupported, '$what is Android-only');
  }

  GravixMusicException _raise(GravixMusicException e) {
    _set(_state.value.copyWith(status: GravixMusicStatus.error, error: e, interrupted: false));
    if (!_errors.isClosed) _errors.add(e);
    return e;
  }

  void _set(GravixMusicState s) {
    if (_disposed) return;
    _state.value = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _checkUsable() {
    if (_disposed) throw StateError('GravixRoomMusic is disposed');
  }

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _queue.then((_) => op());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}

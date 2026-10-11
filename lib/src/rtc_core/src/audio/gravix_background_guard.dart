// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show immutable, kIsWeb;
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:meta/meta.dart' show internal, visibleForTesting;

import '../core/room.dart';
import '../events.dart';
import '../logger.dart';
import '../managers/event.dart';
import '../support/native.dart';
import '../support/platform.dart';

/// When the SDK plays a silent keep-alive while the app is in the background
/// (see `GravixAudioDeviceOptions.backgroundKeepAlive`).
enum GravixBackgroundKeepAlive {
  /// Never (the default; the pre-0.4.15 behaviour).
  off,

  /// On every Android phone.
  on,

  /// Only on Transsion phones (Infinix, Tecno, itel), whose "Hiber" app
  /// freezer is the reason this exists.
  transsionOnly,
}

/// The process was not run for [frozenFor] while the device was awake: an
/// OEM app freezer (Transsion "Hiber" was seen doing this to a background
/// listener) stopped it. Its sockets may have been destroyed;
/// the room may have dropped.
@immutable
class GravixProcessFreezeEvent {
  const GravixProcessFreezeEvent({required this.frozenFor, required this.wallGap, required this.detectedAt});

  /// Time the process did not run while the device was awake (monotonic clock).
  final Duration frozenFor;

  /// Wall-clock time between the last two checks (includes device sleep).
  final Duration wallGap;

  /// When it was noticed (the first moment the process ran again).
  final DateTime detectedAt;

  @override
  String toString() =>
      'GravixProcessFreezeEvent(frozenFor: ${frozenFor.inMilliseconds} ms, '
      'wallGap: ${wallGap.inMilliseconds} ms)';
}

/// Transsion makes Infinix, Tecno and itel phones; their system ships the
/// "Hiber" freezer.
@internal
bool gravixIsTranssionDevice(String? manufacturer, String? brand) {
  bool hit(String? s) {
    final v = s?.toLowerCase() ?? '';
    return v.contains('infinix') || v.contains('tecno') || v.contains('itel') || v.contains('transsion');
  }

  return hit(manufacturer) || hit(brand);
}

/// The keep-alive plays only while all of this holds: a real playout (a
/// subscribed remote audio track keeps WebRTC's own player running) already is
/// the "audio out" the freezer respects.
@internal
bool gravixKeepAliveWanted({
  required GravixBackgroundKeepAlive mode,
  required bool isTranssion,
  required bool inRoom,
  required bool backgrounded,
  required bool remoteAudio,
}) {
  final enabled = switch (mode) {
    GravixBackgroundKeepAlive.off => false,
    GravixBackgroundKeepAlive.on => true,
    GravixBackgroundKeepAlive.transsionOnly => isTranssion,
  };
  return enabled && inRoom && backgrounded && !remoteAudio;
}

/// How much longer than [interval] the monotonic clock ran between two checks
/// before it counts as a freeze. Monotonic (Dart's Stopwatch, CLOCK_MONOTONIC)
/// does not advance while the device sleeps, so deep sleep is not a freeze;
/// a frozen process on an awake device is.
@internal
Duration? gravixFrozenFor({
  required Duration monotonicGap,
  required Duration interval,
  Duration threshold = const Duration(seconds: 3),
}) {
  if (monotonicGap <= interval + threshold) return null;
  return monotonicGap - interval;
}

/// Opt-in background protections against OEM app freezers (0.4.15, Android).
/// Rooms are attached from the same hooks as the mic monitor; nothing is
/// attached (no listener, no timer, no channel call) while both options are
/// off.
@internal
class GravixBackgroundGuard {
  GravixBackgroundGuard._();

  static final GravixBackgroundGuard instance = GravixBackgroundGuard._();

  /// Freeze check period while backgrounded (a Dart timer; it simply does not
  /// fire while the process is frozen).
  static const Duration freezeTickInterval = Duration(seconds: 2);

  GravixBackgroundKeepAlive get keepAliveMode => _mode;
  set keepAliveMode(GravixBackgroundKeepAlive value) {
    _mode = value;
    refresh();
  }

  bool get detectFreeze => _detectFreeze;
  set detectFreeze(bool value) {
    _detectFreeze = value;
    if (!value) _stopFreezeTimer();
  }

  GravixBackgroundKeepAlive _mode = GravixBackgroundKeepAlive.off;
  bool _detectFreeze = false;

  final StreamController<GravixProcessFreezeEvent> _freezes = StreamController<GravixProcessFreezeEvent>.broadcast();
  Stream<GravixProcessFreezeEvent> get freezes => _freezes.stream;

  final Map<Object, EventsListener<RoomEvent>?> _rooms = Map<Object, EventsListener<RoomEvent>?>.identity();
  AppLifecycleListener? _lifecycle;
  bool _backgrounded = false;
  bool _keepAliveOn = false;
  bool? _transsion;
  Timer? _freezeTimer;
  Duration? _lastMono;
  DateTime? _lastWall;
  final Stopwatch _stopwatch = Stopwatch()..start();

  // test seams
  @visibleForTesting
  Duration Function()? debugMonotonic;
  @visibleForTesting
  DateTime Function()? debugWall;
  @visibleForTesting
  bool? debugRemoteAudio;
  @visibleForTesting
  bool? debugIsTranssion;

  @visibleForTesting
  int get attachedRooms => _rooms.length;
  @visibleForTesting
  bool get freezeTimerRunning => _freezeTimer != null;
  @visibleForTesting
  void debugTick() => _tick();

  Duration get _mono => debugMonotonic?.call() ?? _stopwatch.elapsed;
  DateTime get _wall => debugWall?.call() ?? DateTime.now();

  bool get _android => !kIsWeb && lkPlatformIs(PlatformType.android);
  bool get _wanted => _mode != GravixBackgroundKeepAlive.off || _detectFreeze;

  void attachRoom(Object room) {
    if (!_android || !_wanted || _rooms.containsKey(room)) return;
    EventsListener<RoomEvent>? listener;
    if (room is Room) {
      listener = room.createListener()
        ..on<TrackSubscribedEvent>((_) => refresh())
        ..on<TrackUnsubscribedEvent>((_) => refresh())
        ..on<ParticipantDisconnectedEvent>((_) => refresh());
    }
    _rooms[room] = listener;
    if (_lifecycle == null) {
      _backgrounded = _currentlyBackgrounded();
      _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
      if (_backgrounded) _startFreezeTimer();
    }
    if (_mode == GravixBackgroundKeepAlive.transsionOnly && _transsion == null && debugIsTranssion == null) {
      unawaited(_resolveTranssion());
    }
    refresh();
  }

  void detachRoom(Object room) {
    if (!_rooms.containsKey(room)) return;
    unawaited(_rooms.remove(room)?.dispose());
    if (_rooms.isEmpty) {
      _lifecycle?.dispose();
      _lifecycle = null;
      _stopFreezeTimer();
    }
    refresh();
  }

  Future<void> _resolveTranssion() async {
    _transsion = await isAggressiveFreezer();
    refresh();
  }

  /// Whether this phone ships an app freezer known to stop background
  /// listeners despite a foreground service (Transsion: Infinix, Tecno, itel).
  static Future<bool> isAggressiveFreezer() async {
    if (kIsWeb || !lkPlatformIs(PlatformType.android)) return false;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return gravixIsTranssionDevice(info.manufacturer, info.brand);
    } catch (e) {
      logger.fine('isAggressiveFreezer: device info unavailable: $e');
      return false;
    }
  }

  bool _currentlyBackgrounded() {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == AppLifecycleState.hidden || s == AppLifecycleState.paused;
    } catch (_) {
      return false;
    }
  }

  void _onLifecycle(AppLifecycleState state) {
    final backgrounded = state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
    final visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (backgrounded && !_backgrounded) {
      _backgrounded = true;
      _startFreezeTimer();
      refresh();
    } else if (visible && _backgrounded) {
      // the first thing that runs after a thaw by an activity start
      if (_freezeTimer != null) _tick();
      _stopFreezeTimer();
      _backgrounded = false;
      refresh();
    }
  }

  bool get _remoteAudio {
    final o = debugRemoteAudio;
    if (o != null) return o;
    for (final room in _rooms.keys) {
      if (room is! Room) continue;
      for (final p in room.remoteParticipants.values) {
        if (p.audioTrackPublications.any((pub) => pub.subscribed)) return true;
      }
    }
    return false;
  }

  /// Re-evaluates the keep-alive. Cheap; called on every input change.
  void refresh() {
    final want =
        _android &&
        gravixKeepAliveWanted(
          mode: _mode,
          isTranssion: debugIsTranssion ?? _transsion ?? false,
          inRoom: _rooms.isNotEmpty,
          backgrounded: _backgrounded,
          remoteAudio: _rooms.isNotEmpty && _remoteAudio,
        );
    if (want == _keepAliveOn) return;
    _keepAliveOn = want;
    logger.info('background keep-alive ${want ? 'on' : 'off'}');
    unawaited(Native.setBackgroundKeepAlive(active: want));
  }

  void _startFreezeTimer() {
    if (!_detectFreeze || _freezeTimer != null || _rooms.isEmpty) return;
    _lastMono = _mono;
    _lastWall = _wall;
    _freezeTimer = Timer.periodic(freezeTickInterval, (_) => _tick());
  }

  void _stopFreezeTimer() {
    _freezeTimer?.cancel();
    _freezeTimer = null;
    _lastMono = null;
    _lastWall = null;
  }

  void _tick() {
    final mono = _mono;
    final wall = _wall;
    final lastMono = _lastMono;
    final lastWall = _lastWall;
    _lastMono = mono;
    _lastWall = wall;
    if (lastMono == null || lastWall == null) return;
    final frozen = gravixFrozenFor(monotonicGap: mono - lastMono, interval: freezeTickInterval);
    if (frozen == null) return;
    final event = GravixProcessFreezeEvent(frozenFor: frozen, wallGap: wall.difference(lastWall), detectedAt: wall);
    logger.warning('the process was frozen in the background: $event');
    _freezes.add(event);
  }

  @visibleForTesting
  void resetForTest() {
    for (final l in _rooms.values) {
      unawaited(l?.dispose());
    }
    _rooms.clear();
    _lifecycle?.dispose();
    _lifecycle = null;
    _stopFreezeTimer();
    _backgrounded = false;
    _keepAliveOn = false;
    _transsion = null;
    _mode = GravixBackgroundKeepAlive.off;
    _detectFreeze = false;
    debugMonotonic = null;
    debugWall = null;
    debugRemoteAudio = null;
    debugIsTranssion = null;
  }
}

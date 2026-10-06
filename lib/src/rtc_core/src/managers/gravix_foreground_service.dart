// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, kIsWeb;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:meta/meta.dart' show internal, visibleForTesting;

import '../logger.dart';
import '../support/native.dart';
import '../support/platform.dart';

/// How the Android call foreground service behaves. See [GravixForegroundService].
@immutable
class GravixForegroundServiceOptions {
  const GravixForegroundServiceOptions({
    this.enabled = false,
    this.notificationTitle,
    this.notificationText,
    this.showLeaveAction = false,
    this.leaveActionLabel,
    this.includeCamera = false,
  });

  /// Start the service automatically for every room (connect → start,
  /// microphone/camera publish → type upgrade, disconnect/dispose → stop).
  /// False (the default) = the SDK never starts it: no notification, no
  /// behaviour change.
  final bool enabled;

  /// Notification title; null = the app's label.
  final String? notificationTitle;

  /// Notification text; null = "In a room".
  final String? notificationText;

  /// Adds a "Leave" action to the notification. Tapping it emits on
  /// [GravixForegroundService.leaveRequests]; the app decides what leaving
  /// means (the SDK does not disconnect on its own).
  final bool showLeaveAction;

  /// Label of the Leave action; null = "Leave".
  final String? leaveActionLabel;

  /// Add the `camera` type when the camera is published (needs the CAMERA
  /// permission granted). Off: a video room's camera stops in the background
  /// as before, while the microphone and playback keep going.
  final bool includeCamera;

  GravixForegroundServiceOptions copyWith({
    bool? enabled,
    String? notificationTitle,
    String? notificationText,
    bool? showLeaveAction,
    String? leaveActionLabel,
    bool? includeCamera,
  }) => GravixForegroundServiceOptions(
    enabled: enabled ?? this.enabled,
    notificationTitle: notificationTitle ?? this.notificationTitle,
    notificationText: notificationText ?? this.notificationText,
    showLeaveAction: showLeaveAction ?? this.showLeaveAction,
    leaveActionLabel: leaveActionLabel ?? this.leaveActionLabel,
    includeCamera: includeCamera ?? this.includeCamera,
  );

  @override
  bool operator ==(Object other) =>
      other is GravixForegroundServiceOptions &&
      other.enabled == enabled &&
      other.notificationTitle == notificationTitle &&
      other.notificationText == notificationText &&
      other.showLeaveAction == showLeaveAction &&
      other.leaveActionLabel == leaveActionLabel &&
      other.includeCamera == includeCamera;

  @override
  int get hashCode =>
      Object.hash(enabled, notificationTitle, notificationText, showLeaveAction, leaveActionLabel, includeCamera);

  @override
  String toString() =>
      'GravixForegroundServiceOptions(enabled: $enabled, showLeaveAction: $showLeaveAction, '
      'includeCamera: $includeCamera)';
}

/// Android call foreground service: keeps the microphone, the room playback
/// and the room music working while the app is in the background, for hosts,
/// seated speakers and listeners.
///
/// Without it Android 11+ silences the microphone ~5 s after the app leaves
/// the screen ("App op 27 missing, silencing record"), which also silences
/// room music (it is mixed into the microphone).
///
/// **Disabled by default.** Turn it on once, before the first connect:
///
/// ```dart
/// GravixForegroundService.defaults = const GravixForegroundServiceOptions(
///   enabled: true,
///   notificationTitle: 'Live room',
///   notificationText: 'Tap to return',
///   showLeaveAction: true,
/// );
/// GravixForegroundService.leaveRequests.listen((_) => leaveTheRoom());
/// ```
///
/// Then every `Room.connect` (and `GravixRoomService.connect`) starts the
/// service as `mediaPlayback`; publishing the microphone adds the
/// `microphone` type (only when RECORD_AUDIO is granted); the room's
/// disconnect/dispose stops it. One room can opt in or out on its own with
/// `RoomOptions(foregroundService: ...)` / `GravixRoomService.connect(foregroundService: ...)`.
///
/// Apps that manage it themselves call [start] / [update] / [stop].
///
/// Android only; [isSupported] is false (and every call a no-op) on iOS and
/// the web. On iOS, `UIBackgroundModes: audio` with the SDK's
/// `playAndRecord` session already keeps both directions alive.
///
/// Android 14 rules: the service must be started while the app is visible
/// (the SDK starts it at connect), and the `microphone` type needs
/// RECORD_AUDIO granted at that moment. An upgrade asked for while the app is
/// in the background is applied when it returns.
class GravixForegroundService {
  GravixForegroundService._();

  /// Process-wide defaults; [GravixForegroundServiceOptions.enabled] is false.
  static GravixForegroundServiceOptions defaults = const GravixForegroundServiceOptions();

  /// Android (not the web).
  static bool get isSupported => !kIsWeb && lkPlatformIs(PlatformType.android);

  /// Whether the service is in the foreground.
  static bool get isRunning => _running;

  /// The types Android applied, e.g. `[mediaPlayback]` or `[microphone, mediaPlayback]`.
  static List<String> get activeTypes => List.unmodifiable(_typeNames);

  /// The notification's Leave action was tapped.
  static Stream<void> get leaveRequests => _leave.stream;

  /// Grace before an automatic stop once the last room let go, so a room being
  /// replaced (reconnect with a new token, the next region candidate) does not
  /// stop the service and then need to start it again from the background.
  @visibleForTesting
  static Duration stopGrace = const Duration(seconds: 3);

  static final StreamController<void> _leave = StreamController<void>.broadcast();
  static StreamSubscription<String>? _nativeEvents;

  static bool _running = false;
  static List<String> _typeNames = const <String>[];
  static GravixForegroundServiceOptions? _activeOptions;
  static bool _mic = false;
  static bool _camera = false;
  static bool _updatePending = false;
  static bool _manual = false;
  static final Map<Object, GravixForegroundServiceOptions> _rooms =
      Map<Object, GravixForegroundServiceOptions>.identity();
  static final Map<Object, void Function(bool backgrounded)> _backgroundSinks =
      Map<Object, void Function(bool backgrounded)>.identity();
  static Timer? _stopTimer;
  static Future<void> _queue = Future<void>.value();
  static AppLifecycleListener? _lifecycle;
  static bool? _lastBackgrounded;

  // ── public, for apps that drive it themselves ───────────────────────────

  /// Starts the service (or re-applies [options] / the flags when it runs).
  /// [micPublished] asks for the `microphone` type (granted only with
  /// RECORD_AUDIO). Call it while the app is visible. Works whether or not
  /// [defaults] is enabled. Returns whether the service is in the foreground.
  static Future<bool> start({
    GravixForegroundServiceOptions? options,
    bool micPublished = false,
    bool cameraPublished = false,
  }) {
    if (!isSupported) return Future<bool>.value(false);
    _manual = true;
    _stopTimer?.cancel();
    _mic = _mic || micPublished;
    _camera = _camera || cameraPublished;
    final opts = options ?? _activeOptions ?? defaults;
    return _serial(() => _ensureStarted(opts));
  }

  /// Changes the requested types (null = unchanged). An upgrade the OS refuses
  /// because the app is in the background is retried when it comes back.
  static Future<bool> update({bool? micPublished, bool? cameraPublished}) {
    if (!isSupported) return Future<bool>.value(false);
    if (micPublished != null) _mic = micPublished;
    if (cameraPublished != null) _camera = cameraPublished;
    return _serial(_applyUpdate);
  }

  /// Stops the service now (also any room's automatic hold).
  static Future<void> stop() {
    if (!isSupported) return Future<void>.value();
    _manual = false;
    _rooms.clear();
    return _serial(_stopNow);
  }

  // ── internal hooks (Room, LocalParticipant, GravixRoomService) ──────────

  /// The effective options for a room ([override] wins over [defaults]).
  @internal
  static GravixForegroundServiceOptions effective(GravixForegroundServiceOptions? override) => override ?? defaults;

  /// Room.connect: takes a hold for [room] when enabled. Never throws, never
  /// delays the join (the caller does not await the native start).
  @internal
  static Future<void> roomConnecting(Object room, GravixForegroundServiceOptions? override) {
    final opts = effective(override);
    if (!opts.enabled || !isSupported) return Future<void>.value();
    _stopTimer?.cancel();
    _rooms[room] = opts;
    return _serial(() => _ensureStarted(_activeOptions ?? opts));
  }

  /// A local microphone/camera publication of [room].
  @internal
  static Future<void> roomPublished(Object room, {bool microphone = false, bool camera = false}) {
    final opts = _rooms[room];
    if (opts == null) return Future<void>.value();
    final wantCamera = camera && opts.includeCamera;
    if ((!microphone || _mic) && (!wantCamera || _camera)) return Future<void>.value();
    if (microphone) _mic = true;
    if (wantCamera) _camera = true;
    return _serial(_applyUpdate);
  }

  /// Room disconnect/cleanup/dispose (or a failed connect): drops the hold;
  /// the service stops after [stopGrace] when nothing else holds it.
  @internal
  static void roomReleased(Object room) {
    if (_rooms.remove(room) == null) return;
    if (_rooms.isNotEmpty || _manual) return;
    _stopTimer?.cancel();
    if (stopGrace == Duration.zero) {
      unawaited(_serial(_stopIfUnheld));
    } else {
      _stopTimer = Timer(stopGrace, () => unawaited(_serial(_stopIfUnheld)));
    }
  }

  /// GravixRoomService: receives app background/foreground changes while the
  /// service is enabled for it (the SDK installs no lifecycle observer otherwise).
  @internal
  static void addBackgroundSink(Object owner, void Function(bool backgrounded) sink) {
    if (!isSupported) return;
    _backgroundSinks[owner] = sink;
    _syncLifecycle();
  }

  @internal
  static void removeBackgroundSink(Object owner) {
    if (_backgroundSinks.remove(owner) != null) _syncLifecycle();
  }

  @visibleForTesting
  static bool get lifecycleObserverInstalled => _lifecycle != null;

  @visibleForTesting
  static int get roomHolds => _rooms.length;

  @visibleForTesting
  static Future<void> idle() => _queue;

  @visibleForTesting
  static void resetForTest() {
    defaults = const GravixForegroundServiceOptions();
    stopGrace = const Duration(seconds: 3);
    _stopTimer?.cancel();
    _stopTimer = null;
    _running = false;
    _typeNames = const <String>[];
    _activeOptions = null;
    _mic = false;
    _camera = false;
    _updatePending = false;
    _manual = false;
    _rooms.clear();
    _backgroundSinks.clear();
    _lifecycle?.dispose();
    _lifecycle = null;
    _lastBackgrounded = null;
    _queue = Future<void>.value();
  }

  // ── implementation ──────────────────────────────────────────────────────

  static Future<T> _serial<T>(Future<T> Function() op) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await op());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  static void _listenNative() {
    _nativeEvents ??= Native.callServiceEvents.listen((event) {
      switch (event) {
        case 'leave':
          _leave.add(null);
        case 'stopped':
          if (_running) logger.info('call foreground service stopped');
          _running = false;
          _typeNames = const <String>[];
          _syncLifecycle();
      }
    });
  }

  static bool get _visible {
    final AppLifecycleState? state;
    try {
      state = WidgetsBinding.instance.lifecycleState;
    } catch (_) {
      return true; // no binding: nothing to go by
    }
    // null: no frame yet (cold start); inactive: a permission dialog is up
    return state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  }

  static Future<bool> _ensureStarted(GravixForegroundServiceOptions opts) async {
    _listenNative();
    _activeOptions = opts;
    _syncLifecycle();
    if (_running) return _applyUpdate();
    try {
      final reply = await Native.startCallService(
        notificationTitle: opts.notificationTitle,
        notificationText: opts.notificationText,
        showLeaveAction: opts.showLeaveAction,
        leaveActionLabel: opts.leaveActionLabel,
        microphone: _mic,
        camera: _camera,
      );
      _running = true;
      _readTypes(reply);
      _updatePending = _mic && !_typeNames.contains('microphone');
      logger.info('call foreground service started: $_typeNames');
      return true;
    } on PlatformException catch (e) {
      logger.warning('call foreground service did not start: ${e.message ?? e.code}');
      _running = false;
      _updatePending = true; // retried when the app is visible again
      return false;
    } on MissingPluginException {
      return false;
    } finally {
      _syncLifecycle();
    }
  }

  static Future<bool> _applyUpdate() async {
    if (!_running) {
      // a hold exists but the start failed (e.g. joined from the background): retry when visible
      if ((_rooms.isNotEmpty || _manual) && _visible) return _ensureStarted(_activeOptions ?? defaults);
      _updatePending = _rooms.isNotEmpty || _manual;
      return false;
    }
    if (!_visible) {
      // Android 14 refuses microphone/camera added from the background
      _updatePending = true;
      return false;
    }
    try {
      final reply = await Native.updateCallService(microphone: _mic, camera: _camera);
      _readTypes(reply);
      final error = reply['error'];
      _updatePending = error != null;
      if (error != null) logger.warning('call foreground service type update refused: $error');
      return error == null;
    } on PlatformException catch (e) {
      logger.warning('call foreground service update failed: ${e.message ?? e.code}');
      _updatePending = true;
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static void _readTypes(Map<String, Object?> reply) {
    final names = reply['typeNames'];
    if (names is List) _typeNames = names.whereType<String>().toList(growable: false);
  }

  static Future<void> _stopIfUnheld() async {
    if (_rooms.isNotEmpty || _manual) return;
    await _stopNow();
  }

  static Future<void> _stopNow() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    final wasActive = _running || _activeOptions != null;
    _running = false;
    _typeNames = const <String>[];
    _activeOptions = null;
    _mic = false;
    _camera = false;
    _updatePending = false;
    _syncLifecycle();
    if (wasActive) await Native.stopCallService();
  }

  /// The observer exists only while the service is in use (enabled and held)
  /// or a GravixRoomService that enabled it is connected.
  static void _syncLifecycle() {
    final want = _activeOptions != null || _backgroundSinks.isNotEmpty;
    if (want && _lifecycle == null) {
      _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
      _lastBackgrounded = !_visible;
    } else if (!want && _lifecycle != null) {
      _lifecycle!.dispose();
      _lifecycle = null;
      _lastBackgrounded = null;
    }
  }

  static void _onLifecycle(AppLifecycleState state) {
    // Nothing here mutes the microphone or the playout: background is exactly
    // when they must keep running.
    final backgrounded = state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
    final visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (state != AppLifecycleState.detached && backgrounded != _lastBackgrounded && (backgrounded || visible)) {
      _lastBackgrounded = backgrounded;
      for (final sink in _backgroundSinks.values.toList()) {
        try {
          sink(backgrounded);
        } catch (e) {
          logger.warning('setAppBackgrounded failed: $e');
        }
      }
    }
    if (visible && _updatePending && (_rooms.isNotEmpty || _manual)) {
      unawaited(_serial(_applyUpdate));
    }
  }
}

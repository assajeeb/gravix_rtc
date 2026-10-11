// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, kIsWeb;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:meta/meta.dart' show internal, visibleForTesting;

import '../core/room.dart';
import '../events.dart';
import '../logger.dart';
import '../managers/event.dart';
import '../managers/gravix_foreground_service.dart';
import '../support/native.dart';
import '../support/platform.dart';
import '../track/local/audio.dart';
import '../types/other.dart';
import 'gravix_other_app_audio.dart';

/// What the local microphone is doing, as far as the platform tells the SDK.
///
/// 0.4.15 (field report 2026-10-10, items 7a/7c): until now a microphone the
/// OS silenced (another app's call, a missing foreground-service type in the
/// background) produced one log line at most; the app could not tell the user
/// why the room could not hear them.
enum GravixMicState {
  /// No published, unmuted microphone (a listener, or muted).
  idle,

  /// The microphone is published, unmuted, and nothing reports a problem.
  active,

  /// The OS took the microphone while the app is on screen: a phone or VoIP
  /// call, another app's transient audio focus, an iOS audio session
  /// interruption, or a recorder that stopped. See [GravixMicStateEvent.reason].
  interrupted,

  /// The app is in the background and Android will not (or does not) let it
  /// record: no `microphone` foreground-service type, or the capture is
  /// silenced in the background.
  blockedInBackground,
}

/// Why the microphone is in its [GravixMicState].
enum GravixMicStateReason {
  none,

  /// A cellular call (Android audio mode IN_CALL / RINGTONE).
  phoneCall,

  /// Another app took the audio focus for a moment (Android
  /// AUDIOFOCUS_LOSS_TRANSIENT): VoIP calls and voice assistants do this.
  audioFocusLoss,

  /// Android reports our recording as silenced while the app is visible
  /// (another app with capture priority holds the microphone).
  silencedBySystem,

  /// iOS AVAudioSession interruption (a call, Siri, an alarm).
  sessionInterrupted,

  /// Android 11+ in the background without the `microphone`
  /// foreground-service type: the capture is silenced ~5 s after leaving the
  /// screen. See `GravixForegroundServiceOptions.claimMicrophoneAtStart`.
  backgroundWithoutMicrophoneType,

  /// Android reports the recording as silenced while in the background.
  silencedInBackground,

  /// The microphone is published and unmuted, but the platform reports no
  /// running recording for more than [GravixMicMonitor.captureStoppedGrace].
  captureStopped,

  /// The capture runs (recording, not silenced, published, unmuted) but its
  /// frames are DIGITAL silence (below -90 dBFS) for >= 3 s: a real microphone
  /// always has a noise floor. An emulator mic stall, an OEM recorder that
  /// never comes back, a silence the OS does not report. Opt-in:
  /// `GravixAudioDeviceOptions.silentCaptureDetection`.
  silentCapture,
}

/// A microphone state change.
@immutable
class GravixMicStateEvent {
  const GravixMicStateEvent(this.state, this.reason, this.at);

  final GravixMicState state;
  final GravixMicStateReason reason;

  /// When the SDK saw the change.
  final DateTime at;

  @override
  bool operator ==(Object other) => other is GravixMicStateEvent && other.state == state && other.reason == reason;

  @override
  int get hashCode => Object.hash(state, reason);

  @override
  String toString() => 'GravixMicStateEvent(${state.name}, ${reason.name})';
}

/// The raw inputs [gravixClassifyMic] decides from. Native fills the platform
/// part (`onMicSignals`), the monitor the app part.
@internal
@immutable
class GravixMicSignals {
  const GravixMicSignals({
    this.micWanted = false,
    this.backgrounded = false,
    this.micTypeMissing = false,
    this.recording,
    this.silenced = false,
    this.silencedSinceBackground = false,
    this.focusLossTransient = false,
    this.phoneCall = false,
    this.sessionInterrupted = false,
    this.silentCapture = false,
  });

  /// A published, unmuted local microphone exists in an attached room.
  final bool micWanted;
  final bool backgrounded;

  /// Android 11+: the call service does not hold the `microphone` type.
  final bool micTypeMissing;

  /// The platform reports our app recording; null = unknown (iOS, or not yet
  /// confirmed long enough to call it stopped).
  final bool? recording;
  final bool silenced;

  /// The current silence began while the app was in the background (the OS's
  /// background capture restriction). On the return to the foreground the
  /// lifecycle event arrives a few ms before the native un-silence signal
  /// (seen on a real device); until then it is still the background
  /// block, not a foreground interruption.
  final bool silencedSinceBackground;
  final bool focusLossTransient;
  final bool phoneCall;
  final bool sessionInterrupted;

  /// The capture's frames have been digital silence for >= 3 s (opt-in).
  final bool silentCapture;

  GravixMicSignals copyWith({
    bool? micWanted,
    bool? backgrounded,
    bool? micTypeMissing,
    bool? Function()? recording,
    bool? silenced,
    bool? silencedSinceBackground,
    bool? focusLossTransient,
    bool? phoneCall,
    bool? sessionInterrupted,
    bool? silentCapture,
  }) => GravixMicSignals(
    micWanted: micWanted ?? this.micWanted,
    backgrounded: backgrounded ?? this.backgrounded,
    micTypeMissing: micTypeMissing ?? this.micTypeMissing,
    recording: recording != null ? recording() : this.recording,
    silenced: silenced ?? this.silenced,
    silencedSinceBackground: silencedSinceBackground ?? this.silencedSinceBackground,
    focusLossTransient: focusLossTransient ?? this.focusLossTransient,
    phoneCall: phoneCall ?? this.phoneCall,
    sessionInterrupted: sessionInterrupted ?? this.sessionInterrupted,
    silentCapture: silentCapture ?? this.silentCapture,
  );

  @override
  String toString() =>
      'GravixMicSignals(wanted: $micWanted, bg: $backgrounded, typeMissing: $micTypeMissing, '
      'recording: $recording, silenced: $silenced${silencedSinceBackground ? ' (since background)' : ''}, '
      'focusLossTransient: $focusLossTransient, '
      'phoneCall: $phoneCall, sessionInterrupted: $sessionInterrupted, silentCapture: $silentCapture)';
}

/// Pure decision: the most specific cause wins (a phone call explains a
/// silenced recording; a missing foreground-service type explains a silenced
/// background capture).
@internal
(GravixMicState, GravixMicStateReason) gravixClassifyMic(GravixMicSignals s) {
  if (!s.micWanted) return (GravixMicState.idle, GravixMicStateReason.none);
  if (s.phoneCall) return (GravixMicState.interrupted, GravixMicStateReason.phoneCall);
  if (s.sessionInterrupted) return (GravixMicState.interrupted, GravixMicStateReason.sessionInterrupted);
  if (s.backgrounded && s.micTypeMissing) {
    return (GravixMicState.blockedInBackground, GravixMicStateReason.backgroundWithoutMicrophoneType);
  }
  if (s.silenced) {
    return s.backgrounded || s.silencedSinceBackground
        ? (GravixMicState.blockedInBackground, GravixMicStateReason.silencedInBackground)
        : (GravixMicState.interrupted, GravixMicStateReason.silencedBySystem);
  }
  if (s.focusLossTransient) return (GravixMicState.interrupted, GravixMicStateReason.audioFocusLoss);
  if (s.recording == false) return (GravixMicState.interrupted, GravixMicStateReason.captureStopped);
  if (s.silentCapture) return (GravixMicState.interrupted, GravixMicStateReason.silentCapture);
  return (GravixMicState.active, GravixMicStateReason.none);
}

/// Digital-silence meter over the outbound audio source's cumulative stats
/// (`totalAudioEnergy`, `totalSamplesDuration` of the media-source report the
/// local audio track already polls every 2 s). Mean square of an interval =
/// energy delta / duration delta; below 1e-9 (-90 dBFS RMS, about one 16-bit
/// LSB) the interval is digital silence. Pure; no frames are copied.
@internal
class GravixSilenceMeter {
  /// -90 dBFS as a mean square.
  static const double silentMeanSquare = 1e-9;

  num? _energy;
  num? _duration;
  Duration _silentFor = Duration.zero;

  Duration get silentFor => _silentFor;

  void reset() {
    _energy = null;
    _duration = null;
    _silentFor = Duration.zero;
  }

  /// Returns how long the capture has been digitally silent.
  Duration feed({required num? totalAudioEnergy, required num? totalSamplesDuration}) {
    if (totalAudioEnergy == null || totalSamplesDuration == null) {
      reset();
      return _silentFor;
    }
    final lastE = _energy;
    final lastD = _duration;
    _energy = totalAudioEnergy;
    _duration = totalSamplesDuration;
    if (lastE == null || lastD == null) return _silentFor;
    final dD = totalSamplesDuration - lastD;
    final dE = totalAudioEnergy - lastE;
    if (dD <= 0 || dE < 0) {
      // no samples flowing (that is captureStopped, not this), or new counters
      _silentFor = Duration.zero;
      return _silentFor;
    }
    if (dE / dD < silentMeanSquare) {
      _silentFor += Duration(microseconds: (dD * 1e6).round());
    } else {
      _silentFor = Duration.zero;
    }
    return _silentFor;
  }
}

/// Watches the microphone of every connected room and recovers it after an
/// interruption. Process-wide; runs only while a room is attached (Room.connect
/// attaches, disconnect/dispose detaches), and is event-driven: no polling.
@internal
class GravixMicMonitor {
  GravixMicMonitor._();

  static final GravixMicMonitor instance = GravixMicMonitor._();

  /// How long "mic wanted but not recording" must last before it counts
  /// (publish -> recorder start takes a moment).
  @visibleForTesting
  static Duration captureStoppedGrace = const Duration(milliseconds: 1500);

  /// After an interruption ends: how long to wait for the recorder to come
  /// back on its own before restarting the capture.
  @visibleForTesting
  static Duration restartCheckDelay = const Duration(milliseconds: 1500);

  /// At most one capture restart per this window (a recorder that cannot open
  /// must not be hammered).
  @visibleForTesting
  static Duration restartMinInterval = const Duration(seconds: 10);

  /// Restart the capture after an interruption ends (and re-assert the audio
  /// session/route). False = the pre-0.4.15 behaviour (state is still
  /// reported). Set through `GravixAudioDevice.options`.
  bool recoverAfterInterruption = true;

  /// False = the monitor never attaches (pre-0.4.15: nothing runs per room).
  /// Set through `GravixAudioDeviceOptions.micStateMonitoring`.
  bool enabled = true;

  /// Android Bluetooth chatroom model (opt-in, `GravixAudioDevice.options`):
  /// the native side follows the microphone in/out of communication mode.
  bool get bluetoothChatroom => _chatroom;
  set bluetoothChatroom(bool value) {
    if (_chatroom == value) return;
    _chatroom = value;
    _syncChatroom(force: true);
  }

  bool _chatroom = false;
  (bool, bool)? _chatroomSent;

  /// Opt-in digital-silence detection (`GravixAudioDeviceOptions.silentCaptureDetection`).
  bool get silentCaptureDetection => _silentDetection;
  set silentCaptureDetection(bool value) {
    if (_silentDetection == value) return;
    _silentDetection = value;
    if (!value) _silentCapture = false;
    refresh();
  }

  bool _silentDetection = false;
  bool _silentCapture = false;

  // Phone run 2026-10-10 (Xiaomi, XA_cell_f_media / XA_wa_f_media): after a
  // cellular and a WhatsApp call the detector reported silentCapture for
  // 1.5-2 s because its 2 s stats window still covered the call's zeroed
  // capture. Silence is measured only outside OS-reported interruptions: the
  // meters restart when one begins and when it ends (a full fresh window
  // after the end), and nothing is reported within
  // [silentHoldAfterInterruption] of an end.
  bool _osInterrupted = false;
  DateTime? _silentHoldUntil;

  /// No silentCapture report this soon after an OS-reported interruption ends.
  static const Duration silentHoldAfterInterruption = Duration(seconds: 4);

  void _resetMeters() {
    for (final m in _meters.values) {
      m.reset();
    }
    _silentCapture = false;
  }

  /// How long digital silence must last.
  static const Duration silentCaptureAfter = Duration(seconds: 3);

  /// At most one capture restart for silence per this window.
  @visibleForTesting
  static Duration silentRestartMinInterval = const Duration(seconds: 30);
  DateTime? _lastSilentRestart;

  final Map<LocalAudioTrack, EventsListener<TrackEvent>> _trackListeners =
      Map<LocalAudioTrack, EventsListener<TrackEvent>>.identity();
  final Map<LocalAudioTrack, GravixSilenceMeter> _meters = Map<LocalAudioTrack, GravixSilenceMeter>.identity();

  /// Tests: the clock.
  @visibleForTesting
  DateTime Function()? debugNow;
  DateTime get _now => debugNow?.call() ?? DateTime.now();

  /// Tests: the local microphone tracks to watch (default: each attached
  /// room's microphone publication).
  @visibleForTesting
  List<LocalAudioTrack>? debugMicTracks;

  List<LocalAudioTrack> get _micTracks {
    final o = debugMicTracks;
    if (o != null) return o;
    final out = <LocalAudioTrack>[];
    for (final room in _rooms.keys) {
      if (room is! Room) continue;
      final t = room.localParticipant?.getTrackPublicationBySource(TrackSource.microphone)?.track;
      if (t is LocalAudioTrack) out.add(t);
    }
    return out;
  }

  /// Listens to the stats the track already polls; only while the option is on.
  void _syncTrackListeners() {
    final want = _silentDetection && _rooms.isNotEmpty ? _micTracks : const <LocalAudioTrack>[];
    for (final t in _trackListeners.keys.toList()) {
      if (!want.any((w) => identical(w, t))) {
        unawaited(_trackListeners.remove(t)?.dispose());
        _meters.remove(t);
      }
    }
    for (final t in want) {
      if (_trackListeners.containsKey(t)) continue;
      _meters[t] = GravixSilenceMeter();
      _trackListeners[t] = t.createListener()
        ..on<AudioSenderStatsEvent>((e) {
          final src = e.stats.audioSourceStats;
          debugFeedSourceStats(
            t,
            totalAudioEnergy: src?.totalAudioEnergy,
            totalSamplesDuration: src?.totalSamplesDuration,
          );
        });
    }
    if (_trackListeners.isEmpty) _silentCapture = false;
  }

  /// One stats sample of [track]'s audio source (the 2 s stats event).
  @visibleForTesting
  void debugFeedSourceStats(
    LocalAudioTrack track, {
    required num? totalAudioEnergy,
    required num? totalSamplesDuration,
  }) {
    final meter = _meters[track];
    if (meter == null) return;
    if (!_micWanted || _osInterrupted || _autoMuted) {
      // muted (the engine mute zeroes the frames), not published, or the OS
      // has the microphone (a call zeroes it): not a fault, not measured.
      // The other-app muteMicInBackground mute is the same engine mute
      // (merge 2026-10-11: it read as silentCapture and restarted the capture).
      meter.reset();
      if (_silentCapture) {
        _silentCapture = false;
        refresh();
      }
      return;
    }
    final hold = _silentHoldUntil;
    final held = hold != null && _now.isBefore(hold);
    final silent =
        meter.feed(totalAudioEnergy: totalAudioEnergy, totalSamplesDuration: totalSamplesDuration) >=
            silentCaptureAfter &&
        !held;
    final any =
        silent || _meters.entries.any((m) => !identical(m.key, track) && m.value.silentFor >= silentCaptureAfter);
    if (any == _silentCapture) return;
    _silentCapture = any;
    refresh();
  }

  void _syncChatroom({bool force = false}) {
    if (!_android) return;
    final want = (_chatroom, _chatroom && _signals.micWanted && _rooms.isNotEmpty);
    final sent = _chatroomSent;
    // nothing to say while it never was on
    if (sent == null && !_chatroom) return;
    if (!force && sent == want) return;
    _chatroomSent = want;
    unawaited(Native.setBluetoothChatroom(enabled: want.$1, micActive: want.$2));
  }

  /// Other-app audio (owner report 2026-10-10): what to do while another app
  /// plays audio during a room. Set through
  /// `GravixAudioDeviceOptions.otherAppAudio`; latched when the first room
  /// attaches. Off = the native watcher is never started.
  GravixOtherAppAudioMode otherAppAudio = GravixOtherAppAudioMode.off;

  GravixOtherAppAudioMode _otherMode = GravixOtherAppAudioMode.off;
  StreamSubscription<Map<String, Object?>>? _otherSub;
  bool _otherPlaying = false;
  GravixOtherAppCaptureAction _actionSent = GravixOtherAppCaptureAction.none;
  final StreamController<bool> _otherChanges = StreamController<bool>.broadcast();

  /// The SDK muted the microphone in the engine for another app's audio
  /// (muteMicInBackground). That engine mute zeroes the frames like the
  /// user's mute, so the silent-capture detector must not measure it.
  bool get _autoMuted => _actionSent == GravixOtherAppCaptureAction.mute;

  /// Another app plays media/game audio now (debounced natively).
  bool get otherAppAudioPlaying => _otherPlaying;
  Stream<bool> get otherAppAudioChanges => _otherChanges.stream;

  final StreamController<GravixMicStateEvent> _changes = StreamController<GravixMicStateEvent>.broadcast();
  Stream<GravixMicStateEvent> get changes => _changes.stream;

  GravixMicStateEvent _current = GravixMicStateEvent(GravixMicState.idle, GravixMicStateReason.none, DateTime.now());
  GravixMicStateEvent get current => _current;

  final Map<Object, EventsListener<RoomEvent>?> _rooms = Map<Object, EventsListener<RoomEvent>?>.identity();
  StreamSubscription<Map<String, Object?>>? _nativeSub;
  AppLifecycleListener? _lifecycle;

  GravixMicSignals _signals = const GravixMicSignals();
  bool? _platformRecording;
  int _sdkInt = 0;
  Timer? _stoppedTimer;
  Timer? _restartTimer;
  DateTime? _lastRestart;
  bool _wasInterrupted = false;

  /// Tests: overrides the "published, unmuted microphone" lookup.
  @visibleForTesting
  bool? debugMicWanted;

  /// Tests: replaces the capture restart (default: re-enable each attached
  /// room's microphone track).
  @visibleForTesting
  Future<void> Function()? debugRestartCapture;

  @visibleForTesting
  int restartCount = 0;

  @visibleForTesting
  int get attachedRooms => _rooms.length;

  bool get _android => !kIsWeb && lkPlatformIs(PlatformType.android);
  bool get _supported => !kIsWeb && (lkPlatformIs(PlatformType.android) || lkPlatformIs(PlatformType.iOS));

  // ── room hooks (called from GravixForegroundService's room hooks) ─────────

  void attachRoom(Object room) {
    if (!enabled || !_supported || _rooms.containsKey(room)) return;
    EventsListener<RoomEvent>? listener;
    if (room is Room) {
      listener = room.createListener()
        ..on<LocalTrackPublishedEvent>((_) => refresh())
        ..on<LocalTrackUnpublishedEvent>((_) => refresh())
        ..on<TrackMutedEvent>((_) => refresh())
        ..on<TrackUnmutedEvent>((_) => refresh());
    }
    _rooms[room] = listener;
    if (_rooms.length == 1) _start();
    refresh();
  }

  void detachRoom(Object room) {
    if (!_rooms.containsKey(room)) return;
    unawaited(_rooms.remove(room)?.dispose());
    if (_rooms.isEmpty) _stop();
    refresh();
  }

  void _start() {
    _nativeSub ??= Native.micSignals.listen(_onNative);
    _lifecycle ??= AppLifecycleListener(onStateChange: (_) => refresh());
    unawaited(_startNative());
    _otherMode = _android ? otherAppAudio : GravixOtherAppAudioMode.off;
    if (_otherMode != GravixOtherAppAudioMode.off) {
      _otherSub ??= Native.otherAppAudioEvents.listen(_onOtherApp);
      unawaited(Native.startOtherAppAudioMonitor());
    }
  }

  void _onOtherApp(Map<String, Object?> m) {
    final playing = m['playing'] == true;
    if (playing == _otherPlaying) return;
    _otherPlaying = playing;
    logger.info('other app audio: ${playing ? 'playing' : 'stopped'} (players=${m['players']})');
    _otherChanges.add(playing);
    refresh();
  }

  /// Sends the capture action when it changed (one call per change).
  void _syncOtherAppAction() {
    if (_otherMode == GravixOtherAppAudioMode.off) return;
    final action = gravixOtherAppCaptureAction(
      mode: _otherMode,
      otherAppPlaying: _otherPlaying,
      micWanted: _rooms.isNotEmpty && _signals.micWanted,
      backgrounded: _signals.backgrounded,
    );
    if (action == _actionSent) return;
    final wasMuted = _autoMuted;
    _actionSent = action;
    // the silence window restarts when the automatic mute begins or ends: a
    // stats interval spanning the switch holds muted (zeroed) time
    if (_autoMuted != wasMuted) _resetMeters();
    logger.info('other app audio: capture action ${action.wire}');
    unawaited(Native.setOtherAppCaptureAction(action.wire));
  }

  void _stopOtherApp() {
    if (_otherMode == GravixOtherAppAudioMode.off) return;
    // the room is gone: give the capture back exactly as it was
    if (_actionSent != GravixOtherAppCaptureAction.none) {
      _actionSent = GravixOtherAppCaptureAction.none;
      unawaited(Native.setOtherAppCaptureAction(GravixOtherAppCaptureAction.none.wire));
    }
    unawaited(_otherSub?.cancel());
    _otherSub = null;
    unawaited(Native.stopOtherAppAudioMonitor());
    if (_otherPlaying) {
      _otherPlaying = false;
      _otherChanges.add(false);
    }
    _otherMode = GravixOtherAppAudioMode.off;
  }

  Future<void> _startNative() async {
    try {
      final initial = await Native.startMicMonitor(recoverAfterInterruption: recoverAfterInterruption);
      if (initial != null) _onNative(initial);
    } on PlatformException catch (e) {
      logger.fine('mic monitor unavailable: ${e.message ?? e.code}');
    } on MissingPluginException {
      // no native side (tests, unsupported platform)
    }
  }

  void _stop() {
    unawaited(_nativeSub?.cancel());
    _nativeSub = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _stoppedTimer?.cancel();
    _restartTimer?.cancel();
    _stoppedTimer = null;
    _restartTimer = null;
    _platformRecording = null;
    _wasInterrupted = false;
    _osInterrupted = false;
    _silentHoldUntil = null;
    _signals = const GravixMicSignals();
    _stopOtherApp();
    unawaited(Native.stopMicMonitor());
  }

  void _onNative(Map<String, Object?> m) {
    final sdk = m['sdkInt'];
    if (sdk is int) _sdkInt = sdk;
    final rec = m['recording'];
    _platformRecording = rec is bool ? rec : null;
    final silenced = m['silenced'] == true;
    // where a silence began decides what it is (A4, 2026-10-10): kept while it
    // lasts, cleared when it ends
    final sinceBackground = silenced && (_signals.silenced ? _signals.silencedSinceBackground : _backgrounded);
    _signals = _signals.copyWith(
      silenced: silenced,
      silencedSinceBackground: sinceBackground,
      // a ducking request (lossTransientCanDuck) leaves the microphone alone
      focusLossTransient: m['focus'] == 'lossTransient',
      phoneCall: m['phoneCall'] == true,
      sessionInterrupted: m['sessionInterrupted'] == true,
    );
    refresh();
  }

  bool get _micWanted {
    final o = debugMicWanted;
    if (o != null) return o;
    for (final room in _rooms.keys) {
      if (room is! Room) continue;
      final pub = room.localParticipant?.getTrackPublicationBySource(TrackSource.microphone);
      final track = pub?.track;
      if (track != null && !track.muted) return true;
    }
    return false;
  }

  bool get _backgrounded {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == AppLifecycleState.hidden || s == AppLifecycleState.paused;
    } catch (_) {
      return false;
    }
  }

  /// Re-evaluates the state. Cheap; called on every input change.
  void refresh() {
    if (_rooms.isEmpty) {
      _syncChatroom();
      _emit(GravixMicState.idle, GravixMicStateReason.none);
      return;
    }
    final wanted = _micWanted;
    final micTypeMissing =
        _android &&
        _sdkInt >= 30 &&
        !(GravixForegroundService.isRunning && GravixForegroundService.activeTypes.contains('microphone'));

    // "not recording" counts only once it lasted captureStoppedGrace
    bool? recording = _platformRecording;
    if (wanted && recording == false) {
      _stoppedTimer ??= Timer(captureStoppedGrace, () {
        _stoppedConfirmed = true;
        refresh();
      });
      if (!_stoppedConfirmed) recording = null;
    } else {
      _stoppedTimer?.cancel();
      _stoppedTimer = null;
      _stoppedConfirmed = false;
    }

    _signals = _signals.copyWith(
      micWanted: wanted,
      backgrounded: _backgrounded,
      micTypeMissing: micTypeMissing,
      recording: () => recording,
    );
    _syncChatroom();
    // before the silence signal below: the automatic mute it may start or end
    // is not measured (see _autoMuted)
    _syncOtherAppAction();
    _syncTrackListeners();
    // an OS-reported interruption beginning or ending restarts the silence
    // measurement (see _osInterrupted)
    final (osState, osReason) = gravixClassifyMic(_signals.copyWith(silentCapture: false));
    final os =
        osState == GravixMicState.blockedInBackground ||
        (osState == GravixMicState.interrupted && osReason != GravixMicStateReason.captureStopped);
    if (os != _osInterrupted) {
      _osInterrupted = os;
      _resetMeters();
      if (!os) _silentHoldUntil = _now.add(silentHoldAfterInterruption);
    }
    _signals = _signals.copyWith(silentCapture: wanted && _silentCapture && !_osInterrupted && !_autoMuted);
    final (state, reason) = gravixClassifyMic(_signals);
    final previous = _current;
    _emit(state, reason);
    _maybeRecover(previous, _current);
  }

  bool _stoppedConfirmed = false;

  void _emit(GravixMicState state, GravixMicStateReason reason) {
    if (_current.state == state && _current.reason == reason) return;
    _current = GravixMicStateEvent(state, reason, DateTime.now());
    logger.info('microphone: ${state.name} (${reason.name}) $_signals');
    _changes.add(_current);
  }

  static const _reassertAfter = {
    GravixMicStateReason.phoneCall,
    GravixMicStateReason.audioFocusLoss,
    GravixMicStateReason.silencedBySystem,
    GravixMicStateReason.sessionInterrupted,
  };

  bool _isInterruption(GravixMicStateEvent e) =>
      e.state == GravixMicState.blockedInBackground ||
      (e.state == GravixMicState.interrupted && e.reason != GravixMicStateReason.captureStopped);

  void _maybeRecover(GravixMicStateEvent previous, GravixMicStateEvent now) {
    if (now.reason == GravixMicStateReason.silentCapture &&
        previous.reason != GravixMicStateReason.silentCapture &&
        recoverAfterInterruption) {
      // a recorder delivering digital silence: open a new one, once per 30 s
      final last = _lastSilentRestart;
      final t = DateTime.now();
      if (last == null || t.difference(last) >= silentRestartMinInterval) {
        _lastSilentRestart = t;
        unawaited(_performRestart('the capture delivers digital silence'));
      }
    }
    if (_isInterruption(now)) {
      _wasInterrupted = true;
      return;
    }
    if (!recoverAfterInterruption) return;
    if (now.state == GravixMicState.idle) {
      // nothing to bring back; a later unmute starts a fresh capture
      _wasInterrupted = false;
      return;
    }
    final ended = _wasInterrupted && previous != now;
    final stopped = now.reason == GravixMicStateReason.captureStopped && previous.reason != now.reason;
    if (!ended && !stopped) return;
    _wasInterrupted = false;
    if (ended && _reassertAfter.contains(previous.reason)) {
      // The other app's call reprogrammed the audio mode and route (telephony
      // sets IN_CALL, then NORMAL): put ours back first. Not after a
      // background block: nothing reprogrammed the session then, Android
      // un-silences the capture by itself, and a re-activation mid-playout
      // is an audible flip.
      logger.info('microphone interruption ended: re-asserting the audio session');
      unawaited(Native.reassertAudioSession());
    }
    if (stopped) {
      // one restart for one stop, whichever path saw it first
      _restartTimer?.cancel();
      _restartTimer = null;
      unawaited(_restartCapture('recorder stopped'));
    } else {
      // give the recorder a moment to resume on its own
      _restartTimer?.cancel();
      _restartTimer = Timer(restartCheckDelay, () {
        if (_current.reason == GravixMicStateReason.captureStopped) {
          unawaited(_restartCapture('recorder did not come back after the interruption'));
        }
      });
    }
  }

  Future<void> _restartCapture(String why) async {
    final last = _lastRestart;
    final now = DateTime.now();
    if (last != null && now.difference(last) < restartMinInterval) return;
    _lastRestart = now;
    await _performRestart(why);
  }

  Future<void> _performRestart(String why) async {
    restartCount++;
    logger.info('microphone: restarting the capture ($why)');
    final seam = debugRestartCapture;
    if (seam != null) {
      await seam();
      return;
    }
    for (final room in _rooms.keys.toList()) {
      if (room is! Room) continue;
      final track = room.localParticipant?.getTrackPublicationBySource(TrackSource.microphone)?.track;
      if (track is! LocalAudioTrack || track.muted) continue;
      try {
        // Disabling the only enabled microphone track makes WebRTC stop its
        // recorder; enabling it opens a new one on the current route (the
        // same path the 2026-09-30 engine-mute note describes).
        track.mediaStreamTrack.enabled = false;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!track.muted) track.mediaStreamTrack.enabled = true;
      } catch (e) {
        logger.warning('microphone capture restart failed: $e');
      }
    }
  }

  @visibleForTesting
  void resetForTest() {
    for (final l in _rooms.values) {
      unawaited(l?.dispose());
    }
    _rooms.clear();
    unawaited(_nativeSub?.cancel());
    _nativeSub = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _stoppedTimer?.cancel();
    _restartTimer?.cancel();
    _stoppedTimer = null;
    _restartTimer = null;
    _stoppedConfirmed = false;
    _platformRecording = null;
    _sdkInt = 0;
    _signals = const GravixMicSignals();
    _current = GravixMicStateEvent(GravixMicState.idle, GravixMicStateReason.none, DateTime.now());
    _lastRestart = null;
    _wasInterrupted = false;
    debugMicWanted = null;
    debugRestartCapture = null;
    restartCount = 0;
    recoverAfterInterruption = true;
    for (final l in _trackListeners.values) {
      unawaited(l.dispose());
    }
    _trackListeners.clear();
    _meters.clear();
    _silentDetection = false;
    _silentCapture = false;
    _osInterrupted = false;
    _silentHoldUntil = null;
    _lastSilentRestart = null;
    silentRestartMinInterval = const Duration(seconds: 30);
    debugMicTracks = null;
    debugNow = null;
    enabled = true;
    _chatroom = false;
    _chatroomSent = null;
    unawaited(_otherSub?.cancel());
    _otherSub = null;
    _otherPlaying = false;
    _otherMode = GravixOtherAppAudioMode.off;
    _actionSent = GravixOtherAppCaptureAction.none;
    otherAppAudio = GravixOtherAppAudioMode.off;
    captureStoppedGrace = const Duration(milliseconds: 1500);
    restartCheckDelay = const Duration(milliseconds: 1500);
    restartMinInterval = const Duration(seconds: 10);
  }
}

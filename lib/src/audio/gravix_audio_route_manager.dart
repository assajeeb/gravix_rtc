// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'gravix_android_audio_session_guard.dart';
import 'gravix_audio_platform.dart';
import 'gravix_audio_route_log.dart';
import 'gravix_foreign_call_detector.dart';

/// ════════════════════════════════════════════════════════════════════════════
///  GravixAudioRouteManager — one owner for "where does the sound come out".
/// ════════════════════════════════════════════════════════════════════════════
///
/// Addresses two long-standing bugs. Both claims are the reference
/// implementation's; see the internal audio-routing design notes and confirm on
/// device with the internal on-device audio-routing checklist before repeating them.
///
///  • Room switch flips loudspeaker → earpiece.
///    Root cause: the route was applied in parallel with (i.e. BEFORE) the
///    microphone being enabled. WebRTC's AudioDeviceModule puts AudioManager
///    into `MODE_IN_COMMUNICATION` when playout/capture starts, and that reset
///    wipes any speakerphone flag set beforehand. The old room's background
///    teardown stopping ITS tracks does the same thing a moment later. Whoever
///    touches the AudioManager last wins — and it was not us.
///    Fix: apply AFTER the track is live, and re-assert on a short delay ladder
///    plus on every event that can restart playout.
///
///  • Bluetooth connect/disconnect kills the audio or moves it.
///    Root cause: nothing listened for device changes; becomingNoisy only
///    printed a log. When a headset disappears Android falls back to the
///    EARPIECE, not the loudspeaker, so the room goes "silent" in the user's
///    hand. When a headset appears, SCO takes ~0.5–1.5s to come up, so a single
///    immediate re-route lands before the device is usable.
///    Fix: listen to device changes + becomingNoisy, debounce, and apply twice
///    (now + late) so the SCO/A2DP transition is caught.
///
/// Usage:
/// ```dart
/// await GravixAudioRouteManager.instance.start();            // once
/// GravixAudioRouteManager.instance.applyAfterTrackStart();   // after mic up
/// GravixAudioRouteManager.instance.forceSpeakerOverHeadset = true;
/// ```
class GravixAudioRouteManager {
  GravixAudioRouteManager({
    required GravixAudioPlatform platform,
    required GravixAndroidAudioSessionGuard guard,
    required GravixForeignCallDetector foreignCall,
    GravixAudioRouteLog? log,
  }) : _platform = platform,
       _guard = guard,
       _foreignCall = foreignCall,
       _log = log ?? GravixAudioRouteLog.instance;

  /// Process-wide instance used by [GravixAudioRouting].
  static final GravixAudioRouteManager instance = GravixAudioRouteManager(
    platform: GravixNativeAudioPlatform(),
    guard: GravixAndroidAudioSessionGuard.instance,
    foreignCall: GravixForeignCallDetector.instance,
  );

  /// Debounce before reacting to a device change.
  static const Duration debounceDelay = Duration(milliseconds: 300);

  /// Second apply after a device change — BT SCO negotiation completes well
  /// after the device-added event.
  static const Duration lateDelay = Duration(milliseconds: 1200);

  /// First and second rungs of the post-track-start ladder.
  static const Duration trackStartFirstRung = Duration(milliseconds: 400);
  static const Duration trackStartSecondRung = Duration(milliseconds: 1200);

  final GravixAudioPlatform _platform;
  final GravixAndroidAudioSessionGuard _guard;
  final GravixForeignCallDetector _foreignCall;
  final GravixAudioRouteLog _log;

  StreamSubscription<String>? _devicesSub;
  StreamSubscription<void>? _noisySub;
  Timer? _debounce;
  Timer? _late;

  bool _applying = false;
  bool _rerunRequested = false;
  bool _started = false;

  /// Set while another app owns a voice call. [apply] becomes a no-op:
  /// preferring the speaker reaches `setCommunicationDevice(SPEAKER)` on API
  /// 31+, which would drag the OTHER app's call onto the loudspeaker too.
  bool suppressed = false;

  /// Force the phone's built-in loudspeaker even when a Bluetooth or wired
  /// headset IS connected.
  ///
  /// Default false, which is what a listener with earbuds in expects: the
  /// headset wins while it is there, the loudspeaker takes over the instant it
  /// goes away.
  bool forceSpeakerOverHeadset = false;

  /// Last route we actually resolved — for UI, not a source of truth. The
  /// native call can no-op silently; see [GravixAndroidAudioSessionGuard].
  bool get speakerOn => _speakerOn;
  bool _speakerOn = true;

  /// Whether an external (BT / wired / USB / car / dock) output is present.
  bool get hasExternalRoute => _hasExternal;
  bool _hasExternal = false;

  /// How many times [apply] has reached the platform. Field-report signal.
  int applyCount = 0;

  /// Notified whenever the effective route changes — bind a speaker icon to it.
  final ValueNotifier<bool> speakerOnListenable = ValueNotifier<bool>(true);

  /// The output the app explicitly asked for, or null while routing is
  /// automatic (the default).
  ///
  /// Non-null only after [setAudioOutput]. See that method for why an explicit
  /// selection is not the bug the automatic earpiece ranking was.
  GravixAudioOutput? get audioOutput => _audioOutput;
  GravixAudioOutput? _audioOutput;

  /// [audioOutput] as a listenable, for an earpiece/speaker toggle.
  final ValueNotifier<GravixAudioOutput?> audioOutputListenable = ValueNotifier<GravixAudioOutput?>(null);

  /// How many times [setAudioOutput] has reached the platform, successfully or
  /// not. Field-report signal, the counterpart to [applyCount].
  int directOutputCount = 0;

  /// Whether [start] has run.
  bool get isStarted => _started;

  // ── lifecycle ──────────────────────────────────────────────────────────────

  /// Idempotent. Call once, when v2 routing is enabled.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _devicesSub = _platform.devicesChanged.listen((detail) {
      _log.log('DEVICES', detail);
      // A headset appearing/disappearing is also the moment another app's call
      // most often starts or ends.
      _foreignCall.probeSoon();
      _schedule('devicesChanged');
    });

    // Headset/BT yanked. Android's default fallback is the EARPIECE, which
    // reads as "the audio disappeared". Re-apply so we land on loudspeaker.
    _noisySub = _platform.becomingNoisy.listen((_) {
      _log.log('NOISY', 'headset removed, re-asserting');
      _foreignCall.probeSoon();
      _schedule('becomingNoisy');
    });

    await apply(reason: 'start');
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    _late?.cancel();
    _debounce = null;
    _late = null;
    await _devicesSub?.cancel();
    await _noisySub?.cancel();
    _devicesSub = null;
    _noisySub = null;
    _started = false;
  }

  // ── the two call sites the room code needs ────────────────────────────────

  /// Call right AFTER the local audio track / first remote track is live.
  ///
  /// WebRTC reprograms AudioManager when playout starts, so one immediate apply
  /// is not enough — the ladder re-asserts once the ADM has settled. [reason]
  /// names the event that restarted playout, so the route log says WHICH one
  /// reprogrammed AudioManager. Anything that opens a new audio track belongs
  /// here, not just the first published track.
  void applyAfterTrackStart({String reason = 'trackStart'}) {
    unawaited(apply(reason: reason));
    _late?.cancel();
    _late = Timer(trackStartFirstRung, () {
      unawaited(apply(reason: '$reason+400'));
      Timer(trackStartSecondRung, () => unawaited(apply(reason: '$reason+1600')));
    });
  }

  void _schedule(String reason) {
    _debounce?.cancel();
    _debounce = Timer(debounceDelay, () {
      unawaited(apply(reason: reason));
      // BT SCO negotiation completes well after the device-added event.
      _late?.cancel();
      _late = Timer(lateDelay, () => unawaited(apply(reason: '$reason(late)')));
    });
  }

  // ── explicit output selection (opt-in, not a ranking) ─────────────────────

  /// Select the audio output **explicitly**, because the user asked for it.
  ///
  /// ## This is not the bug that was removed
  ///
  /// v2 deliberately has no automatic earpiece *ranking*, and that stays gone.
  /// The removed behaviour was `setSpeakerOutputPreferred(false)`, which does
  /// not pick a device — it installs the preferred-device list
  /// `[BT, Wired, Earpiece, Speaker]`. That list is sticky: the native switch
  /// re-resolves it on every hot-plug, so when the headset that justified it
  /// disconnects the **earpiece** wins, nobody asked for it, and a re-apply
  /// gated on device enumeration cannot recover because enumeration keeps
  /// reporting the headset for a moment after it is gone. See §1 of
  /// the internal audio-routing design notes.
  ///
  /// This method does none of that. It calls
  /// [GravixAudioPlatform.setDirectAudioOutput], which names a device
  /// (`setCommunicationDevice` on API 31+). There is no list, nothing outranks
  /// anything, and there is no state left behind for a later hot-plug to
  /// re-resolve into a surprise. The selection is re-asserted verbatim by
  /// [apply] — including after a headset disconnect — and
  /// `setAudioOutput(GravixAudioOutput.speaker)` undoes it completely.
  ///
  /// ## Behaviour
  ///
  /// - Default is automatic: [audioOutput] is null and [apply] prefers the
  ///   loudspeaker unconditionally, exactly as before this method existed.
  ///   Nothing here changes what an app that never calls it does.
  /// - An explicit selection **persists** across device changes and room
  ///   events until it is changed or [clearAudioOutput] is called. A 1:1
  ///   listening mode must not be yanked to the loudspeaker by a Bluetooth
  ///   device flickering in and out.
  /// - Returns false when the platform could not apply it (no earpiece on the
  ///   handset, or the native call failed). The previous selection is kept and
  ///   the automatic route is left alone.
  /// - Only meaningful with `GravixAudioRouting.v2 = true`; the v1 path has no
  ///   route owner to hold the selection. [GravixAudioRouting.setAudioOutput]
  ///   enforces that gate.
  Future<bool> setAudioOutput(GravixAudioOutput output) async {
    directOutputCount++;
    final bool applied;
    try {
      applied = await _platform.setDirectAudioOutput(output);
    } catch (e) {
      debugPrint('setAudioOutput($output) failed: $e');
      _log.log('OUTPUT-FAIL', '${output.label}: $e');
      return false;
    }
    if (!applied) {
      _log.log('OUTPUT-UNSUPPORTED', '${output.label}: platform declined');
      return false;
    }
    _audioOutput = output;
    audioOutputListenable.value = output;
    final speaker = output == GravixAudioOutput.speaker;
    _speakerOn = speaker;
    speakerOnListenable.value = speaker;
    _log.log('OUTPUT', 'explicit ${output.label}');
    return true;
  }

  /// Drop an explicit selection and hand routing back to [apply].
  ///
  /// The next apply prefers the loudspeaker unconditionally, as it does by
  /// default. Call this when leaving a private-listening mode, or on room
  /// teardown if the selection should not outlive the room.
  Future<void> clearAudioOutput({String reason = 'clearAudioOutput'}) async {
    if (_audioOutput == null) return;
    _audioOutput = null;
    audioOutputListenable.value = null;
    _log.log('OUTPUT', 'cleared, back to automatic');
    await apply(reason: reason);
  }

  // ── the single place the speaker preference is ever set ───────────────────

  Future<void> apply({String reason = ''}) async {
    // Serialize: two overlapping applies can leave AudioManager on the older
    // decision (this is exactly how the route "randomly" flipped).
    if (_applying) {
      _rerunRequested = true;
      return;
    }
    _applying = true;
    try {
      if (suppressed) {
        _log.log('APPLY-SKIP', '$reason: another app owns a call');
        return;
      }

      // ── ROOT-CAUSE FIX: sound moves to the earpiece after a Bluetooth or
      // wired headset DISCONNECTS ──────────────────────────────────────────
      //
      // `setSpeakerOutputPreferred` does not pick a device, it picks a
      // preferred-device RANKING that the native switch keeps and re-resolves
      // on every hot-plug event:
      //
      //   preferred = true   ->  [BluetoothHeadset, WiredHeadset, Speakerphone, Earpiece]
      //   preferred = false  ->  [BluetoothHeadset, WiredHeadset, Earpiece, Speakerphone]
      //
      // Two things follow. First, an `external ? false : true` branch buys
      // nothing: Bluetooth and wired ALREADY outrank Speakerphone when
      // preferred = true, so a connected headset wins either way. Second, that
      // branch is the one and only thing that ever ranks the EARPIECE above the
      // loudspeaker — and the list is sticky, it outlives the headset:
      //
      //   1. headset connects    -> external = true -> preferred = false
      //                          -> list [BT, Wired, Earpiece, Speaker]
      //   2. headset disconnects -> the switch re-resolves that same list, BT
      //      and Wired are gone -> EARPIECE wins. Sound is in the top speaker
      //      the instant the headset leaves.
      //   3. a debounced re-apply gated on device enumeration cannot recover,
      //      because enumeration keeps reporting a Bluetooth device for a
      //      moment after a real disconnect (the A2DP teardown lags): external
      //      reads true again, preferred stays false, the earpiece ordering is
      //      re-confirmed — and nothing else fires. Stuck.
      //
      // So: never rank the earpiece above the loudspeaker. Preferring the
      // speaker unconditionally gives a connected headset top priority AND
      // makes Speakerphone the fallback the moment it vanishes — applied by the
      // native switch itself on the hot-plug event, with no debounce window and
      // no dependence on our device enumeration telling the truth.

      // BEFORE the preference, not after: the preference call is a SILENT
      // no-op whenever the native Android audio switch is down, which is how a
      // room ends up stuck in the earpiece with a log full of APPLY lines that
      // all "succeeded". The session is app-owned now
      // (GravixAndroidAudioSessionOwner) so no Room teardown can take it down;
      // this is the detector for anything else that resets the mode under us,
      // and costs one getMode() when the session is healthy.
      await _guard.ensureAlive(reason);

      // An explicit selection wins over the automatic route, and is
      // re-asserted here for the same reason the automatic route is: WebRTC
      // reprograms AudioManager when playout restarts, so whatever was set
      // before the track came up is gone. Re-asserting a NAMED DEVICE cannot
      // reintroduce the sticky earpiece ranking — see [setAudioOutput].
      final explicit = _audioOutput;
      if (explicit != null) {
        final ok = await _platform.setDirectAudioOutput(explicit);
        applyCount++;
        final speaker = explicit == GravixAudioOutput.speaker;
        _speakerOn = speaker;
        speakerOnListenable.value = speaker;
        _hasExternal = (await _platform.getOutputs()).hasExternalOutput;
        _log.log('APPLY', '$reason -> explicit ${explicit.label}${ok ? '' : ' (declined)'}');
        return;
      }

      await _platform.setSpeakerOutputPreferred(true, force: forceSpeakerOverHeadset);
      applyCount++;

      // Reporting only, and deliberately AFTER the route is set: this must
      // never be an input to the decision above (see step 3), and keeping the
      // enumeration off the critical path means a device change reaches the
      // native router immediately instead of one async hop later.
      final devices = await _platform.getOutputs();
      final external = devices.hasExternalOutput;
      _hasExternal = external;
      final effectiveSpeaker = forceSpeakerOverHeadset || !external;
      _speakerOn = effectiveSpeaker;
      speakerOnListenable.value = effectiveSpeaker;

      _log.log(
        'APPLY',
        '$reason -> setSpeakerOutputPreferred(true, force=$forceSpeakerOverHeadset) '
            'external=$external effectiveSpeaker=$effectiveSpeaker',
      );
    } catch (e) {
      debugPrint('route apply[$reason] failed: $e');
      _log.log('APPLY-FAIL', '$reason: $e');
    } finally {
      _applying = false;
      if (_rerunRequested) {
        _rerunRequested = false;
        unawaited(apply(reason: 'coalesced'));
      }
    }
  }
}

// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'gravix_audio_platform.dart';
import 'gravix_audio_route_log.dart';

/// How sure we are that *another app* holds a voice call right now.
enum GravixForeignCallConfidence { none, suspected, confirmed }

/// ════════════════════════════════════════════════════════════════════════════
///  GravixForeignCallDetector — "is ANOTHER app currently holding a call?"
/// ════════════════════════════════════════════════════════════════════════════
///
/// The reported bug this exists for: a user is on a WhatsApp / cellular call
/// routed to a Bluetooth headset, then opens a live audio room. While that call
/// is up the headset is bound in HFP/SCO and Android SUSPENDS the same
/// headset's A2DP profile — its A2DP output disappears from the output device
/// list. Android's media strategy never routes media onto a Bluetooth SCO
/// device (SCO belongs to the communication strategy), so with no A2DP sink
/// left the room falls back to the built-in loudspeaker and leaks into the room
/// the user is physically in.
///
/// Knowing a foreign call is up lets an app pin its own (communication-profile)
/// playout into the live SCO link so the room mixes into the headset alongside
/// the call — or, if the OEM refuses that, go silent instead of leaking.
///
/// ── Design rules, each one bought with a real failure mode ──────────────────
///
///  • Only [GravixForeignCallConfidence.confirmed] is ever allowed to drive
///    behaviour. A false positive silences a HEALTHY room, which is worse than
///    the bug being fixed. `suspected` exists purely so a field report can
///    explain a near-miss.
///
///  • Mode alone is not proof: some OEM builds report our OWN session as
///    `IN_COMMUNICATION`, so a single-signal detector would mute those devices
///    on every join. Hence [baselineMode] (read before our stack writes
///    AudioManager) and the non-mode corroborators.
///
///  • Conversely, on API < 31 our own audio switch sets `MODE_NORMAL` at
///    connect, and that is a GLOBAL write that can clear a foreign call's
///    `MODE_IN_COMMUNICATION` — a false negative. Signals C/D/E do not depend
///    on the mode and cover that case.
///
///  • Device enumeration LAGS a real disconnect, so device-set signals may open
///    safe mode but must never be what closes it — the exit requires
///    `mode == NORMAL`.
///
/// Android-only. Elsewhere the verdict is permanently `none`.
@immutable
class GravixForeignCallVerdict {
  const GravixForeignCallVerdict({
    required this.confidence,
    required this.reasons,
    required this.mode,
    required this.baselineMode,
    required this.scoOn,
    required this.hasBtSco,
    required this.hasBtA2dp,
    required this.commDevice,
    required this.at,
  });

  const GravixForeignCallVerdict.none()
    : confidence = GravixForeignCallConfidence.none,
      reasons = const <String>[],
      mode = 'n/a',
      baselineMode = null,
      scoOn = false,
      hasBtSco = false,
      hasBtA2dp = false,
      commDevice = null,
      at = null;

  final GravixForeignCallConfidence confidence;

  /// Which signals fired. This is what makes a field report from a failing
  /// handset actionable.
  final List<String> reasons;

  final String mode;

  /// The mode read BEFORE any of our own AudioManager writes. Null until
  /// [GravixForeignCallDetector.captureBaseline] has run.
  final String? baselineMode;

  final bool scoOn;
  final bool hasBtSco;
  final bool hasBtA2dp;
  final String? commDevice;
  final DateTime? at;

  bool get isConfirmed => confidence == GravixForeignCallConfidence.confirmed;

  /// WITHOUT THIS the detector re-runs the whole foreign-call policy 75× a
  /// minute.
  ///
  /// A fresh instance is built on every probe, and `ValueNotifier` only skips
  /// notifying when `_value == newValue`. With identity equality that test
  /// never passes, so every listener — including the one that re-pins the route
  /// — fires on each 800 ms poll.
  ///
  /// [at] is deliberately excluded: it changes on every probe by construction,
  /// so including it would defeat the whole point.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GravixForeignCallVerdict &&
          other.confidence == confidence &&
          other.mode == mode &&
          other.baselineMode == baselineMode &&
          other.scoOn == scoOn &&
          other.hasBtSco == hasBtSco &&
          other.hasBtA2dp == hasBtA2dp &&
          other.commDevice == commDevice &&
          listEquals(other.reasons, reasons);

  @override
  int get hashCode =>
      Object.hash(confidence, mode, baselineMode, scoOn, hasBtSco, hasBtA2dp, commDevice, Object.hashAll(reasons));

  @override
  String toString() =>
      '${confidence.name} mode=$mode baseline=$baselineMode '
      'sco=$scoOn btSco=$hasBtSco btA2dp=$hasBtA2dp comm=$commDevice '
      '[${reasons.join('; ')}]';
}

/// See the doc on [GravixForeignCallVerdict] for why each signal is weighed the
/// way it is.
class GravixForeignCallDetector {
  GravixForeignCallDetector({required GravixAudioPlatform platform, GravixAudioRouteLog? log, DateTime Function()? now})
    : _platform = platform,
      _log = log ?? GravixAudioRouteLog.instance,
      _now = now ?? DateTime.now;

  /// Process-wide instance used by [GravixAudioRouting].
  static final GravixForeignCallDetector instance = GravixForeignCallDetector(platform: GravixNativeAudioPlatform());

  final GravixAudioPlatform _platform;
  final GravixAudioRouteLog _log;
  final DateTime Function() _now;

  /// Latest verdict. Bind UI to this.
  final ValueNotifier<GravixForeignCallVerdict> verdict = ValueNotifier<GravixForeignCallVerdict>(
    const GravixForeignCallVerdict.none(),
  );

  /// The single question the policy layer asks.
  bool get isConfirmed => verdict.value.isConfirmed;

  String? _baselineMode;
  String? get baselineMode => _baselineMode;

  /// Forget a baseline that can no longer be trusted.
  ///
  /// Signal B ("mode is IN_COMMUNICATION and the baseline was already busy") is
  /// the only evidence that survives once our own session is up, and its exit
  /// condition requires `mode == NORMAL` — which never happens while we hold a
  /// room on the communication profile. So a baseline that recorded OUR OWN
  /// `IN_COMMUNICATION` would latch `confirmed` for the entire session with no
  /// way back. Cleared on leave so the next join starts honest.
  void clearBaseline() => _baselineMode = null;

  /// True from the moment our own room session owns the audio device.
  ///
  /// This gates the Bluetooth corroborators, and it is not optional: on the
  /// communication profile OUR OWN room brings up a SCO link and suspends that
  /// headset's A2DP — byte-for-byte the same fingerprint another app's call
  /// leaves behind. Without this gate, ordinary "join a room wearing earbuds"
  /// trips every corroborator and safe mode silences a healthy room.
  ///
  /// So the corroborators only count BEFORE our session exists — which is
  /// exactly the reported scenario (the other call is already up when the user
  /// opens the room). Once connected only signal A (`MODE_IN_CALL`, which our
  /// stack can never produce) and signal B (a baseline that was already busy)
  /// remain, and both are unambiguous.
  bool ourSessionActive = false;

  Timer? _poll;
  Timer? _soon;
  bool _probing = false;
  bool _connected = false;

  /// Opens a window after connect during which the audio switch is actively
  /// reprogramming AudioManager and every reading is untrustworthy.
  DateTime? _settleUntil;
  static const Duration settleWindow = Duration(milliseconds: 2500);

  /// An interruption seen recently counts as a corroborator, never a verdict.
  DateTime? _lastInterruption;
  static const Duration interruptionWindow = Duration(seconds: 8);

  DateTime? _confirmedSince;

  /// How long a mode-only verdict may hold before we stop believing it.
  ///
  /// Signal B rests entirely on the baseline, and a baseline can be wrong (one
  /// reading, taken before our first AudioManager write, that nothing
  /// re-validates). Every other signal is corroborated by hardware state we can
  /// re-check, so only the mode-only case gets a time box.
  static const Duration modeOnlyMaxHold = Duration(seconds: 90);

  /// Consecutive agreeing probes before the state flips, in each direction.
  static const int enterStreak = 2;
  static const int exitStreak = 2;
  int _confirmStreak = 0;
  int _clearStreak = 0;

  // ── lifecycle ──────────────────────────────────────────────────────────────

  /// MUST run before anything in our stack writes AudioManager, and ONLY while
  /// no room is connected: inside a room the communication profile legitimately
  /// holds `MODE_IN_COMMUNICATION`, and recording that as the baseline would
  /// make signal B fire forever.
  ///
  /// Cheap — one channel call. The most recent reading wins, so a baseline
  /// taken during someone else's call is replaced by a `NORMAL` one at the next
  /// cold join after that call ends.
  Future<void> captureBaseline() async {
    if (!_platform.isAndroid) return;
    try {
      _baselineMode = (await _platform.getMode()).label;
      _log.log('FOREIGN-BASELINE', _baselineMode!);
    } catch (e) {
      debugPrint('GravixForeignCallDetector.captureBaseline failed: $e');
    }
  }

  /// Called at connect so probes inside the settle window are ignored rather
  /// than read as a call.
  void noteConnectStarted() => _settleUntil = _now().add(settleWindow);

  /// An audio interruption arrived. A TRIGGER and a corroborator, never a
  /// verdict on its own — with focus interruptions enabled an app holding two
  /// focus requests will interrupt ITSELF.
  void onInterruptionSeen() {
    _lastInterruption = _now();
    probeSoon();
  }

  void start() {
    if (!_platform.isAndroid) return;
    _connected = true;
    _restartPoll();
  }

  void stop() {
    _connected = false;
    _poll?.cancel();
    _poll = null;
    _soon?.cancel();
    _soon = null;
    _confirmStreak = 0;
    _clearStreak = 0;
    _confirmedSince = null;
    // The baseline describes a moment that has passed. Keeping it across a room
    // teardown is what let one bad reading confirm a foreign call on every
    // later join for the rest of the app's life.
    clearBaseline();
    _setVerdict(const GravixForeignCallVerdict.none());
  }

  void _restartPoll() {
    _poll?.cancel();
    if (!_connected) return;
    // Faster while confirmed: restoring the room promptly when the other call
    // ends matters more than shaving detection latency, which the pre-join
    // probe and the event triggers already cover.
    final interval = isConfirmed ? const Duration(milliseconds: 800) : const Duration(milliseconds: 1500);
    _poll = Timer.periodic(interval, (_) => unawaited(probe()));
  }

  /// A definitive pre-join answer from a standing start.
  ///
  /// [probe] alone can never return `confirmed` on a cold detector: entering
  /// safe mode deliberately requires [enterStreak] agreeing probes. The
  /// pre-join case cannot wait for a poll to deliver the second one — the leak
  /// happens the moment the room's audio starts — so run them back to back.
  Future<bool> confirmNow() async {
    if (!_platform.isAndroid) return false;
    await probe();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await probe();
    return isConfirmed;
  }

  /// Coalesced "something happened, look again shortly".
  void probeSoon({Duration delay = const Duration(milliseconds: 400)}) {
    if (!_platform.isAndroid) return;
    _soon?.cancel();
    _soon = Timer(delay, () => unawaited(probe()));
  }

  // ── the probe ──────────────────────────────────────────────────────────────

  /// Three channel reads plus one device enumeration.
  Future<GravixForeignCallVerdict> probe() async {
    if (!_platform.isAndroid) return verdict.value;
    if (_probing) return verdict.value;

    final settle = _settleUntil;
    if (settle != null && _now().isBefore(settle)) return verdict.value;

    _probing = true;
    try {
      final mode = await _platform.getMode();
      final modeName = mode.label;
      final scoOn = await _platform.isBluetoothScoOn();
      final commDevice = await _platform.getCommunicationDeviceType();
      final commIsBtSco = commDevice == 'bluetoothSco';
      final devices = await _platform.getOutputs();
      final hasBtSco = devices.hasBluetoothSco;
      final hasBtA2dp = devices.hasBluetoothA2dp;

      final lastInterruption = _lastInterruption;
      final interruptedRecently = lastInterruption != null && _now().difference(lastInterruption) < interruptionWindow;

      // ── weigh the signals ──────────────────────────────────────────────────
      final reasons = <String>[];
      var confirmed = false;
      var suspected = false;

      // A. MODE_IN_CALL is telephony. Nothing in our stack can ever produce it.
      if (mode == GravixAudioHardwareMode.inCall) {
        confirmed = true;
        reasons.add('mode=IN_CALL (telephony; our stack never sets this)');
      } else if (mode == GravixAudioHardwareMode.inCommunication) {
        final baselineWasBusy = _baselineMode != null && _baselineMode != 'NORMAL';
        if (baselineWasBusy) {
          // B. Already non-normal before we touched anything => not ours.
          confirmed = true;
          reasons.add(
            'mode=IN_COMMUNICATION and baseline was $_baselineMode (already busy before we configured audio)',
          );
        } else {
          // B'. Could be an OEM quirk in our own session — needs a witness.
          suspected = true;
          reasons.add('mode=IN_COMMUNICATION but baseline was NORMAL (may be our own session on this OEM)');
        }
      }

      // C/D/E only mean anything while our own session is NOT up — see
      // [ourSessionActive]. Our room produces the identical fingerprint.
      if (!ourSessionActive) {
        // C. The A2DP sink vanished while an SCO sink is present — the exact
        //    fingerprint of a headset whose A2DP the OS suspended for a call.
        if (hasBtSco && !hasBtA2dp) {
          reasons.add('BT_SCO output present with no BT_A2DP (A2DP suspended for a call)');
          if (suspected) confirmed = true;
          suspected = true;
        }

        // D. SCO is up and our session is not what brought it up.
        if (scoOn) {
          reasons.add('isBluetoothScoOn()=true before our session started');
          if (suspected) confirmed = true;
          suspected = true;
        }

        // E. The communication route is already pinned to a BT SCO device.
        if (commIsBtSco) {
          reasons.add('communicationDevice=BLUETOOTH_SCO before our session started');
          if (suspected) confirmed = true;
          suspected = true;
        }
      } else if (hasBtSco || scoOn || commIsBtSco) {
        reasons.add('BT/SCO signals ignored — our own session owns the audio device and produces the same fingerprint');
      }

      // F. A focus interruption landed recently.
      if (interruptedRecently) {
        reasons.add('audio interruption within ${interruptionWindow.inSeconds}s');
        if (suspected) confirmed = true;
      }

      final raw = confirmed
          ? GravixForeignCallConfidence.confirmed
          : suspected
          ? GravixForeignCallConfidence.suspected
          : GravixForeignCallConfidence.none;

      // ── hysteresis ─────────────────────────────────────────────────────────
      if (raw == GravixForeignCallConfidence.confirmed) {
        _confirmStreak++;
        _clearStreak = 0;
      } else if (raw == GravixForeignCallConfidence.none) {
        _clearStreak++;
        _confirmStreak = 0;
      } else {
        // `suspected` is neither evidence to enter nor evidence to leave.
        _confirmStreak = 0;
        _clearStreak = 0;
      }

      // Is anything but the audio mode holding this verdict up? Telephony
      // (signal A) is self-evidently real; the BT corroborators and a recent
      // focus interruption are re-checked hardware facts. Signal B alone rests
      // on a single historical reading that nothing re-validates.
      final hasLiveCorroborator =
          mode == GravixAudioHardwareMode.inCall ||
          interruptedRecently ||
          (!ourSessionActive && (scoOn || commIsBtSco || hasBtSco));

      final wasConfirmed = isConfirmed;
      GravixForeignCallConfidence effective;
      if (wasConfirmed) {
        // Exit needs a clear streak AND a normal mode: enumeration keeps
        // reporting a Bluetooth device for a moment after a real disconnect, so
        // the device set must not be what releases safe mode.
        final canExit = _clearStreak >= exitStreak && mode == GravixAudioHardwareMode.normal;

        // ...but that exit is unreachable while OUR room legitimately holds
        // MODE_IN_COMMUNICATION, so a mode-only verdict would latch for the
        // whole session. Time-box it: if nothing but the mode has vouched for
        // this call for 90s, stop believing it and hand the room back. A real
        // foreign call that is still up re-confirms on the next two probes; the
        // cost of being wrong is ~2s of unnecessary sharing, versus a
        // permanently silent room.
        final startedAt = _confirmedSince;
        final staleModeOnly =
            !hasLiveCorroborator && startedAt != null && _now().difference(startedAt) > modeOnlyMaxHold;
        if (staleModeOnly) {
          _log.log(
            'FOREIGN-CALL',
            'releasing mode-only verdict after ${modeOnlyMaxHold.inSeconds}s with no corroborating signal',
          );
          // Drop the baseline with it, or this just oscillates: the mode is
          // still IN_COMMUNICATION and the baseline still says "was already
          // busy", so signal B would re-confirm two probes later and we would
          // mute/unmute on a 90s cycle. Releasing the verdict IS the decision
          // that this baseline is not trustworthy, so it has to go too. With it
          // gone signal B degrades to B' (suspected), which never enters safe
          // mode on its own — while signals A and C/D/E, which do not depend on
          // the baseline, still work normally.
          clearBaseline();
        }

        effective = (canExit || staleModeOnly)
            ? GravixForeignCallConfidence.none
            : GravixForeignCallConfidence.confirmed;
      } else {
        effective = _confirmStreak >= enterStreak
            ? GravixForeignCallConfidence.confirmed
            : raw == GravixForeignCallConfidence.confirmed
            ? GravixForeignCallConfidence.suspected
            : raw;
      }

      _setVerdict(
        GravixForeignCallVerdict(
          confidence: effective,
          reasons: List<String>.unmodifiable(reasons),
          mode: modeName,
          baselineMode: _baselineMode,
          scoOn: scoOn,
          hasBtSco: hasBtSco,
          hasBtA2dp: hasBtA2dp,
          commDevice: commDevice,
          at: _now(),
        ),
      );

      return verdict.value;
    } catch (e) {
      debugPrint('GravixForeignCallDetector.probe failed: $e');
      return verdict.value;
    } finally {
      _probing = false;
    }
  }

  void _setVerdict(GravixForeignCallVerdict v) {
    final prev = verdict.value.confidence;
    if (v.confidence == GravixForeignCallConfidence.confirmed) {
      // Only stamp the START of a confirmed run, so the time box measures how
      // long we have been confirmed rather than resetting on every probe.
      _confirmedSince ??= _now();
    } else {
      _confirmedSince = null;
    }
    verdict.value = v;
    if (prev != v.confidence) {
      _log.log(
        'FOREIGN-CALL',
        '${prev.name} -> ${v.confidence.name}: ${v.reasons.isEmpty ? "no signals" : v.reasons.join("; ")}',
      );
      // The poll cadence is confidence-dependent.
      _restartPoll();
    }
  }
}

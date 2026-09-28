// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart';

import 'gravix_android_audio_session_owner.dart';
import 'gravix_audio_host.dart';
import 'gravix_audio_platform.dart';
import 'gravix_audio_route_log.dart';
import 'gravix_foreign_call_detector.dart';

/// ════════════════════════════════════════════════════════════════════════════
///  GravixAndroidAudioSessionGuard — detects a session that died under a room.
/// ════════════════════════════════════════════════════════════════════════════
///
/// WHAT IT CATCHES
/// ---------------
/// Every route lever ends at `setSpeakerOutputPreferred`, whose native
/// implementation begins:
///
///     handler.post {
///       val switch = audioSwitch ?: return@post   // <- silent no-op
///       applySpeakerRouting(switch, speakerRouting)
///     }
///
/// If the session is down that returns having done nothing, and reports no
/// error back to Dart. So an `APPLY` line in the route log proves only that we
/// CALLED it, never that it landed — which is how a report can show
/// `speakerOn = true` next to a handset stuck in the earpiece across seven
/// consecutive applies.
///
/// The ROOT CAUSE of that — any Room's teardown stopping the process-wide
/// session — is closed by [GravixAndroidAudioSessionOwner]. This guard is the
/// belt-and-braces layer on top: before every route apply it checks that the
/// mode we asked for is the mode the device is in, and does one
/// deactivate+activate cycle through the owner if not. Activating is what sets
/// `MODE_IN_COMMUNICATION`, so on the communication profile the audio mode IS
/// the liveness signal.
///
/// After the owner fix [rebuildCount] should be 0 in every scenario except
/// possibly once after a telephony call ended on an OEM that does not hand the
/// mode back. A non-zero count anywhere else is a bug report, not a repair.
///
/// WHAT IT WILL NOT DO
/// -------------------
///  • Repair while the owner says the session is not supposed to be up (logs
///    `SESSION-DEAD` instead — something forgot to start it).
///  • Repair within [settle] of the owner's start: the plugin activates on its
///    own handler thread after the channel call returns, so the first readings
///    after a start are legitimately still `MODE_NORMAL`.
///  • Repair while the mode is `IN_CALL` / `RINGTONE`: telephony owns the mode
///    there and activating would fight it. Log only.
///  • Repair while a foreign call is suspected or confirmed — apply() already
///    no-ops while suppressed, but `suspected` is not suppressed, and a mode
///    flap is exactly what makes it suspect.
///  • Repair while audio is idle: Android resets an idle communication-mode
///    owner to `MODE_NORMAL` after ~6s (a quiet room of muted seats). That is
///    not a dead session, and restarting it produced a `setMode` ping-pong
///    every ~7.5s. The next real mic enable / track start re-runs this.
class GravixAndroidAudioSessionGuard {
  GravixAndroidAudioSessionGuard({
    required GravixAudioPlatform platform,
    required GravixAndroidAudioSessionOwner owner,
    required GravixForeignCallDetector foreignCall,
    GravixAudioRouteLog? log,
    DateTime Function()? now,
  }) : _platform = platform,
       _owner = owner,
       _foreignCall = foreignCall,
       _log = log ?? GravixAudioRouteLog.instance,
       _now = now ?? DateTime.now;

  /// Process-wide instance used by [GravixAudioRouting].
  static final GravixAndroidAudioSessionGuard instance = GravixAndroidAudioSessionGuard(
    platform: GravixNativeAudioPlatform(),
    owner: GravixAndroidAudioSessionOwner.instance,
    foreignCall: GravixForeignCallDetector.instance,
  );

  /// Floor between two repair attempts.
  ///
  /// The ladder fires apply() three times (0/400/1600ms) per event and several
  /// events can overlap, so without this a single dead session would issue a
  /// burst of restarts. One is enough — and if one did not take, hammering it
  /// 200ms later will not help either.
  static const Duration cooldown = Duration(seconds: 3);

  /// Grace after the owner's start before a `MODE_NORMAL` reading counts.
  static const Duration settle = Duration(seconds: 2);

  /// Hard cap on repairs, in case some other signal still loops.
  static const Duration loopWindow = Duration(seconds: 60);
  static const int maxRestartsPerWindow = 2;

  final GravixAudioPlatform _platform;
  final GravixAndroidAudioSessionOwner _owner;
  final GravixForeignCallDetector _foreignCall;
  final GravixAudioRouteLog _log;
  final DateTime Function() _now;

  final List<DateTime> _recentRestarts = <DateTime>[];
  bool _busy = false;
  DateTime? _lastAttempt;

  /// The room this guard is guarding. Null means no room service — the guard
  /// then does nothing, exactly as before any room was created.
  GravixAudioHost? host;

  /// How many times a dead session was rebuilt. Expected to stay 0.
  int rebuildCount = 0;

  /// Restarts the Android audio session if it has been torn down under a
  /// still-live room. Safe to call before every route apply: it costs one
  /// `getMode()` when the session is healthy, which is the normal case.
  ///
  /// Never throws — a failed repair must not take the apply down with it.
  Future<void> ensureAlive(String reason) async {
    if (!_platform.isAndroid) return;

    // Only while a room is actually live. Outside one there is no session that
    // is SUPPOSED to be up, and forcing MODE_IN_COMMUNICATION would grab audio
    // focus and put the handset in call mode for nothing.
    final room = host;
    if (room == null || !room.isRoomConnected) return;

    // Backgrounded: the session was released on purpose so other apps can
    // record. MODE_NORMAL is correct.
    if (room.appBackgrounded) return;

    // On the media profile MODE_NORMAL is the correct, intended state — the
    // mode check below would read it as "dead" and restart forever.
    if (room.recordableRoomAudio) return;

    if (_busy) return;
    final last = _lastAttempt;
    if (last != null && _now().difference(last) < cooldown) return;

    _busy = true;
    try {
      final mode = await _platform.getMode();
      if (mode == GravixAudioHardwareMode.inCommunication) return;

      final modeName = mode.label;

      if (!_owner.isActive) {
        // Connected but nobody started the session. Not ours to paper over.
        _log.log('SESSION-DEAD', '$reason: mode=$modeName while connected and owner inactive');
        return;
      }

      final since = _owner.activeSince;
      if (since != null && _now().difference(since) < settle) return;

      if (mode != GravixAudioHardwareMode.normal) {
        // IN_CALL / RINGTONE / CALL_SCREENING: telephony owns it.
        _log.log('SESSION-GUARD', '$reason: mode=$modeName — telephony owns the mode, not touching');
        return;
      }

      final confidence = _foreignCall.verdict.value.confidence;
      if (confidence != GravixForeignCallConfidence.none) {
        _log.log('SESSION-GUARD', '$reason: mode=$modeName but foreign call ${confidence.name} — not touching');
        return;
      }

      // Android resets an IDLE comm-mode owner to NORMAL ~6s after setMode
      // (nothing playing or capturing — a quiet room of muted seats). That is
      // not a dead session, and restarting it produced a setMode ping-pong
      // every ~7.5s. The next real mic enable / track start re-runs this.
      if (!room.audioFlowing) {
        _log.log('SESSION-GUARD', '$reason: mode=$modeName while idle — OS reset, not restarting');
        return;
      }

      final now = _now();
      _recentRestarts.removeWhere((t) => now.difference(t) > loopWindow);
      if (_recentRestarts.length >= maxRestartsPerWindow) {
        _log.log('SESSION-GUARD', '$reason: loop-capped');
        return;
      }
      _recentRestarts.add(now);

      _lastAttempt = now;
      rebuildCount++;
      _log.log(
        'SESSION-RESTART',
        '$reason: mode=$modeName while connected and owner active — session was reset under us, restarting',
      );

      // The owner logs SESSION-STOP / SESSION-START with the resulting mode;
      // that pair is what tells a field report whether the repair took.
      await _owner.restart(reason);
    } catch (e) {
      debugPrint('android audio session guard failed: $e');
      _log.log('SESSION-RESTART', 'failed: $e');
    } finally {
      _busy = false;
    }
  }
}

// Copyright 2024 Gravity Compile
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'gravix_audio_platform.dart';
import 'gravix_audio_route_log.dart';

/// ════════════════════════════════════════════════════════════════════════════
///  GravixAndroidAudioSessionOwner — the app, not a Room, owns the session.
/// ════════════════════════════════════════════════════════════════════════════
///
/// ROOT CAUSE THIS EXISTS FOR
/// --------------------------
/// The Android audio session (audio mode, focus, output routing) is ONE object
/// for the whole process, but under the RTC core's default
/// [AudioSessionManagementMode.automatic] its lifetime is driven by individual
/// `Room` objects: `Room.connect()` starts it and `Room.disconnect()` /
/// `Room.dispose()` stop it — unconditionally, even for a Room that never
/// connected.
///
/// So any stale Room tearing down under a live one kills the live room's
/// session. In this SDK that is not hypothetical: [GravixRoomService.connect]
/// opens with `await disconnect()` to make re-entry safe, which in automatic
/// mode is precisely a Room teardown landing next to a new Room's connect.
///
/// Once stopped, `setSpeakerOutputPreferred()` is a SILENT no-op on the native
/// side (`audioSwitch ?: return`), the mode falls back to `MODE_NORMAL`, and
/// voice-communication playout in `MODE_NORMAL` comes out of the EARPIECE.
///
/// WHAT THIS DOES
/// --------------
/// Puts the RTC core in `manual` mode once ([claim]), so it never starts or
/// stops the Android session from Room lifecycle again, and then owns the
/// lifetime explicitly:
///
///   • [start]   — on every connect (idempotent);
///   • [stop]    — on a real leave, a terminal disconnect, or a failed connect;
///   • [restart] — the only way to re-assert mode/focus while the native switch
///                 is still alive (its own start() no-ops while active).
///
/// In manual mode the core's connect-time session calls are no-ops on Android
/// while `setSpeakerOutputPreferred` keeps working — so
/// [GravixAudioRouteManager]'s preferred-device list and the native hot-plug
/// handling do the routing, and nothing can pull the rug from under them.
///
/// Every operation is serialized on one future chain: start/stop/restart
/// overlapping from a room switch plus a leave must land in call order.
///
/// Android only. iOS stays in the core's automatic mode.
class GravixAndroidAudioSessionOwner {
  GravixAndroidAudioSessionOwner({
    required GravixAudioPlatform platform,
    GravixAudioRouteLog? log,
    DateTime Function()? now,
    Duration modePollInterval = const Duration(milliseconds: 100),
  }) : _platform = platform,
       _log = log ?? GravixAudioRouteLog.instance,
       _now = now ?? DateTime.now,
       _modePollInterval = modePollInterval;

  /// Process-wide instance used by [GravixAudioRouting].
  static final GravixAndroidAudioSessionOwner instance = GravixAndroidAudioSessionOwner(
    platform: GravixNativeAudioPlatform(),
  );

  final GravixAudioPlatform _platform;
  final GravixAudioRouteLog _log;
  final DateTime Function() _now;
  final Duration _modePollInterval;

  bool _claimed = false;
  bool _active = false;
  DateTime? _activeSince;
  Future<void> _chain = Future<void>.value();

  /// For a field report.
  int starts = 0;
  int stops = 0;
  int restarts = 0;

  /// Whether WE believe the session is up. The foreign-call baseline is only
  /// trustworthy while this is false.
  bool get isActive => _active;
  DateTime? get activeSince => _activeSince;

  /// Switch the RTC core to manual session management. Once per process; must
  /// run before any `Room` is constructed.
  Future<void> claim() async {
    if (!_platform.isAndroid || _claimed) return;
    _claimed = true;
    await _platform.claimManualSessionManagement();
    _log.log('SESSION-OWNER', 'claimed (RTC core manual mode)');
  }

  /// Bring the communication session up. Safe to call on every connect.
  Future<void> start(String reason) => _enqueue(() => _start(reason));

  /// Tear the session down: release focus, restore the previous audio mode.
  Future<void> stop(String reason) => _enqueue(() => _stop(reason));

  /// Full deactivate + activate. Used by [GravixAndroidAudioSessionGuard] when
  /// the mode was reset under a live room (telephony, OEM quirk) — the native
  /// switch is still alive then, so a plain [start] would no-op.
  Future<void> restart(String reason) => _enqueue(() async {
    restarts++;
    await _start$restart(reason);
  });

  Future<void> _start$restart(String reason) async {
    await _stop('restart:$reason');
    await _start('restart:$reason');
  }

  Future<void> _start(String reason) async {
    if (!_platform.isAndroid) return;
    await claim();
    if (_active) return;
    _active = true;
    _activeSince = _now();
    starts++;
    try {
      await _platform.startCommunicationSession();
      final mode = await _awaitMode(GravixAudioHardwareMode.inCommunication);
      _log.log('SESSION-START', '$reason -> mode=${mode.label}');
    } catch (e) {
      // Let the next connect retry rather than believing a dead session.
      _active = false;
      _activeSince = null;
      debugPrint('android audio session start failed: $e');
      _log.log('SESSION-START', '$reason FAILED: $e');
    }
  }

  Future<void> _stop(String reason) async {
    if (!_platform.isAndroid || !_active) return;
    _active = false;
    _activeSince = null;
    stops++;
    try {
      await _platform.stopCommunicationSession();
      final mode = await _awaitMode(GravixAudioHardwareMode.normal);
      _log.log('SESSION-STOP', '$reason -> mode=${mode.label}');
    } catch (e) {
      debugPrint('android audio session stop failed: $e');
      _log.log('SESSION-STOP', '$reason FAILED: $e');
    }
  }

  Future<void> _enqueue(Future<void> Function() op) {
    // A failed op must not poison the chain for the next one.
    return _chain = _chain.then((_) => op(), onError: (_) => op());
  }

  /// The plugin posts activate/deactivate to its own handler thread and the
  /// channel result returns BEFORE that work runs, so the first `getMode()`
  /// after an await is often stale. Poll briefly; report whatever the mode is
  /// when we give up — the log line is what a field report is read from.
  Future<GravixAudioHardwareMode> _awaitMode(GravixAudioHardwareMode want) async {
    var mode = await _platform.getMode();
    for (var i = 0; i < 5 && mode != want; i++) {
      await Future<void>.delayed(_modePollInterval);
      mode = await _platform.getMode();
    }
    return mode;
  }
}

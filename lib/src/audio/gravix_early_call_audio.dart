// Copyright Gravity Compile, Inc. Apache 2.0.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Candidate "earlyCallAudio": activate Android call audio at `connect()` start
/// instead of when the first remote audio track arrives.
///
/// Why: flutter_webrtc does that activation (audio focus, MODE_IN_COMMUNICATION,
/// output route) on Android's main thread - Flutter's platform thread - the
/// moment the first audio track is added. On a 2201117TG that blocked every
/// platform-channel reply and event for ~190 ms in the middle of the negotiation
/// the first audio was waiting on (LAN, 2026-09-20: setRemoteDescription 183 ms
/// vs 17 ms with the switch already active). `connect()` starts it the moment the
/// WebSocket dial begins - the one stretch of a join that makes no platform call -
/// so the ~200 ms overlap DNS + TCP + TLS instead of being queued behind.
///
/// What the user notices: exactly what they notice today, ~0.5 s EARLIER - other
/// apps' audio pauses or ducks (flutter_webrtc requests AUDIOFOCUS_GAIN), the
/// volume keys switch to call volume, the output route is chosen. Nothing opens
/// the microphone; no mic indicator. If the join then fails before a peer
/// connection exists, [stop] gives the audio back (flutter_webrtc only releases
/// it when the last peer connection is disposed).
///
/// Android only; false/no-op everywhere else. Not used under audio routing v2,
/// which owns session activation itself.
abstract final class GravixEarlyCallAudio {
  static const MethodChannel _channel = MethodChannel('gravix.cloud/fast_connect');

  /// True when the native side started (or had already started) call audio.
  /// Never throws.
  static Future<bool> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('startCallAudio') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('stopCallAudio');
    } catch (_) {}
  }
}

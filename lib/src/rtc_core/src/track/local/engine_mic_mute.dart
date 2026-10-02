// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:meta/meta.dart';

import '../../logger.dart';
import '../../support/native.dart';
import '../../support/platform.dart';

/// Microphone mute inside the Android audio device module, with the recorder
/// left running.
///
/// Why (field 2026-09-30, Android): muting by disabling the mic track makes the
/// WebRTC engine (webrtc-sdk's stop-on-mute ADM, `WebRtcVoiceSendChannel::
/// MuteStream`) STOP the AudioRecord, and unmuting re-creates it. Closing and
/// re-opening a VOICE_COMMUNICATION input under a live call re-routes the voice
/// path on OEM audio HALs, and that interrupted the playout of the OTHER
/// participants: silent for a moment after each unmute, gone after rapid
/// toggling. With the track kept enabled the engine never sees a mute; the
/// module zeroes the captured PCM on its record thread instead
/// (`JavaAudioDeviceModule.setMicrophoneMute`, before any encoder or mixer), and
/// the native side also holds the music mixer, so nothing AUDIBLE is sent while
/// muted. The encoder keeps running on those zeros: packets still flow, at the
/// rate MicUplinkPause caps the sender to (~7 kbps measured 2026-10-02, was the
/// full 46-75 kbps before the cap).
///
/// The state is engine-wide (one audio device module per process), so it is
/// tracked here, released when the muted track stops, and cleared before any
/// new microphone capture starts.
class GravixEngineMicMute {
  GravixEngineMicMute._();

  static bool Function() _supported = _defaultSupported;
  static Future<bool> Function(bool mute) _setNative = Native.setMicrophoneMute;

  static bool _defaultSupported() => lkPlatformIs(PlatformType.android) && !lkPlatformIsTest();

  /// Whether the module's microphone mute is currently engaged by us.
  static bool get engaged => _engaged;
  static bool _engaged = false;

  /// The local audio track holding the mute (a `LocalAudioTrack`).
  @internal
  static Object? owner;

  /// Whether this platform mutes in the audio device module (Android).
  static bool get supported => _supported();

  /// Engages the module mute. Returns false (and engages nothing) when the
  /// platform or the native side cannot: the caller must then mute the old way.
  static Future<bool> engage() async {
    if (!_supported()) return false;
    bool ok;
    try {
      ok = await _setNative(true);
    } catch (e) {
      logger.warning('engine microphone mute failed: $e');
      ok = false;
    }
    _engaged = ok;
    return ok;
  }

  /// Releases the module mute if engaged. Never throws.
  static Future<void> release() async {
    if (!_engaged) return;
    _engaged = false;
    owner = null;
    try {
      if (!await _setNative(false)) {
        logger.severe('engine microphone unmute was refused by the native side');
      }
    } catch (e) {
      logger.severe('engine microphone unmute failed: $e');
    }
  }

  @visibleForTesting
  static void debugReset({bool Function()? supported, Future<bool> Function(bool mute)? setNative}) {
    _supported = supported ?? _defaultSupported;
    _setNative = setNative ?? Native.setMicrophoneMute;
    _engaged = false;
    owner = null;
  }
}

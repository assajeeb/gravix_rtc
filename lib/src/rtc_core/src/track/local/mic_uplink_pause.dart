// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';

import '../../logger.dart';

/// Saves the microphone's uplink while it is muted, without touching the
/// capture: the mic sender's `encodings[0].maxBitrate` is capped at
/// [mutedMaxBitrate] while muted and restored on unmute.
///
/// Why (owner 2026-10-02): the engine-level mute (GravixEngineMicMute) keeps
/// the recorder running and zeroes the PCM, but the encoder still encodes those
/// zeros at the publish rate (64 kbps, DTX off for clean word onsets, plus RED):
/// 46-75 kbps of uplink for silence in the field. Capped, the same silence costs
/// ~7 kbps (Xiaomi 2201117TG, tester outbound-rtp, 2026-10-02). Only
/// setParameters on the sender (the audio-first bitrate cap's path): no
/// renegotiation, no track restart, the recorder is not touched.
///
/// Why NOT `encodings[0].active = false` (which would send nothing at all):
/// measured on the same phone 2026-10-02, an inactive encoding stops the audio
/// send stream, and with no sending stream left the engine STOPS the Android
/// AudioRecord (`rec stop ... VOICE_COMMUNICATION` at the mute tap) and
/// re-creates it on unmute (`rec start`) -- exactly the 0.4.4 field bug that the
/// engine-level mute exists to avoid (re-opening a voice input under a live call
/// interrupts the other participants' playout on OEM HALs).
///
/// flutter_webrtc 1.6.0 keeps ONE cached RTCRtpParameters per sender
/// (`sender.parameters` returns it, `setParameters` stores it before calling
/// native), and the audio-first policy mutates and re-sends that same object.
/// So a value the native side refused is reverted in the cache at once, or the
/// next unrelated setParameters would silently apply it.
class MicUplinkPause {
  /// Opus' floor is ~6 kbps; the sender still sends 50 packets/s.
  static const int mutedMaxBitrate = 6000;

  /// Opus' maximum: "uncapped" for an encoding that had no cap before.
  static const int opusMaxBitrate = 510000;

  rtc.RTCRtpSender? _sender;
  bool _capped = false;
  int? _bitrateBefore;

  /// The sender currently paused (null: none).
  @visibleForTesting
  rtc.RTCRtpSender? get pausedSender => _sender;

  /// Whether the cap is applied on the current sender.
  bool get capped => _capped;

  /// Caps [sender] (no-op when null or already paused). Never throws: a refused
  /// cap only costs uplink, the audio is zeroed or disabled anyway.
  Future<void> pause(rtc.RTCRtpSender? sender) async {
    if (sender == null || identical(_sender, sender)) return;
    _sender = sender;
    _capped = false;
    final params = sender.parameters;
    final enc = params.encodings;
    if (enc == null || enc.isEmpty) return;
    final first = enc.first;
    final before = first.maxBitrate;
    first.maxBitrate = mutedMaxBitrate;
    if (await _set(sender, params)) {
      _bitrateBefore = before;
      _capped = true;
    } else {
      first.maxBitrate = before; // what the native side still has (see the class doc)
    }
  }

  /// Undoes the cap before the microphone goes live again. Returns false only
  /// when the sender refused the restore (twice): the unmuted microphone then
  /// stays at the muted rate until the next setParameters / republish.
  Future<bool> resume(rtc.RTCRtpSender? current) async {
    final sender = _sender;
    final capped = _capped;
    final before = _bitrateBefore;
    forget();
    if (sender == null || !capped) return true;
    // A republish replaced the sender: the new one starts uncapped (and the old
    // one is gone; setParameters on it would throw "sender is null").
    if (!identical(sender, current)) return true;
    final params = sender.parameters;
    final enc = params.encodings;
    if (enc == null || enc.isEmpty) return true;
    // someone else (the audio-first policy) moved it meanwhile: then it is theirs
    if (enc.first.maxBitrate != mutedMaxBitrate) return true;
    // No cap before: flutter_webrtc cannot clear a maxBitrate (a null is
    // ignored natively), so lift it to Opus' maximum instead.
    enc.first.maxBitrate = before ?? opusMaxBitrate;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (await _set(sender, params)) return true;
    }
    logger.severe('mic uplink: restoring the bitrate after unmute failed');
    return false;
  }

  /// Forgets the paused sender without touching it (unpublished / replaced).
  void forget() {
    _sender = null;
    _capped = false;
    _bitrateBefore = null;
  }

  static Future<bool> _set(rtc.RTCRtpSender sender, rtc.RTCRtpParameters params) async {
    try {
      return await sender.setParameters(params);
    } catch (e) {
      // flutter_webrtc throws a String on PlatformException
      logger.warning('mic uplink setParameters failed: $e');
      return false;
    }
  }
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:meta/meta.dart';

/// The link between room music (`GravixRoomMusic`, app layer) and the
/// microphone's mute (`LocalAudioTrack.mute`, RTC core) without the core
/// importing the music layer.
///
/// While a music session runs with `continueWhileMicMuted`, [appliesTo] is true
/// for the published microphone track: a mute then zeroes only the voice (in
/// the Android audio device module) and the publication stays live on the wire,
/// so the music keeps reaching the room.
class GravixMusicVoiceMute {
  GravixMusicVoiceMute._();

  static bool Function(Object track)? _predicate;

  /// Whether a mute of [track] must be a voice-only mute right now.
  static bool appliesTo(Object track) => _predicate?.call(track) ?? false;

  /// Set by GravixRoomMusic when its session starts, cleared when it ends.
  @internal
  static set predicate(bool Function(Object track)? p) => _predicate = p;

  @internal
  static bool Function(Object track)? get predicate => _predicate;

  @visibleForTesting
  static void debugReset() => _predicate = null;
}

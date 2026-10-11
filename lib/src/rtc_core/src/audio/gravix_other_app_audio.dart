// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

/// What the SDK does while ANOTHER app plays audio on this phone during a room
/// (Android). Set through `GravixAudioDeviceOptions.otherAppAudio`.
///
/// Why (owner report 2026-10-10): "a user is in a room with the mic on; when he
/// plays YouTube or a game with sound, the microphone sends that sound too".
/// An app on the media audio profile (MODE_NORMAL, USAGE_MEDIA playout, the
/// MIC capture source through `bypassVoiceProcessing`, libwebrtc's software
/// echo canceller) cancels only what WebRTC itself plays: the echo
/// canceller's reference is the room's own playout. YouTube or a game on the
/// loudspeaker reaches the microphone through the air and is not in that
/// reference, so the room hears it. The communication profile
/// (VOICE_COMMUNICATION capture, platform echo canceller) is a different
/// trade-off (WhatsApp voice notes, earpiece/call routing) that the app picks
/// at initialize; see the README, "Other apps' audio".
///
/// Detection uses Android's playback activity (API 26+, no permission, no
/// audio content): any started player with a media, game or unknown usage that
/// is not the room's own playout, on the loudspeaker (API 31+ also excludes
/// players routed to a headset). It reports after ~1 s of continuous
/// presence and clears after ~2 s of absence, so a short game blip or a
/// playlist gap does not flap.
enum GravixOtherAppAudioMode {
  /// Default. Nothing is watched; exactly the behaviour before this option.
  off,

  /// Report only: `GravixAudioDevice.otherAppAudioPlaying` and
  /// `GravixAudioDevice.otherAppAudioPlayingChanged` (show "other audio is
  /// heard by the room", offer a mute). The capture is not touched.
  detect,

  /// Detect, and while another app plays and the microphone is live, attach
  /// the platform echo canceller and noise suppressor (`android.media.audiofx`)
  /// to the running capture; released when it stops. No capture restart.
  /// Whether the platform echo canceller sees other apps' output depends on
  /// the phone (measured per device, see the run log of 2026-10-10).
  platformEffects,

  /// Detect, and while another app plays and the microphone is live, re-open
  /// the capture with the VOICE_COMMUNICATION source (the source a call app
  /// uses, which brings the phone's own voice processing); back to the
  /// original source when it stops. Each switch restarts the recorder (a gap
  /// of tens of ms), and while it lasts the capture behaves like a call's
  /// (another app's recorder, e.g. a voice note, may be silenced).
  voiceCommunicationCapture,

  /// Detect, and while another app plays, the microphone is live AND our app
  /// is in the background, mute the microphone in the audio engine (the
  /// published track stays; it sends silence); unmuted when either ends. The
  /// user's own mute is kept apart and wins.
  muteMicInBackground,
}

/// What the native capture should do now. Internal; derived by
/// [gravixOtherAppCaptureAction].
enum GravixOtherAppCaptureAction {
  none('none'),
  platformEffects('platformEffects'),
  voiceCommunication('voiceCommunication'),
  mute('mute');

  const GravixOtherAppCaptureAction(this.wire);

  /// The value sent to the native side.
  final String wire;
}

/// The capture action for the current inputs. Pure: the whole policy is this
/// table, so it is tested without a phone.
GravixOtherAppCaptureAction gravixOtherAppCaptureAction({
  required GravixOtherAppAudioMode mode,
  required bool otherAppPlaying,
  required bool micWanted,
  required bool backgrounded,
}) {
  if (!otherAppPlaying || !micWanted) return GravixOtherAppCaptureAction.none;
  return switch (mode) {
    GravixOtherAppAudioMode.off || GravixOtherAppAudioMode.detect => GravixOtherAppCaptureAction.none,
    GravixOtherAppAudioMode.platformEffects => GravixOtherAppCaptureAction.platformEffects,
    GravixOtherAppAudioMode.voiceCommunicationCapture => GravixOtherAppCaptureAction.voiceCommunication,
    GravixOtherAppAudioMode.muteMicInBackground =>
      backgrounded ? GravixOtherAppCaptureAction.mute : GravixOtherAppCaptureAction.none,
  };
}

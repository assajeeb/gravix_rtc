// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// The audio scenario of the process. Android only (iOS keeps its audio
/// session; `GravixRtcClient.initialize` ignores the scenario there). Latched by the
/// first `WebRTC.initialize`, like every initialize option.
enum GravixAudioScenario {
  /// The audio device module as the app (or flutter_webrtc) configures it.
  standard,

  /// Agora `AUDIO_SCENARIO_CHATROOM` parity (REA of the Agora Android SDK +
  /// device runs, 2026-10-22): the communication profile
  /// (MODE_IN_COMMUNICATION, VOICE_COMMUNICATION capture), the platform AEC,
  /// a 16 kHz capture (the voice path the platform AEC is tuned for; playout
  /// stays 48 kHz) and no AGC. The platform AEC cancels everything the phone
  /// plays, also sounds outside WebRTC (gift / entrance SVGA, MP4), so they do
  /// not reach the microphone while the user keeps talking. Xiaomi
  /// 2026-10-22, a separate player's music: sent -11 dBFS (media profile) ->
  /// below -85 dBFS mean (chatRoom).
  ///
  /// Trade-offs (as on Agora ChatRoom): call volume (the volume keys set the
  /// call stream), voice-band capture (16 kHz), another app cannot record
  /// while our microphone runs, screen recordings do not capture the room.
  chatRoom,
}

GravixAudioScenario _current = GravixAudioScenario.standard;

/// The scenario chosen by [gravixUseAudioScenario] / `GravixRtcClient.initialize`.
GravixAudioScenario get gravixAudioScenario => _current;

/// Records [scenario] for the SDK (noise suppression reads it) and returns the
/// options it adds to `WebRTC.initialize` (empty for standard). An app that
/// calls `WebRTC.initialize` itself merges these into its options, before any
/// other initialize; `GravixRtcClient.initialize(audioScenario:)` does it for the rest.
Map<String, dynamic> gravixUseAudioScenario(GravixAudioScenario scenario) {
  _current = scenario;
  switch (scenario) {
    case GravixAudioScenario.standard:
      return const {};
    case GravixAudioScenario.chatRoom:
      return {
        'androidAudioConfiguration': rtc.AndroidAudioConfiguration.communication.toMap(),
        'androidUseHardwareAudioProcessing': true,
        'audioSampleRate': 16000,
        'audioOutputSampleRate': 48000,
      };
  }
}

// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

// WebRTC processing while OUR noise suppression runs (plan §1c, owner
// 2026-10-21). Decided BEFORE the capture starts: the options reach
// startLocalRecording -> applyPlatformAudioProcessingOptions (Android platform
// NS/AEC effects are bound when the AudioRecord is created; re-creating it
// mid-call re-routes on some OEMs), so the mic track must be created with them.

import '../rtc_core/src/audio/gravix_audio_scenario.dart';
import '../rtc_core/src/track/options.dart';
import 'gravix_noise_options.dart';

/// Whether [engine] is one of ours (Gravix processing runs).
bool gravixNsIsOurs(GravixNsEngine engine) => engine == GravixNsEngine.rnnoise || engine == GravixNsEngine.dfn3;

/// [o] under the process audio scenario: [GravixAudioScenario.chatRoom] runs
/// without AGC (Agora ChatRoom parity) unless the app chose
/// [GravixNsAgcOrder.webrtcBeforeNs] (or [GravixNsAgcOrder.none]) itself.
GravixNoiseSuppressionOptions gravixScenarioNsOptions(GravixNoiseSuppressionOptions o) =>
    gravixAudioScenario == GravixAudioScenario.chatRoom && o.agcOrder == GravixNsAgcOrder.ownAfterNs
        ? o.copyWith(agcOrder: GravixNsAgcOrder.none)
        : o;

/// The WebRTC processing to use while [engine] is active.
///
/// - not ours (off / browser / unsupported platform): [base] unchanged.
/// - [GravixNoiseSuppressionOptions.disableWebRtcNs]: WebRTC software NS off;
///   with [GravixHwNs.on] the platform (hardware) NS stays on
///   (`noiseSuppression: true, mode: platform`), otherwise every NS is off.
/// - [GravixNsAgcOrder.ownAfterNs]: WebRTC AGC off (ours runs after our NS);
///   [GravixNsAgcOrder.webrtcBeforeNs]: WebRTC AGC as in [base].
/// - an app that already turned NS / AGC off keeps them off.
AudioProcessingOptions gravixNsProcessing(
  AudioProcessingOptions base,
  GravixNoiseSuppressionOptions ns,
  GravixNsEngine engine,
) {
  if (!gravixNsIsOurs(engine)) return base;
  var nsOn = base.noiseSuppression;
  var nsMode = base.noiseSuppressionMode;
  if (ns.disableWebRtcNs && nsOn) {
    if (ns.hardwareNs == GravixHwNs.on) {
      nsMode = AudioProcessingMode.platform;
    } else {
      nsOn = false;
    }
  }
  final agcOn = ns.agcOrder == GravixNsAgcOrder.webrtcBeforeNs ? base.autoGainControl : false;
  return AudioProcessingOptions(
    echoCancellation: base.echoCancellation,
    noiseSuppression: nsOn,
    autoGainControl: agcOn,
    highPassFilter: base.highPassFilter,
    echoCancellationMode: base.echoCancellationMode,
    noiseSuppressionMode: nsMode,
    autoGainControlMode: base.autoGainControlMode,
    highPassFilterMode: base.highPassFilterMode,
  );
}

/// [gravixNsProcessing] applied to a capture's options.
AudioCaptureOptions gravixNsCaptureOptions(
  AudioCaptureOptions base,
  GravixNoiseSuppressionOptions ns,
  GravixNsEngine engine,
) {
  if (!gravixNsIsOurs(engine)) return base;
  return base.copyWith(processing: gravixNsProcessing(base.processing, ns, engine));
}

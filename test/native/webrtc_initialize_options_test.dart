// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixRtcClient.initialize(enableWARP:) -> flutter_webrtc's initialize()
// option map. `enableWARP` is read by flutter_webrtc >= 1.6.2 (WebRTC-
// IceHandshakeDtls field trial: the DTLS handshake rides on the ICE STUN
// checks); 1.6.0/1.6.1 look keys up by name and ignore it. The key is sent only
// when asked for, so the default map is byte-for-byte what 0.4.7 sent.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/audio_session.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/webrtc_initialize_options.dart';

void main() {
  test('default: no enableWARP key (same map as 0.4.7)', () {
    final m = gravixWebRTCInitializeOptions(
      bypassVoiceProcessing: false,
      initialAudioSessionOptions: null,
      includeAndroidAudioConfiguration: true,
    );
    expect(m, isEmpty);
  });

  test('enableWARP: true is passed through', () {
    final m = gravixWebRTCInitializeOptions(
      bypassVoiceProcessing: false,
      initialAudioSessionOptions: null,
      includeAndroidAudioConfiguration: true,
      enableWARP: true,
    );
    expect(m, {'enableWARP': true});
  });

  test('enableWARP sits beside the other options, which are unchanged', () {
    final m = gravixWebRTCInitializeOptions(
      bypassVoiceProcessing: true,
      initialAudioSessionOptions: const AudioSessionOptions.communication(),
      includeAndroidAudioConfiguration: true,
      enableWARP: true,
    );
    expect(m['bypassVoiceProcessing'], true);
    expect(m['enableWARP'], true);
    expect(m.containsKey('androidAudioConfiguration'), isTrue);
  });
}

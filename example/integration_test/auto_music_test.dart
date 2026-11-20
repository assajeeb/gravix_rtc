// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// On-device A/B for auto music (0.11.3): the real microphone through Gravix NS,
// Opus with DTX ON (as a room publishes it), loopback peers; the RECEIVED
// level every 100 ms plus GravixNsState.musicDetected. Play the stimulus from
// a speaker after `AMTEST ready` (song / talk / noise), then compare runs:
//
//   flutter test integration_test/auto_music_test.dart -d <device> --dart-define=AUTOMUSIC=true|false
//
// Lines: `AMTEST t=<s> det=<0|1> lv=<dB x10 per 100 ms>`.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

const _autoMusic = bool.fromEnvironment('AUTOMUSIC', defaultValue: true);
const _seconds = int.fromEnvironment('AMSECONDS', defaultValue: 140);

Future<double?> _inLevel(rtc.RTCPeerConnection pc) async {
  for (final r in await pc.getStats()) {
    if (r.type == 'inbound-rtp' && r.values['kind'] == 'audio') {
      return (r.values['audioLevel'] as num?)?.toDouble();
    }
  }
  return null;
}

rtc.RTCSessionDescription _dtx(rtc.RTCSessionDescription d) =>
    rtc.RTCSessionDescription(d.sdp!.replaceAll('useinbandfec=1', 'useinbandfec=1;usedtx=1'), d.type);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('auto music A/B (received level)', (tester) async {
    await Future<void>.delayed(const Duration(seconds: 4)); // permission grant
    final ns = GravixNoiseSuppression.instance;
    final st = await ns.configure(const GravixNoiseSuppressionOptions().copyWith(autoMusic: _autoMusic));
    debugPrint('AMTEST ns=$st autoMusic=$_autoMusic');
    final track = await LocalAudioTrack.create();
    await track.start();
    final a = await rtc.createPeerConnection(<String, dynamic>{});
    final b = await rtc.createPeerConnection(<String, dynamic>{});
    a.onIceCandidate = (c) => b.addCandidate(c);
    b.onIceCandidate = (c) => a.addCandidate(c);
    await a.addTrack(track.mediaStreamTrack, track.mediaStream);
    final offer = await a.createOffer(<String, dynamic>{});
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(_dtx(offer));
    final answer = await b.createAnswer(<String, dynamic>{});
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(_dtx(answer)); // the sender's encoder: DTX on
    for (var i = 0; i < 40 && a.connectionState != rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    debugPrint('AMTEST ready peers=${a.connectionState} dtx=${answer.sdp!.contains('usedtx=1') ? 'answer' : 'munged'}');
    final sw = Stopwatch()..start();
    final lv = <int>[];
    var det = 0;
    while (sw.elapsed.inSeconds < _seconds) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final l = await _inLevel(b);
      lv.add(l == null || l <= 0 ? -900 : (200 * math.log(l) / math.ln10).round()); // dB x10
      if (lv.length == 10) {
        final s = await ns.refreshStats();
        det = s.musicDetected ? 1 : 0;
        debugPrint('AMTEST t=${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} det=$det lv=${lv.join(',')}');
        lv.clear();
      }
    }
    debugPrint('AMTEST done');
    await a.close();
    await b.close();
    await track.stop();
    await track.dispose();
  });
}

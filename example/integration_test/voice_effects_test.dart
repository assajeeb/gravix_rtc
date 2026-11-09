// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// On-device proof for voice effects: the native library loads on this ABI, each
// effect is timed, and the real WebRTC capture path runs every effect (the
// native block counter advances while the effect is active).
//
//   flutter test integration_test/voice_effects_test.dart -d <device>
//
// RECORD_AUDIO must be granted right after install (the test waits 6 s for it).
// Every step prints `FXTEST ...`.
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

const _channel = MethodChannel('gravix_client');

Future<Map<Object?, Object?>> _stats() async =>
    (await _channel.invokeMethod<Map<Object?, Object?>>('fxStats', <String, dynamic>{}))!;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every effect loads, is timed, and runs on the capture path', (tester) async {
    final fx = GravixVoiceEffects.instance;

    for (final e in GravixVoiceEffect.values.where((e) => e != GravixVoiceEffect.none)) {
      final b = await fx.benchmark(e, seconds: 2);
      expect(b, isNotNull, reason: 'benchmark failed for ${e.name}');
      debugPrint('FXTEST bench ${e.name} p50=${b!.p50Us} p95=${b.p95Us} max=${b.maxUs} latency=${b.latencyMs}');
      expect(b.p95Us, lessThan(6000), reason: 'over the 6 ms budget: ${e.name}');
    }

    await Future<void>.delayed(const Duration(seconds: 6)); // permission grant
    expect(await fx.set(GravixVoiceEffect.robot), isTrue);
    final track = await LocalAudioTrack.create();
    await track.start();
    // Two real peer connections in this app: a send stream is what runs the capture pipeline.
    final a = await rtc.createPeerConnection(<String, dynamic>{});
    final b = await rtc.createPeerConnection(<String, dynamic>{});
    a.onIceCandidate = (c) => b.addCandidate(c);
    b.onIceCandidate = (c) => a.addCandidate(c);
    await a.addTrack(track.mediaStreamTrack, track.mediaStream);
    final offer = await a.createOffer(<String, dynamic>{});
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(offer);
    final answer = await b.createAnswer(<String, dynamic>{});
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(answer);
    for (var i = 0; i < 40 && a.connectionState != rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    debugPrint('FXTEST peers state=${a.connectionState}');
    await Future<void>.delayed(const Duration(seconds: 2));

    for (final e in GravixVoiceEffect.values.where((e) => e != GravixVoiceEffect.none)) {
      expect(await fx.set(e), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final before = (await _stats())['frames'] as num;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final s = await _stats();
      final frames = (s['frames'] as num) - before;
      debugPrint(
        'FXTEST live ${e.name} active=${s['active']} rate=${s['rate']} frames=$frames '
        'latency=${s['latencyMs']} over=${s['over']} maxUs=${s['maxUs']} watchdog=${s['watchdog']}',
      );
      expect(s['active'], e.name);
      expect(frames, greaterThan(100), reason: 'capture path did not run ${e.name}');
      expect(s['watchdog'], isFalse);
    }

    expect(await fx.set(GravixVoiceEffect.none), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final off = await _stats();
    debugPrint('FXTEST off active=${off['active']} latency=${off['latencyMs']}');
    expect(off['active'], 'none');
    expect(off['latencyMs'], 0);

    await a.close();
    await b.close();
    await track.stop();
    await track.dispose();
  });
}

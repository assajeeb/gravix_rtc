// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// On-device check: a voice effect stays on while room music plays (music mixed
// after the effect). Prints `VMTEST ...`; logcat tag GxMusicMixer shows route=.
//
//   flutter test integration_test/voice_music_test.dart -d <device>
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

const _client = MethodChannel('gravix_client');
const _music = MethodChannel('com.gravitycompile.gravix_rtc/music');

Future<Map<Object?, Object?>> _fx() async => (await _client
    .invokeMethod<Map<Object?, Object?>>('fxStats', <String, dynamic>{}))!;

/// 20 s, 48 kHz mono, 1 kHz sine at -12 dBFS.
Future<String> _wav() async {
  const rate = 48000, secs = 20, n = rate * secs;
  final b = ByteData(44 + n * 2);
  void s(int o, String t) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(o + i, t.codeUnitAt(i));
    }
  }

  s(0, 'RIFF');
  b.setUint32(4, 36 + n * 2, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  s(36, 'data');
  b.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    b.setInt16(
      44 + i * 2,
      (8200 * math.sin(2 * math.pi * 1000 * i / rate)).round(),
      Endian.little,
    );
  }
  final f = File('${Directory.systemTemp.path}/vm_tone.wav');
  await f.writeAsBytes(b.buffer.asUint8List());
  return f.path;
}

Future<double?> _inLevel(rtc.RTCPeerConnection pc) async {
  for (final r in await pc.getStats()) {
    if (r.type == 'inbound-rtp' && r.values['kind'] == 'audio') {
      return (r.values['audioLevel'] as num?)?.toDouble();
    }
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('voice effect stays on while music plays', (tester) async {
    final path = await _wav();
    await Future<void>.delayed(const Duration(seconds: 6)); // permission grant
    final fx = GravixVoiceEffects.instance;
    expect(await fx.set(GravixVoiceEffect.girl), isTrue);
    final track = await LocalAudioTrack.create();
    await track.start();
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
    for (
      var i = 0;
      i < 40 &&
          a.connectionState !=
              rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    debugPrint(
      'VMTEST peers=${a.connectionState} levelNoMusic=${await _inLevel(b)}',
    );

    debugPrint(
      'VMTEST install=${await _music.invokeMethod<Object?>('install')}',
    );
    for (var i = 0; i < 40; i++) {
      final st = await _music.invokeMethod<Map<Object?, Object?>>('getState');
      if (st?['captureLive'] == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    debugPrint(
      'VMTEST captureState=${await _music.invokeMethod<Object?>('getState')} fx=${await _fx()}',
    );
    final start = await _music.invokeMethod<Object?>('start', <String, dynamic>{
      'source': path,
      'monitor': false,
      'musicVolume': 1.0,
    });
    debugPrint('VMTEST start=$start');
    for (var k = 0; k < 3; k++) {
      final f0 = (await _fx())['frames'] as num;
      await Future<void>.delayed(const Duration(seconds: 2));
      final s = await _fx();
      final st = await _music.invokeMethod<Map<Object?, Object?>>('getState');
      debugPrint(
        'VMTEST music k=$k active=${s['active']} musicBypass=${s['musicBypass']} frames=${(s['frames'] as num) - f0} '
        'watchdog=${s['watchdog']} pos=${st?['positionMs']} level=${await _inLevel(b)}',
      );
      expect(s['active'], 'girl');
      expect(
        s['musicBypass'],
        isFalse,
        reason: 'effect bypassed while music plays',
      );
    }
    // effect off mid-song, then back on
    expect(await fx.set(GravixVoiceEffect.none), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    debugPrint(
      'VMTEST fxOff level=${await _inLevel(b)} pos=${(await _music.invokeMethod<Map<Object?, Object?>>('getState'))?['positionMs']}',
    );
    expect(await fx.set(GravixVoiceEffect.robot), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    final s2 = await _fx();
    debugPrint(
      'VMTEST fxBack active=${s2['active']} musicBypass=${s2['musicBypass']} level=${await _inLevel(b)}',
    );
    await _music.invokeMethod<Object?>('stop');
    await Future<void>.delayed(const Duration(seconds: 1));
    debugPrint('VMTEST afterStop level=${await _inLevel(b)}');
    await fx.set(GravixVoiceEffect.none);
    await a.close();
    await b.close();
    await track.stop();
    await track.dispose();
  });
}

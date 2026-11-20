// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// On-device check (iOS): native events reach the UI engine while a second
// (headless) engine runs, which used to take them over (0.11.2 fix):
//  - voice effect `music` events (iOS still goes dry while music plays: bypass
//    true at the start, false once the track ends),
//  - room music `onCompleted`,
//  - noise suppression `onNsEvent`.
// Prints `IOSEV ...`.
//
//   flutter test integration_test/ios_events_test.dart -d <iphone>
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_cloud_example/second_engine.dart' as second; // keeps the entry point in the kernel
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

const _second = MethodChannel('gravix_example/second_engine');

/// [secs] s, 48 kHz mono, 1 kHz sine at -12 dBFS.
Future<String> _wav(int secs) async {
  const rate = 48000;
  final n = rate * secs;
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
    b.setInt16(44 + i * 2, (8200 * math.sin(2 * math.pi * 1000 * i / rate)).round(), Endian.little);
  }
  final f = File('${Directory.systemTemp.path}/iosev_tone.wav');
  await f.writeAsBytes(b.buffer.asUint8List());
  return f.path;
}

final _out = File('${Directory.systemTemp.path}/iosev.txt');

/// Printed and appended to tmp/iosev.txt in the app container (a profile build
/// has no Dart console: `devicectl device copy from --domain-type appDataContainer`).
void _log(String line) {
  debugPrint(line);
  _out.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

Future<bool> _until(bool Function() ok, Duration max) async {
  final end = DateTime.now().add(max);
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return ok();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native events reach the UI engine with a second engine running', (tester) async {
    second.secondEngineMain; // referenced so the import stays
    expect(Platform.isIOS, isTrue, reason: 'iOS-only check');
    if (_out.existsSync()) _out.deleteSync();
    expect(await _second.invokeMethod<bool>('spawn'), isTrue, reason: 'second engine did not start');
    await Future<void>.delayed(const Duration(seconds: 2));
    _log('IOSEV secondEngine=started');

    final fx = GravixVoiceEffects.instance;
    final bypass = <bool>[];
    void onFx() => bypass.add(fx.state.value.musicBypass);
    final ns = <Map<String, Object?>>[];
    final nsSub = GravixNoiseNative.events.listen(ns.add);

    expect(await fx.set(GravixVoiceEffect.girl), isTrue);
    fx.state.addListener(onFx);
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
    await _until(
      () => a.connectionState == rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      const Duration(seconds: 10),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    _log('IOSEV peers=${a.connectionState} fx=${fx.state.value}');

    final music = GravixMusicController();
    var completed = 0;
    final doneSub = music.onCompleted.listen((_) => completed++);
    _log('IOSEV install=${await music.install()}');
    final t0 = DateTime.now();
    await music.start(path: await _wav(4), gain: 0.5, monitor: false);

    final gotOn = await _until(() => bypass.contains(true), const Duration(seconds: 3));
    _log('IOSEV musicOn bypassEvents=$bypass after=${DateTime.now().difference(t0).inMilliseconds}ms');
    final gotDone = await _until(() => completed > 0, const Duration(seconds: 10));
    _log('IOSEV onCompleted=$completed after=${DateTime.now().difference(t0).inMilliseconds}ms');
    final gotOff = await _until(
      () => bypass.isNotEmpty && bypass.last == false && bypass.contains(true),
      const Duration(seconds: 4),
    );
    _log('IOSEV musicOff bypassEvents=$bypass fx=${fx.state.value}');
    _log('IOSEV nsEvents=${ns.length} steps=${ns.map((e) => e['type']).toList()}');

    final singerOn = await GravixNoiseNative.setSingerMode(true, 'keep');
    final singerOff = await GravixNoiseNative.setSingerMode(false, 'keep');
    _log('IOSEV singerOn=$singerOn singerOff=$singerOff');

    fx.state.removeListener(onFx);
    await doneSub.cancel();
    await nsSub.cancel();
    await music.stop();
    await fx.set(GravixVoiceEffect.none);
    await a.close();
    await b.close();
    await track.stop();
    await track.dispose();

    _log('IOSEV RESULT gotOn=$gotOn gotDone=$gotDone gotOff=$gotOff');
    expect(gotOn, isTrue, reason: 'voice effect music event (bypass on) never reached Dart');
    expect(gotDone, isTrue, reason: 'music onCompleted never reached Dart');
    expect(gotOff, isTrue, reason: 'voice effect music event (bypass off) never reached Dart');
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// On-device check of the voice effect + room music through the ROOM API
// (GravixRoomService.connect + roomMusic), i.e. with the mic republishes the
// room path does (DTX swap on music start/stop) and its relaxed voice
// processing. Android: the music must ride after the effect (route post),
// survive the republishes and restarts (no fallback, nothing dropped), keep
// its level between the pre and post routes, and follow the effect's delay.
//
//   flutter test integration_test/room_voice_music_test.dart -d <device> \
//     --dart-define-from-file=<dir-outside-the-repo>/defines.json
//   # GX_URL, GX_TOKEN (a publisher: canPublish true, any room)
//
// Without GX_TOKEN the test is skipped. Every step prints `RVMTEST ...`;
// logcat tag GxMusicMixer prints `music started/stopped route=...`.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

const _url = String.fromEnvironment('GX_URL');
const _token = String.fromEnvironment('GX_TOKEN');

const _client = MethodChannel('gravix_client');
const _music = MethodChannel('com.gravitycompile.gravix_rtc/music');

Future<Map<Object?, Object?>> _fx() async => (await _client
    .invokeMethod<Map<Object?, Object?>>('fxStats', <String, dynamic>{}))!;

Future<Map<Object?, Object?>> _mix() async =>
    (await _music.invokeMethod<Map<Object?, Object?>>('getState'))!;

/// 60 s, 48 kHz mono, 1 kHz sine at -12 dBFS.
Future<String> _wav() async {
  const rate = 48000, secs = 60, n = rate * secs;
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
  final f = File('${Directory.systemTemp.path}/rvm_tone.wav');
  await f.writeAsBytes(b.buffer.asUint8List());
  return f.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('room path: effect + music, post route survives republishes, same level', (
    tester,
  ) async {
    if (_token.isEmpty) {
      markTestSkipped('GX_TOKEN not set');
      return;
    }
    final t0 = DateTime.now();
    void log(String s) => debugPrint(
      'RVMTEST +${DateTime.now().difference(t0).inMilliseconds}ms $s',
    );
    final path = await _wav();
    await Future<void>.delayed(const Duration(seconds: 4)); // permission grant

    final svc = GravixRoomService();
    expect(
      await svc.connect(
        url: _url,
        token: _token,
        publishMic: true,
        media: GravixRoomMedia.audio,
      ),
      isTrue,
      reason: 'join failed',
    );
    final room = svc.room!;
    LocalAudioTrack? mic() =>
        room.localParticipant
                ?.getTrackPublicationBySource(TrackSource.microphone)
                ?.track
            as LocalAudioTrack?;
    for (var i = 0; i < 40 && mic() == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(mic(), isNotNull, reason: 'mic not published');
    log(
      'joined region=${room.connectedRegion} dtx=${mic()?.lastPublishOptions?.dtx}',
    );

    // sender-side level after APM + effect + post mix (what goes to the SFU)
    Future<double> level() async {
      final v = <double>[];
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final l = (await mic()?.getSenderStats())?.audioSourceStats?.audioLevel
            ?.toDouble();
        if (l != null) v.add(l);
      }
      return v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
    }

    Future<Map<Object?, Object?>> expectRoute(String route, String step) async {
      final st = await _mix();
      final fx = await _fx();
      log(
        '$step route=${st['mixRoute']} delay=${st['mixDelaySamples']} switches=${st['mixSwitches']} '
        'dropped=${st['mixDropped']} gaps=${st['mixCaptureGaps']} retimes=${st['mixRetimes']} '
        'pos=${st['positionMs']} fx=${fx['active']} bypass=${fx['musicBypass']} latency=${fx['latencyMs']}',
      );
      if (Platform.isAndroid) {
        expect(st['mixRoute'], route, reason: step);
        expect(
          st['mixDropped'],
          0,
          reason: '$step: hand-offs lost (processor not running)',
        );
      }
      return st;
    }

    final fx = GravixVoiceEffects.instance;
    final music = svc.roomMusic;

    // 1. effect first, then music (DTX swap republish inside start)
    expect(await fx.set(GravixVoiceEffect.girl), isTrue);
    await music.start(GravixMusicSource.file(path), loop: true, volume: 1.0);
    await Future<void>.delayed(const Duration(seconds: 2));
    var st = await expectRoute('post', 'girl+music');
    if (Platform.isAndroid) {
      expect(
        (st['mixDelaySamples'] as num) > 0,
        isTrue,
        reason: 'music not delayed to the effect',
      );
      expect(
        (await _fx())['musicBypass'],
        isFalse,
        reason: 'effect bypassed while music plays',
      );
    }
    final lPost = await level();

    // 2. effect off mid-song: pre route; level must match (relaxed processing = no AGC lift)
    expect(await fx.set(GravixVoiceEffect.none), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    await expectRoute('pre', 'none');
    final lPre = await level();
    final db = 20 * math.log(lPost / lPre) / math.ln10;
    log(
      'level post=${lPost.toStringAsFixed(3)} pre=${lPre.toStringAsFixed(3)} diff=${db.toStringAsFixed(2)} dB',
    );
    expect(
      db.abs() < 1.5,
      isTrue,
      reason: 'music level jumps ${db.toStringAsFixed(2)} dB between routes',
    );

    // 3. back on, then a preset with another delay (re-time)
    expect(await fx.set(GravixVoiceEffect.girl), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    await expectRoute('post', 'girl again');
    expect(await fx.set(GravixVoiceEffect.robot), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    st = await expectRoute('post', 'robot');

    // 4. mic mute / unmute mid-song (voice-only mute keeps the music)
    await svc.setMicEnabled(false);
    await Future<void>.delayed(const Duration(seconds: 2));
    await expectRoute('post', 'muted');
    await svc.setMicEnabled(true);
    await Future<void>.delayed(const Duration(seconds: 2));
    await expectRoute('post', 'unmuted');

    // 5. stop (DTX swap back) and start again: the post route comes back
    await music.stop();
    await Future<void>.delayed(const Duration(seconds: 2));
    log('stopped state=${music.state.value.status}');
    await music.start(GravixMusicSource.file(path), loop: true, volume: 1.0);
    await Future<void>.delayed(const Duration(seconds: 3));
    await expectRoute('post', 'restart');

    await music.stop();
    await fx.set(GravixVoiceEffect.none);
    await svc.disconnect();
    log('done');
  });
}

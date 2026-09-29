// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// On-device proof for the mute/unmute playout bug (field report 2026-09-30:
// "after mute+unmute the OTHERS' audio goes silent for a moment; toggling
// repeatedly stops it completely").
//
// Needs a live room with a remote audio publisher (e.g. a headless-Chrome tab
// with fake audio). The join credentials come in as dart-defines, from a file
// so the token never appears on a command line:
//
//   flutter test integration_test/mute_playout_test.dart -d emulator-5554 \
//     --dart-define-from-file=<dir-outside-the-repo>/defines.json   # GX_URL, GX_TOKEN
//
// Without GX_TOKEN the test is skipped.
//
// What it measures: the remote audio receiver's counters, sampled every 500 ms.
// `bytesReceived` only proves the network still delivers; `totalSamplesReceived`
// / `totalAudioEnergy` advance only while the playout side pulls decoded audio,
// so a playout stall shows as bytes rising with samples flat. Every sample line
// is printed as `MUTEPROOF {json}` for the run log.
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

const _url = String.fromEnvironment('GX_URL');
const _token = String.fromEnvironment('GX_TOKEN');
const _rapidToggles = int.fromEnvironment('GX_TOGGLES', defaultValue: 20);
const _rapidGapMs = int.fromEnvironment('GX_TOGGLE_GAP_MS', defaultValue: 250);

class _Sample {
  _Sample(this.at, this.phase, this.bytes, this.samples, this.energy, this.concealed, this.sent, this.micMuted);
  final DateTime at;
  final String phase;
  final num bytes, samples, energy, concealed, sent;
  final bool micMuted;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mute/unmute keeps remote audio playing', (tester) async {
    if (_token.isEmpty) {
      markTestSkipped('GX_TOKEN not set');
      return;
    }
    // the run script grants RECORD_AUDIO right after install; give it a moment
    await Future<void>.delayed(const Duration(seconds: 4));
    final svc = GravixRoomService();
    final ok = await svc.connect(url: _url, token: _token, publishMic: true, publishInBackground: true);
    expect(ok, isTrue, reason: 'join failed');
    final room = svc.room!;

    // wait for the remote publisher's audio
    RemoteAudioTrack? remote;
    for (var i = 0; i < 60 && remote == null; i++) {
      for (final p in room.remoteParticipants.values) {
        for (final pub in p.audioTrackPublications) {
          if (pub.track != null) remote = pub.track;
        }
      }
      if (remote == null) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    expect(remote, isNotNull, reason: 'no remote audio track');

    // every isMicMuted change, timestamped (the 500 ms samples alias 250 ms taps)
    void onMic() => debugPrint('MUTEPROOF_MIC ${DateTime.now().toIso8601String()} muted=${svc.isMicMuted.value}');
    svc.isMicMuted.addListener(onMic);

    final series = <_Sample>[];
    var phase = 'base';
    Future<void> sample() async {
      num bytes = 0, samples = 0, energy = 0, concealed = 0, sent = 0;
      for (final p in room.remoteParticipants.values) {
        for (final pub in p.audioTrackPublications) {
          final st = await pub.track?.getReceiverStats();
          if (st == null) continue;
          bytes += st.bytesReceived ?? 0;
          samples += st.totalSamplesReceived ?? 0;
          energy += st.totalAudioEnergy ?? 0;
          concealed += st.concealedSamples ?? 0;
        }
      }
      for (final pub
          in room.localParticipant?.audioTrackPublications ?? const <LocalTrackPublication<LocalAudioTrack>>[]) {
        final st = await pub.track?.getSenderStats();
        sent += st?.bytesSent ?? 0;
      }
      final s = _Sample(DateTime.now(), phase, bytes, samples, energy, concealed, sent, svc.isMicMuted.value);
      series.add(s);
      debugPrint(
        'MUTEPROOF ${jsonEncode({'t': s.at.toIso8601String(), 'phase': phase, 'bytes': bytes, 'samples': samples, 'energy': energy, 'concealed': concealed, 'sent': sent, 'micMuted': s.micMuted})}',
      );
    }

    var sampling = true;
    final sampler = () async {
      while (sampling) {
        await sample();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }();

    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

    await wait(5000);
    phase = 'mute1';
    await svc.setMicEnabled(false);
    await wait(3000);
    phase = 'unmute1';
    await svc.setMicEnabled(true);
    await wait(4000);

    // Rapid toggles exactly like the tester's button: flip the wanted state and
    // call without waiting for the previous call (a user tapping).
    phase = 'rapid';
    var mic = true;
    final calls = <Future<void>>[];
    for (var i = 0; i < _rapidToggles; i++) {
      mic = !mic;
      calls.add(svc.setMicEnabled(mic));
      await wait(_rapidGapMs);
    }
    phase = 'settle';
    await Future.wait(calls).timeout(const Duration(seconds: 20));
    await wait(8000);
    sampling = false;
    await sampler;

    final micPub = room.localParticipant?.getTrackPublicationBySource(TrackSource.microphone);
    debugPrint(
      'MUTEPROOF_FINAL ${jsonEncode({'wanted_mic': mic, 'isMicMuted': svc.isMicMuted.value, 'pub_muted': micPub?.muted, 'track_enabled': micPub?.track?.mediaStreamTrack.enabled})}',
    );

    // 1-second windows (two samples) after the baseline: the remote audio must
    // keep being played out (samples advance) the whole time.
    final stalls = <String>[];
    for (var i = 2; i < series.length; i++) {
      final a = series[i - 2], b = series[i];
      final dBytes = b.bytes - a.bytes, dSamples = b.samples - a.samples;
      if (dSamples <= 0) stalls.add('${b.phase}@${b.at.toIso8601String()} dBytes=$dBytes dSamples=$dSamples');
    }
    debugPrint('MUTEPROOF_STALLS ${stalls.length} ${stalls.take(20).join(' | ')}');

    // The regression guard for the mechanism: in a steady mute (>= 1 s) the
    // uplink keeps sending (silence) because the recorder keeps running. 0.4.3
    // sent 0 bytes there - the engine had stopped the AudioRecord.
    final stoppedRecorder = <String>[];
    for (var i = 2; i < series.length; i++) {
      final a = series[i - 2], b = series[i];
      if (a.micMuted && series[i - 1].micMuted && b.micMuted && a.phase == 'mute1' && b.phase == 'mute1') {
        if (b.sent - a.sent <= 0) stoppedRecorder.add('${b.at.toIso8601String()} dSent=${b.sent - a.sent}');
      }
    }
    debugPrint('MUTEPROOF_RECORDER_STOPPED ${stoppedRecorder.length} ${stoppedRecorder.join(' | ')}');

    svc.isMicMuted.removeListener(onMic);
    final finalMuted = svc.isMicMuted.value;
    final finalPubMuted = micPub?.muted;
    await svc.disconnect();

    expect(stalls, isEmpty, reason: 'remote playout stalled');
    expect(stoppedRecorder, isEmpty, reason: 'muting stopped the recorder (nothing sent while muted)');
    expect(finalMuted, mic == false, reason: 'final mic state is not the last requested one');
    expect(finalPubMuted, !mic, reason: 'published mic mute state is not the last requested one');
  }, timeout: const Timeout(Duration(minutes: 4)));
}

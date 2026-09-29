// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field 2026-09-30 (Android tester 0.3.2+5 / gravix_rtc 0.4.3): "after mute +
// unmute the OTHERS' audio goes silent for a moment; toggling repeatedly stops it".
// Muting disabled the mic track; the WebRTC engine (webrtc-sdk, stop-on-mute
// ADM) then STOPPED the Android AudioRecord and re-created it on every unmute
// (emulator: one new AudioFlinger record thread per unmute, 0 bytes sent while
// muted). Opening/closing a VOICE_COMMUNICATION input under a live call
// re-routes the device's voice path on OEM HALs, which is what interrupted the
// playout of the other participants.
//
// On Android a mute with `stopAudioCaptureOnMute: false` now keeps the track
// enabled and the recorder running, and zeroes the captured audio in the audio
// device module instead (JavaAudioDeviceModule.setMicrophoneMute), plus the usual
// mute signal. If the native mute is not available it falls back to the old
// disable path: the microphone never stays live unconfirmed.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

class _FakeTrack implements rtc.MediaStreamTrack {
  @override
  bool enabled = true;
  bool stopped = false;
  @override
  String? get id => 'mic-1';
  @override
  String? get kind => 'audio';
  @override
  Future<void> stop() async => stopped = true;
  // callbacks the core installs (onEnded, ...) are accepted and ignored
  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isSetter ? null : super.noSuchMethod(invocation);
}

class _FakeStream implements rtc.MediaStream {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<bool> nativeCalls;
  late bool nativeOk;

  setUp(() {
    nativeCalls = <bool>[];
    nativeOk = true;
    GravixEngineMicMute.debugReset(
      supported: () => true,
      setNative: (mute) async {
        nativeCalls.add(mute);
        return nativeOk;
      },
    );
  });

  tearDown(GravixEngineMicMute.debugReset);

  Future<(LocalAudioTrack, _FakeTrack, List<InternalTrackMuteUpdatedEvent>)> startedTrack() async {
    final media = _FakeTrack();
    final t = LocalAudioTrack(TrackSource.microphone, _FakeStream(), media, const AudioCaptureOptions());
    final signals = <InternalTrackMuteUpdatedEvent>[];
    t.events.on<InternalTrackMuteUpdatedEvent>(signals.add);
    await t.start();
    return (t, media, signals);
  }

  test('mute keeps the track enabled and the recorder running; the engine zeroes the mic', () async {
    final (t, media, signals) = await startedTrack();
    expect(await t.mute(stopOnMute: false), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(t.muted, isTrue);
    expect(media.enabled, isTrue, reason: 'a disabled track makes the engine stop the AudioRecord');
    expect(media.stopped, isFalse);
    expect(nativeCalls, [true]);
    expect(signals.single.muted, isTrue);
    expect(signals.single.shouldSendSignal, isTrue, reason: 'the others must still see the mute');

    expect(await t.unmute(stopOnMute: false), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(t.muted, isFalse);
    expect(media.enabled, isTrue);
    expect(nativeCalls, [true, false]);
    expect(GravixEngineMicMute.engaged, isFalse);
    await t.dispose();
  });

  test('20 mute/unmute cycles: no track disable, no restart, one native call each', () async {
    final (t, media, _) = await startedTrack();
    for (var i = 0; i < 20; i++) {
      await t.mute(stopOnMute: false);
      expect(media.enabled, isTrue);
      await t.unmute(stopOnMute: false);
    }
    expect(nativeCalls.length, 40);
    expect(media.stopped, isFalse);
    expect(t.muted, isFalse);
    await t.dispose();
  });

  test('native mute unavailable: falls back to disabling the track (never live unconfirmed)', () async {
    nativeOk = false;
    final (t, media, signals) = await startedTrack();
    await t.mute(stopOnMute: false);
    expect(t.muted, isTrue);
    expect(media.enabled, isFalse);
    expect(GravixEngineMicMute.engaged, isFalse);
    await t.unmute(stopOnMute: false);
    expect(media.enabled, isTrue);
    expect(nativeCalls, [true], reason: 'nothing engaged, nothing to release');
    await Future<void>.delayed(Duration.zero);
    expect(signals.map((e) => e.muted), [true, false]);
    await t.dispose();
  });

  test('stopOnMute: true keeps the stop path (no engine mute)', () async {
    final (t, _, _) = await startedTrack();
    await t.mute(stopOnMute: true);
    expect(nativeCalls, isEmpty);
    await t.dispose();
  });

  test('unsupported platform (iOS, web): the old disable path', () async {
    GravixEngineMicMute.debugReset(
      supported: () => false,
      setNative: (m) async {
        nativeCalls.add(m);
        return true;
      },
    );
    final (t, media, _) = await startedTrack();
    await t.mute(stopOnMute: false);
    expect(media.enabled, isFalse);
    expect(nativeCalls, isEmpty);
    await t.dispose();
  });

  test('stopping a muted track releases the engine mute (engine-wide state)', () async {
    final (t, _, _) = await startedTrack();
    await t.mute(stopOnMute: false);
    expect(GravixEngineMicMute.engaged, isTrue);
    await t.stop();
    expect(GravixEngineMicMute.engaged, isFalse);
    expect(nativeCalls, [true, false]);
    await t.dispose();
  });

  test('a new track never inherits a stale engine mute', () async {
    final (t, _, _) = await startedTrack();
    await t.mute(stopOnMute: false);
    // e.g. the room was left with the mic muted and the track was not stopped
    final (t2, _, _) = await startedTrack();
    expect(GravixEngineMicMute.engaged, isFalse);
    expect(nativeCalls, [true, false]);
    await t.dispose();
    await t2.dispose();
  });
}

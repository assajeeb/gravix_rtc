// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Owner 2026-10-02: while muted, the mic must stop costing uplink (46-75 kbps
// of encoded zeros in the field) WITHOUT the 0.4.4 regression: the recorder
// keeps running (engine-level mute), no track restart, no renegotiation.
//
// Mechanism: the mic sender's maxBitrate is capped at 6 kbps while muted and
// restored on unmute (MicUplinkPause). `encodings[0].active = false` was tried
// first and REJECTED on the phone (Xiaomi 2201117TG, 2026-10-02): an inactive
// encoding stops the send stream and the engine then stops the AudioRecord
// (`rec stop` at the mute, `rec start` at the unmute), the very bug the engine
// mute exists to avoid. The tests below pin: cap on mute / restore on unmute in
// the right order around the engine mute, the refused-cap fallback (cache
// reverted), rapid toggles, no recorder restart, the mute signal, republish
// while muted, and the audio-first interleaving.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/gravix_rtc.dart' show GravixRoomService;
import 'package:gravix_rtc/src/room/gravix_audio_first.dart';
import 'package:gravix_rtc/src/room/gravix_red_mode.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/mic_uplink_pause.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

/// One interleaved log of everything that touches the mic: native engine mute
/// calls, setParameters (with the bitrate sent), track stop / replaceTrack.
final calls = <String>[];

class _FakeTrack implements rtc.MediaStreamTrack {
  @override
  bool enabled = true;
  bool stopped = false;
  @override
  String? get id => 'mic-1';
  @override
  String? get kind => 'audio';
  @override
  Future<void> stop() async {
    stopped = true;
    calls.add('track.stop');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isSetter ? null : super.noSuchMethod(invocation);
}

class _FakeStream implements rtc.MediaStream {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// flutter_webrtc 1.6.0's native sender: ONE cached parameters object,
/// replaced by whatever setParameters is given (before the native call).
class _FakeSender implements rtc.RTCRtpSender {
  _FakeSender(this.name, {int? maxBitrate = 64000})
    : _parameters = rtc.RTCRtpParameters(encodings: [rtc.RTCRtpEncoding(maxBitrate: maxBitrate)]);
  final String name;
  rtc.RTCRtpParameters _parameters;

  /// What the "native side" has applied.
  int? nativeMaxBitrate = 64000;
  bool? nativeActive = true;

  /// Behaviour of the next setParameters calls (popped in order; default ok).
  final results = <Object>[]; // true / false / 'throw'
  Completer<void>? gate;

  @override
  rtc.RTCRtpParameters get parameters => _parameters;

  @override
  Future<bool> setParameters(rtc.RTCRtpParameters parameters) async {
    _parameters = parameters;
    final g = gate;
    if (g != null) await g.future;
    final r = results.isEmpty ? true : results.removeAt(0);
    final enc = parameters.encodings!.first;
    calls.add('$name.setParameters(${enc.maxBitrate}${enc.active ? '' : ', inactive'})${r == true ? '' : ' -> $r'}');
    if (r == 'throw') throw 'Unable to RTCRtpSenderNative::setParameters: boom';
    if (r == true) {
      nativeMaxBitrate = enc.maxBitrate;
      nativeActive = enc.active;
    }
    return r == true;
  }

  @override
  Future<void> replaceTrack(rtc.MediaStreamTrack? track) async => calls.add('$name.replaceTrack');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTransceiver implements rtc.RTCRtpTransceiver {
  _FakeTransceiver(this.sender);
  @override
  final rtc.RTCRtpSender sender;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool engineSupported;

  setUp(() {
    calls.clear();
    engineSupported = true;
    GravixEngineMicMute.debugReset(
      supported: () => engineSupported,
      setNative: (mute) async {
        calls.add('native.mute($mute)');
        return true;
      },
    );
  });

  tearDown(GravixEngineMicMute.debugReset);

  Future<(LocalAudioTrack, _FakeTrack, _FakeSender, List<InternalTrackMuteUpdatedEvent>)> publishedTrack({
    int? maxBitrate = 64000,
  }) async {
    final media = _FakeTrack();
    final t = LocalAudioTrack(TrackSource.microphone, _FakeStream(), media, const AudioCaptureOptions());
    final signals = <InternalTrackMuteUpdatedEvent>[];
    t.events.on<InternalTrackMuteUpdatedEvent>(signals.add);
    await t.start();
    final sender = _FakeSender('s1', maxBitrate: maxBitrate)..nativeMaxBitrate = maxBitrate;
    t.transceiver = _FakeTransceiver(sender);
    calls.clear();
    return (t, media, sender, signals);
  }

  test('mute caps the sender AFTER the engine mute; unmute restores it BEFORE the engine unmute', () async {
    final (t, media, sender, signals) = await publishedTrack();
    expect(await t.mute(stopOnMute: false), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['native.mute(true)', 's1.setParameters(6000)']);
    expect(sender.nativeMaxBitrate, MicUplinkPause.mutedMaxBitrate);
    expect(sender.nativeActive, isTrue, reason: 'active=false stops the Android AudioRecord (measured 2026-10-02)');
    expect(t.uplinkCapped, isTrue);
    expect(signals.single.muted, isTrue);
    expect(signals.single.shouldSendSignal, isTrue, reason: 'the others must still see the mute');

    calls.clear();
    expect(await t.unmute(stopOnMute: false), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['s1.setParameters(64000)', 'native.mute(false)']);
    expect(sender.nativeMaxBitrate, 64000);
    expect(t.uplinkCapped, isFalse);
    expect(signals.map((e) => (e.muted, e.shouldSendSignal)), [(true, true), (false, true)]);
    // the recorder was never touched: no track stop, no disable, no restart
    expect(media.stopped, isFalse);
    expect(media.enabled, isTrue);
    expect(calls.where((c) => c.contains('replaceTrack') || c == 'track.stop'), isEmpty);
    await t.dispose();
  });

  test('cap refused (false): the cached bitrate is reverted, the mute still happens, unmute sends nothing', () async {
    final (t, media, sender, signals) = await publishedTrack();
    sender.results.add(false);
    expect(await t.mute(stopOnMute: false), isTrue);
    expect(t.muted, isTrue);
    expect(t.uplinkCapped, isFalse);
    expect(
      sender.parameters.encodings!.first.maxBitrate,
      64000,
      reason: 'the next unrelated setParameters (audio-first) must not apply a refused cap',
    );
    expect(sender.nativeMaxBitrate, 64000);
    calls.clear();
    await t.unmute(stopOnMute: false);
    expect(calls, ['native.mute(false)'], reason: 'nothing was capped, nothing to restore');
    expect(media.enabled, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(signals.map((e) => e.muted), [true, false]);
    await t.dispose();
  });

  test('cap throws (flutter_webrtc throws a String): same fallback, never fails the mute', () async {
    final (t, _, sender, _) = await publishedTrack();
    sender.results.add('throw');
    expect(await t.mute(stopOnMute: false), isTrue);
    expect(t.muted, isTrue);
    expect(sender.parameters.encodings!.first.maxBitrate, 64000);
    await t.unmute(stopOnMute: false);
    expect(t.muted, isFalse);
    await t.dispose();
  });

  test('restore refused: retried once, and the unmute still goes ahead', () async {
    final (t, _, sender, _) = await publishedTrack();
    await t.mute(stopOnMute: false);
    sender.results.addAll([false, 'throw']);
    calls.clear();
    expect(await t.unmute(stopOnMute: false), isTrue);
    expect(calls, ['s1.setParameters(64000) -> false', 's1.setParameters(64000) -> throw', 'native.mute(false)']);
    expect(t.muted, isFalse);
    await t.dispose();
  });

  test('engine mute unavailable (iOS / native refused): the disable path is capped too', () async {
    engineSupported = false;
    final (t, media, sender, _) = await publishedTrack();
    await t.mute(stopOnMute: false);
    expect(media.enabled, isFalse);
    expect(sender.nativeMaxBitrate, MicUplinkPause.mutedMaxBitrate);
    await t.unmute(stopOnMute: false);
    expect(media.enabled, isTrue);
    expect(sender.nativeMaxBitrate, 64000);
    expect(calls.where((c) => c.startsWith('native')), isEmpty);
    await t.dispose();
  });

  test('not published yet (no sender): mute / unmute work, nothing to cap', () async {
    final media = _FakeTrack();
    final t = LocalAudioTrack(TrackSource.microphone, _FakeStream(), media, const AudioCaptureOptions());
    await t.start();
    calls.clear();
    await t.mute(stopOnMute: false);
    await t.unmute(stopOnMute: false);
    expect(calls, ['native.mute(true)', 'native.mute(false)']);
    await t.dispose();
  });

  test('an encoding without a cap before is lifted to the Opus maximum on unmute (null is ignored natively)', () async {
    final (t, _, sender, _) = await publishedTrack(maxBitrate: null);
    await t.mute(stopOnMute: false);
    expect(sender.nativeMaxBitrate, MicUplinkPause.mutedMaxBitrate);
    await t.unmute(stopOnMute: false);
    expect(sender.nativeMaxBitrate, MicUplinkPause.opusMaxBitrate);
    await t.dispose();
  });

  test('republished while muted (RED auto / full reconnect): the NEW sender is capped, unmute restores it', () async {
    final (t, _, s1, _) = await publishedTrack();
    await t.onPublish();
    await t.mute(stopOnMute: false);
    expect(s1.nativeMaxBitrate, MicUplinkPause.mutedMaxBitrate);
    // RED auto: unpublish + publish (publication.mute() is a no-op on a muted track)
    await t.onUnpublish();
    final s2 = _FakeSender('s2');
    t.transceiver = _FakeTransceiver(s2);
    calls.clear();
    await t.onPublish();
    expect(calls, ['s2.setParameters(6000)']);
    // full reconnect: publish again WITHOUT an unpublish (super.onPublish returns false)
    final s3 = _FakeSender('s3');
    t.transceiver = _FakeTransceiver(s3);
    calls.clear();
    await t.onPublish();
    expect(calls, ['s3.setParameters(6000)']);
    calls.clear();
    await t.unmute(stopOnMute: false);
    expect(calls, ['s3.setParameters(64000)', 'native.mute(false)'], reason: 'never the removed senders');
    await t.dispose();
  });

  test('a publish while NOT muted leaves the sender alone', () async {
    final (t, _, _, _) = await publishedTrack();
    await t.onPublish();
    expect(calls, isEmpty);
    await t.dispose();
  });

  test('the bitrate moved by someone else while muted is theirs: unmute leaves it', () async {
    final (t, _, sender, _) = await publishedTrack();
    await t.mute(stopOnMute: false);
    final p = sender.parameters;
    p.encodings!.first.maxBitrate = 16000;
    await sender.setParameters(p);
    calls.clear();
    await t.unmute(stopOnMute: false);
    expect(calls, ['native.mute(false)']);
    expect(sender.nativeMaxBitrate, 16000);
    await t.dispose();
  });

  test('audio-first engaged while muted does not record the muted cap (unmuted mic never stuck at 6 kbps)', () async {
    final (t, _, sender, _) = await publishedTrack();
    final room = Room(
      engine: Engine(
        connectOptions: const ConnectOptions(),
        roomOptions: const RoomOptions(),
        signalClient: SignalClient((uri, {options, headers, networkOptions, preconnected}) async => throw 'unused'),
      ),
    );
    final ops = RoomAudioFirstOps(room);
    await t.mute(stopOnMute: false);
    await ops.capMic(t, 16000); // audio-first engages during the mute
    expect(sender.nativeMaxBitrate, MicUplinkPause.mutedMaxBitrate, reason: 'skipped: already below');
    await t.unmute(stopOnMute: false);
    expect(sender.nativeMaxBitrate, 64000);
    await ops.restore();
    expect(sender.nativeMaxBitrate, 64000, reason: 'restore() must not put the unmuted mic at the muted rate');

    // unmuted: audio-first caps and restores as before
    await ops.capMic(t, 16000);
    expect(sender.nativeMaxBitrate, 16000);
    await ops.restore();
    expect(sender.nativeMaxBitrate, 64000);
    await t.dispose();
  });

  test(
    '10 rapid toggles through the service: <= 2 transitions, ends unmuted at the publish rate, recorder untouched',
    () async {
      for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(ch),
          (call) async => <String, dynamic>{},
        );
      }
      final (t, media, sender, signals) = await publishedTrack();
      final s = GravixRoomService(
        applyMic: (enabled) async {
          if (enabled) {
            await t.unmute(stopOnMute: false);
          } else {
            await t.mute(stopOnMute: false);
          }
        },
      );
      sender.gate = Completer<void>(); // hold the first transition mid-flight
      var mic = true;
      final futures = <Future<void>>[];
      for (var i = 0; i < 10; i++) {
        mic = !mic;
        futures.add(s.setMicEnabled(mic));
        await Future<void>.delayed(Duration.zero);
      }
      sender.gate!.complete();
      sender.gate = null;
      await Future.wait(futures);
      await Future<void>.delayed(Duration.zero);
      expect(mic, isTrue);
      expect(t.muted, isFalse);
      expect(sender.nativeMaxBitrate, 64000);
      expect(calls.where((c) => c.contains('setParameters')).length, lessThanOrEqualTo(2));
      expect(calls.where((c) => c.startsWith('native')).length, lessThanOrEqualTo(2));
      expect(signals.length, lessThanOrEqualTo(2));
      expect(signals.last.muted, isFalse);
      expect(media.stopped, isFalse);
      expect(media.enabled, isTrue);
      expect(calls.where((c) => c.contains('replaceTrack') || c == 'track.stop'), isEmpty);
      await t.dispose();
    },
  );

  test('RED auto: muted windows (no packets) never count as loss', () {
    final a = GravixRedAuto(thresholdPct: 3);
    var sent = 0, lost = 0;
    // muted with the encoding inactive / a stalled sender: no packets at all
    for (var i = 0; i < 20; i++) {
      expect(a.feed(sent, lost), isFalse);
      expect(a.lastLossPct, isNull);
    }
    // capped silence: 50 packets/s, the SFU's loss report unchanged
    for (var i = 0; i < 20; i++) {
      sent += 250;
      expect(a.feed(sent, lost), isFalse);
      expect(a.lastLossPct, 0);
    }
    expect(a.fired, isFalse);
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// 2026-10-02: the SFU is to stop forwarding a muted track, and it learns of the
// mute only from the client's MuteTrackRequest (which sets TrackInfo.muted for
// everyone else). Since 0.4.4 an Android mic mute no longer disables the track:
// the audio device module zeroes the PCM (GravixEngineMicMute) and the track stays
// enabled, so the media path alone no longer says "muted". mic_engine_mute_test
// checks the track's internal mute event; this test checks the hop after it --
// the publication turning that event into the MuteTrackRequest on the wire --
// through the same call the room service makes (setMicrophoneEnabled with
// stopAudioCaptureOnMute: false).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/participant/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/publication/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

class _FakeWs extends GravixRtcWebSocket {
  final sent = <lk_rtc.SignalRequest>[];

  @override
  void send(List<int> data) => sent.add(lk_rtc.SignalRequest.fromBuffer(data));
}

class _FakeTrack implements rtc.MediaStreamTrack {
  @override
  bool enabled = true;
  @override
  String? get id => 'mic-1';
  @override
  String? get kind => 'audio';
  @override
  Future<void> stop() async {}
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeWs ws;
  late List<bool> nativeCalls;
  late bool supported;

  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in const ['dev.fluttercommunity.plus/device_info', 'dev.fluttercommunity.plus/package_info']) {
      m.setMockMethodCallHandler(MethodChannel(ch), (call) async => <String, dynamic>{});
    }
    nativeCalls = <bool>[];
    supported = true;
    GravixEngineMicMute.debugReset(
      supported: () => supported,
      setNative: (mute) async {
        nativeCalls.add(mute);
        return true;
      },
    );
  });

  tearDown(GravixEngineMicMute.debugReset);

  Future<(LocalParticipant, _FakeTrack)> publishedMic() async {
    final sc = SignalClient((uri, {options, headers, networkOptions, preconnected}) async => ws = _FakeWs());
    await sc.connect(
      'wss://sfu.example',
      'tok',
      connectOptions: const ConnectOptions(),
      roomOptions: const RoomOptions(),
    );
    final room = Room(
      engine: Engine(connectOptions: const ConnectOptions(), roomOptions: const RoomOptions(), signalClient: sc),
    );
    final lp = await LocalParticipant.createFromInfo(
      room: room,
      info: lk_models.ParticipantInfo(sid: 'PA_me', identity: 'me'),
    );
    final media = _FakeTrack();
    final track = LocalAudioTrack(
      TrackSource.microphone,
      _FakeStream(),
      media,
      const AudioCaptureOptions(stopAudioCaptureOnMute: false),
    );
    await track.start();
    lp.addTrackPublication(
      LocalTrackPublication<LocalAudioTrack>(
        participant: lp,
        info: lk_models.TrackInfo(
          sid: 'TR_mic',
          type: lk_models.TrackType.AUDIO,
          source: lk_models.TrackSource.MICROPHONE,
        ),
        track: track,
      ),
    );
    ws.sent.clear();
    return (lp, media);
  }

  List<(String, bool)> mutes() => [for (final r in ws.sent.where((r) => r.hasMute())) (r.mute.sid, r.mute.muted)];

  const opts = AudioCaptureOptions(stopAudioCaptureOnMute: false);

  test('engine-level mute (Android): MuteTrackRequest{muted: true} goes out, the track stays enabled', () async {
    final (lp, media) = await publishedMic();
    await lp.setMicrophoneEnabled(false, audioCaptureOptions: opts);
    await Future<void>.delayed(Duration.zero);
    expect(nativeCalls, [true], reason: 'the engine-level mute was the path taken');
    expect(media.enabled, isTrue);
    expect(mutes(), [('TR_mic', true)]);

    await lp.setMicrophoneEnabled(true, audioCaptureOptions: opts);
    await Future<void>.delayed(Duration.zero);
    expect(nativeCalls, [true, false]);
    expect(mutes(), [('TR_mic', true), ('TR_mic', false)]);
  });

  test('10 toggles: one MuteTrackRequest per transition, last one unmuted', () async {
    final (lp, _) = await publishedMic();
    for (var i = 0; i < 10; i++) {
      await lp.setMicrophoneEnabled(i.isOdd, audioCaptureOptions: opts);
    }
    await Future<void>.delayed(Duration.zero);
    expect(mutes().length, 10);
    expect(mutes().last, ('TR_mic', false));
  });

  test('engine mute unavailable (fallback: track disabled): the same MuteTrackRequest', () async {
    supported = false;
    final (lp, media) = await publishedMic();
    await lp.setMicrophoneEnabled(false, audioCaptureOptions: opts);
    await Future<void>.delayed(Duration.zero);
    expect(nativeCalls, isEmpty);
    expect(media.enabled, isFalse);
    expect(mutes(), [('TR_mic', true)]);
  });
}

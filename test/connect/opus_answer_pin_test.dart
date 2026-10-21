// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GRAVIX (2026-10-21, DTX): the SFU sometimes answers our mic section by
// mirroring the offer (stereo=1, no usedtx): DTX off, a silent mic sent ~37 kbps.
// The publisher pins the answer's opus fmtp for our published audio: usedtx=1
// unless dtx is off, stereo only for a stereo publication (the JS SDK's rule).
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/transport.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/audio_encoding.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/priority.dart';

import '../support/fake_rtc.dart';

const _offer =
    'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=sendonly\r\n'
    'a=msid:stream-1 mic-cid\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1;stereo=1\r\n';

String _answer(String fmtp) =>
    'v=0\r\no=- 3 4 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=recvonly\r\n'
    'a=rtpmap:111 opus/48000/2\r\na=fmtp:111 $fmtp\r\n';

class _Pc extends FakePeerConnection {
  _Pc() : super(0);
  final remotes = <String>[];
  bool rejectPinned = false;

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    offers.add(Map.of(constraints ?? const {}));
    return rtc.RTCSessionDescription(_offer, 'offer');
  }

  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription description) async {
    if (rejectPinned && (description.sdp ?? '').contains('usedtx=1')) throw Exception('rejected');
    remotes.add(description.sdp ?? '');
    await super.setRemoteDescription(description);
  }
}

String? _opusFmtp(String sdp) => RegExp(r'a=fmtp:111 ([^\r\n]*)').firstMatch(sdp)?.group(1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  group('gravixMungeOpusAnswerFmtp', () {
    test('a mirrored answer gets usedtx=1 and loses stereo; the rest is kept', () {
      expect(
        gravixMungeOpusAnswerFmtp('minptime=10;useinbandfec=1;stereo=1', dtx: true, stereo: false),
        'minptime=10;useinbandfec=1;usedtx=1',
      );
    });
    test('dtx off removes usedtx; a stereo publication keeps stereo=1 once', () {
      expect(gravixMungeOpusAnswerFmtp('usedtx=1;stereo=1', dtx: false, stereo: true), 'stereo=1');
      expect(gravixMungeOpusAnswerFmtp('', dtx: true, stereo: false), 'usedtx=1');
      expect(gravixMungeOpusAnswerFmtp('minptime=10', dtx: false, stereo: true), 'minptime=10;stereo=1');
      expect(
        gravixMungeOpusAnswerFmtp('usedtx=0; maxplaybackrate=48000', dtx: true, stereo: false),
        'maxplaybackrate=48000;usedtx=1',
      );
    });
  });

  group('gravixOpusPublishShape (what a publication pins)', () {
    test('the mono mic keeps the dtx option and is mono', () {
      expect(gravixOpusPublishShape(const AudioPublishOptions()), (stereo: false, dtx: true));
      expect(gravixOpusPublishShape(const AudioPublishOptions(dtx: false)), (stereo: false, dtx: false));
      expect(gravixOpusPublishShape(const AudioPublishOptions(encoding: AudioEncoding.presetMusicHighQuality)), (
        stereo: false,
        dtx: true,
      ));
    });
    test('the room service mic (64 kbps mono) and stereo-bitrate presets stay mono unless stereo is asked', () {
      // review 2026-10-21: the room service publishes const AudioEncoding(maxBitrate: 64000), the
      // bitrate of presetMusicStereo; a bitrate match turned every room-service mic stereo, DTX off
      expect(gravixOpusPublishShape(const AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 64000))), (
        stereo: false,
        dtx: true,
      ));
      for (final e in [AudioEncoding.presetMusicStereo, AudioEncoding.presetMusicHighQualityStereo]) {
        expect(gravixOpusPublishShape(AudioPublishOptions(encoding: e)), (stereo: false, dtx: true));
      }
    });
    test('stereo: true publishes stereo without DTX (the JS SDK rule)', () {
      for (final e in [AudioEncoding.presetMusicStereo, AudioEncoding.presetMusicHighQualityStereo]) {
        expect(gravixOpusPublishShape(AudioPublishOptions(encoding: e, stereo: true)), (stereo: true, dtx: false));
        expect(
          gravixOpusPublishShape(
            AudioPublishOptions(encoding: e.copyWith(bitratePriority: Priority.high), stereo: true),
          ),
          (stereo: true, dtx: false),
        );
      }
      expect(const AudioPublishOptions().copyWith(stereo: true).stereo, isTrue);
    });
  });

  group('gravixPinOpusAnswer', () {
    test('pins only our published sections; nothing to do is null', () {
      final pinned = gravixPinOpusAnswer(
        _answer('minptime=10;useinbandfec=1;stereo=1'),
        {'0': 'mic-cid'},
        {'mic-cid': const GravixOpusPin(dtx: true)},
      )!;
      expect(_opusFmtp(pinned), 'minptime=10;useinbandfec=1;usedtx=1');
      expect(
        gravixPinOpusAnswer(
          _answer('minptime=10;usedtx=1'),
          {'0': 'mic-cid'},
          {'mic-cid': const GravixOpusPin(dtx: true)},
        ),
        isNull,
      );
      expect(
        gravixPinOpusAnswer(_answer('stereo=1'), {'0': 'other'}, {'mic-cid': const GravixOpusPin(dtx: true)}),
        isNull,
      );
    });

    test('never gives one bundled payload type two fmtp lines (left as answered)', () {
      const two =
          'v=0\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0 1\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=recvonly\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 stereo=1\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:1\r\na=recvonly\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 stereo=1\r\n';
      final pins = {'a': const GravixOpusPin(dtx: true), 'b': const GravixOpusPin(dtx: false)};
      expect(gravixPinOpusAnswer(two, {'0': 'a', '1': 'b'}, pins), isNull);
      final same = gravixPinOpusAnswer(two, {'0': 'a', '1': 'b'}, {'a': pins['a']!, 'b': pins['a']!})!;
      expect(RegExp('a=fmtp:111 usedtx=1').allMatches(same), hasLength(2));
    });
  });

  group('the publisher applies the pinned answer', () {
    Future<(Transport, _Pc)> publisher() async {
      final pc = _Pc();
      final t = await Transport.create(
        (Map<String, dynamic> c, [Map<String, dynamic>? k]) async => pc,
        connectOptions: const ConnectOptions(),
      );
      addTearDown(t.dispose);
      t.onOffer = (_) {};
      return (t, pc);
    }

    test('dtx on: a mirrored answer is applied with usedtx=1 and no stereo', () async {
      final (t, pc) = await publisher();
      t.gravixSetOpusPin('mic-cid', dtx: true);
      await t.createAndSendOffer();
      await t.setRemoteDescription(rtc.RTCSessionDescription(_answer('minptime=10;useinbandfec=1;stereo=1'), 'answer'));
      expect(_opusFmtp(pc.remotes.single), 'minptime=10;useinbandfec=1;usedtx=1');
    });

    test('dtx off (connect(dtx: false)): usedtx is removed', () async {
      final (t, pc) = await publisher();
      t.gravixSetOpusPin('mic-cid', dtx: false);
      await t.createAndSendOffer();
      await t.setRemoteDescription(rtc.RTCSessionDescription(_answer('minptime=10;usedtx=1;stereo=1'), 'answer'));
      expect(_opusFmtp(pc.remotes.single), 'minptime=10');
    });

    test('a stereo publication keeps stereo=1 and gets no usedtx', () async {
      final (t, pc) = await publisher();
      t.gravixSetOpusPin('mic-cid', dtx: false, stereo: true);
      await t.createAndSendOffer();
      await t.setRemoteDescription(rtc.RTCSessionDescription(_answer('minptime=10;usedtx=1;stereo=1'), 'answer'));
      expect(_opusFmtp(pc.remotes.single), 'minptime=10;stereo=1');
    });

    test('a pinned answer the native side refuses is applied as answered', () async {
      final (t, pc) = await publisher();
      pc.rejectPinned = true;
      t.gravixSetOpusPin('mic-cid', dtx: true);
      await t.createAndSendOffer();
      await t.setRemoteDescription(rtc.RTCSessionDescription(_answer('stereo=1'), 'answer'));
      expect(_opusFmtp(pc.remotes.single), 'stereo=1');
    });

    test('no audio publication: the answer is untouched', () async {
      final (t, pc) = await publisher();
      await t.createAndSendOffer();
      final a = _answer('stereo=1');
      await t.setRemoteDescription(rtc.RTCSessionDescription(a, 'answer'));
      expect(pc.remotes.single, a);
    });
  });
}

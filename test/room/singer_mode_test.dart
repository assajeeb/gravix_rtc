// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Singer mode (2026-11-20): GravixRoomService.setSingerMode's state machine
// with a fake microphone and fake room-music hooks. Both orders with room
// music (singer then music, music then singer, then stops) keep one owner of
// the microphone's processing / DTX / bitrate and at most one republish per
// switch.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/room/gravix_singer_mode.dart';

const _talk = AudioProcessingOptions(
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
  highPassFilter: true,
);

class _Wire {
  AudioProcessingOptions processing = _talk;
  bool dtx = true;
  int? bitrate = 64000;
  int republishes = 0;
  bool failRepublish = false;
  bool failBitrate = false;
}

class _FakeMic implements GravixSingerMic {
  _FakeMic(this.w);
  final _Wire w;

  @override
  AudioProcessingOptions get processing => w.processing;

  @override
  Future<bool> setProcessing(AudioProcessingOptions o) async {
    w.processing = o;
    return true;
  }

  @override
  bool get dtx => w.dtx;

  @override
  int? get maxBitrate => w.bitrate;

  @override
  Future<bool> setMaxBitrate(int bps) async {
    if (w.failBitrate) return false;
    w.bitrate = bps;
    return true;
  }

  @override
  Future<GravixSingerMic?> republish({required bool dtx, required int maxBitrate}) async {
    if (w.failRepublish) return null;
    w.republishes++;
    w.dtx = dtx;
    w.bitrate = maxBitrate;
    return _FakeMic(w);
  }

  @override
  bool sameAs(GravixSingerMic other) => other is _FakeMic && identical(other.w, w);
}

/// Room music's own behaviour reduced to what singer mode sees: a session
/// relaxes NS/AGC, turns DTX off and raises the bitrate to 96 k (unless the
/// profile is held), and restores at its end what it replaced.
class _FakeMusic implements GravixSingerMusicHooks {
  _FakeMusic(this.w, this.held);
  final _Wire w;
  final bool Function() held;
  bool active = false;
  AudioProcessingOptions? processingBefore;
  bool dtxSwapped = false;
  int? bitrateBefore;
  bool bitrateApplied = false;

  void start() {
    active = true;
    if (held()) return;
    processingBefore = w.processing;
    w.processing = AudioProcessingOptions(
      echoCancellation: w.processing.echoCancellation,
      noiseSuppression: false,
      autoGainControl: false,
      highPassFilter: w.processing.highPassFilter,
    );
    if (w.dtx) {
      w.dtx = false;
      w.republishes++;
      dtxSwapped = true;
    }
    if ((w.bitrate ?? 0) < 96000) {
      bitrateBefore = w.bitrate;
      w.bitrate = 96000;
      bitrateApplied = true;
    }
  }

  void stop() {
    active = false;
    if (bitrateApplied) w.bitrate = bitrateBefore;
    if (processingBefore != null) w.processing = processingBefore!;
    if (dtxSwapped) {
      w.dtx = true;
      w.republishes++;
    }
    processingBefore = null;
    dtxSwapped = false;
    bitrateApplied = false;
  }

  @override
  bool get sessionActive => active;

  @override
  bool get disableDtxWhileMusic => true;

  @override
  ({AudioProcessingOptions? processing, bool dtxSwapped, int? bitrate, bool bitrateApplied}) handOver() {
    final r = (
      processing: processingBefore,
      dtxSwapped: dtxSwapped,
      bitrate: bitrateBefore,
      bitrateApplied: bitrateApplied,
    );
    processingBefore = null;
    dtxSwapped = false;
    bitrateBefore = null;
    bitrateApplied = false;
    return r;
  }

  @override
  Future<bool> retake({
    required AudioProcessingOptions processingBefore,
    required bool dtxBefore,
    required int? bitrateBefore,
  }) async {
    this.processingBefore = processingBefore;
    w.processing = AudioProcessingOptions(
      echoCancellation: processingBefore.echoCancellation,
      noiseSuppression: false,
      autoGainControl: false,
      highPassFilter: processingBefore.highPassFilter,
    );
    this.bitrateBefore = bitrateBefore;
    w.bitrate = 96000;
    bitrateApplied = true;
    dtxSwapped = dtxBefore;
    return true;
  }
}

void main() {
  late _Wire w;
  late bool micUp;
  late List<(bool, GravixSingerCaptureSource)> nativeCalls;
  late bool nativeOk;
  late GravixSingerModeController c;
  late _FakeMusic music;

  setUp(() {
    w = _Wire();
    micUp = true;
    nativeCalls = [];
    nativeOk = true;
    c = GravixSingerModeController(
      mic: () => micUp ? _FakeMic(w) : null,
      music: () => music,
      native: (on, source) async {
        nativeCalls.add((on, source));
        return nativeOk;
      },
      defaults: () => (processing: _talk, dtx: true, bitrate: 64000),
    );
    music = _FakeMusic(w, () => c.active);
  });

  test(
    'on: processing off (AEC off by default), DTX off by one republish at 96 k, native MIC; off restores it all',
    () async {
      final s = await c.set(true);
      expect(s.on, isTrue);
      expect(s.republished, isTrue);
      expect(w.processing.noiseSuppression, isFalse);
      expect(w.processing.autoGainControl, isFalse);
      expect(w.processing.highPassFilter, isFalse);
      expect(w.processing.echoCancellation, isFalse);
      expect(w.dtx, isFalse);
      expect(w.bitrate, 96000);
      expect(w.republishes, 1);
      expect(nativeCalls, [(true, GravixSingerCaptureSource.mic)]);
      expect(c.dtxOff, isTrue);
      expect(c.maxBitrate, 96000);

      final off = await c.set(false);
      expect(off.on, isFalse);
      expect(w.processing.noiseSuppression, isTrue);
      expect(w.processing.echoCancellation, isTrue);
      expect(w.dtx, isTrue);
      expect(w.bitrate, 64000);
      expect(w.republishes, 2);
      expect(nativeCalls.last, (false, GravixSingerCaptureSource.keep));
      expect(c.active, isFalse);
    },
  );

  test('disableDtx false: no republish, bitrate on the sender; echoCancellation kept when asked', () async {
    final s = await c.set(
      true,
      const GravixSingerOptions(disableDtx: false, echoCancellation: true, maxBitrate: 128000),
    );
    expect(s.republished, isFalse);
    expect(s.bitrateApplied, isTrue);
    expect(w.dtx, isTrue);
    expect(w.bitrate, 128000);
    expect(w.processing.echoCancellation, isTrue);
    expect(w.processing.noiseSuppression, isFalse);
    await c.set(false);
    expect(w.bitrate, 64000);
    expect(w.republishes, 0);
  });

  test('music then singer then music stop then singer off: one owner, original profile back', () async {
    music.start(); // relaxed, DTX off (1 republish), 96 k
    expect(w.republishes, 1);
    await c.set(true);
    // DTX already off: no second republish; singer processing on top
    expect(w.republishes, 1);
    expect(w.processing.echoCancellation, isFalse);
    music.stop(); // handed over: restores nothing
    expect(w.dtx, isFalse);
    expect(w.processing.echoCancellation, isFalse);
    expect(w.bitrate, 96000);
    expect(w.republishes, 1);
    await c.set(false);
    expect(w.processing, _talk);
    expect(w.dtx, isTrue);
    expect(w.bitrate, 64000);
    expect(w.republishes, 2);
  });

  test('singer then music then singer off then music stop: music restores the original profile', () async {
    await c.set(true); // 1 republish
    music.start(); // held: changes nothing
    expect(w.republishes, 1);
    expect(w.processing.echoCancellation, isFalse);
    await c.set(false); // music retakes: relaxed (AEC back), DTX stays off, 96 k
    expect(w.republishes, 1);
    expect(w.processing.echoCancellation, isTrue);
    expect(w.processing.noiseSuppression, isFalse);
    expect(w.dtx, isFalse);
    expect(w.bitrate, 96000);
    music.stop();
    expect(w.processing, _talk);
    expect(w.dtx, isTrue);
    expect(w.bitrate, 64000);
    expect(w.republishes, 2);
  });

  test('music then singer then singer off then music stop', () async {
    music.start();
    await c.set(true);
    await c.set(false);
    expect(w.processing.noiseSuppression, isFalse); // music relaxed again
    expect(w.processing.echoCancellation, isTrue);
    expect(w.dtx, isFalse);
    music.stop();
    expect(w.processing, _talk);
    expect(w.dtx, isTrue);
    expect(w.bitrate, 64000);
    expect(w.republishes, 2);
  });

  test('no microphone yet: native now, the rest when it is published', () async {
    micUp = false;
    final s = await c.set(true);
    expect(s.on, isTrue);
    expect(s.micPublished, isFalse);
    expect(s.notes, isNotEmpty);
    expect(nativeCalls, [(true, GravixSingerCaptureSource.mic)]);
    micUp = true;
    await c.onMicPublished();
    expect(w.processing.noiseSuppression, isFalse);
    expect(w.dtx, isFalse);
    await c.set(false);
    expect(w.processing, _talk);
    expect(w.dtx, isTrue);
  });

  test('a new microphone while on (reconnect) gets the singer profile again', () async {
    await c.set(true);
    w.processing = _talk; // a rejoin created the track with the room defaults
    w.bitrate = 96000; // published with singer-mode publish options
    w.dtx = false;
    final before = w.republishes;
    await c.onMicPublished();
    expect(w.processing.noiseSuppression, isFalse);
    expect(w.republishes, before);
  });

  test('failures are reported, not thrown; native unavailable (iOS) noted', () async {
    nativeOk = false;
    w.failRepublish = true;
    final s = await c.set(true);
    expect(s.on, isTrue);
    expect(s.nativeApplied, isFalse);
    expect(s.republished, isFalse);
    expect(s.notes.join(' '), contains('DTX'));
    expect(s.notes.join(' '), contains('native'));
    expect(w.bitrate, 96000); // the sender still takes the rate
  });

  test('calls are serialised: the last one wins', () async {
    final a = c.set(true);
    final b = c.set(false);
    final d = c.set(true, const GravixSingerOptions(captureSource: GravixSingerCaptureSource.unprocessed));
    await Future.wait([a, b, d]);
    expect(c.active, isTrue);
    expect(c.options!.captureSource, GravixSingerCaptureSource.unprocessed);
    expect(nativeCalls.last, (true, GravixSingerCaptureSource.unprocessed));
  });

  test('publish options follow singer mode', () {
    final o = GravixRoomService.audioPublishOptionsFor(red: false, dtx: false, maxBitrate: 96000);
    expect(o.dtx, isFalse);
    expect(o.encoding?.maxBitrate, 96000);
    expect(GravixRoomService.audioPublishOptionsFor(red: false).encoding?.maxBitrate, 64000);
  });
}

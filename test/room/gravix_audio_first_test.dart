// Parity port of the React SDK's audio-first mode (test/audioFirst.test.ts), 2026-09-27.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/room/gravix_audio_first.dart';

const s = 1000;

// Sender readings from the field (server run log 2026-09-25, SEND_STATS).
final field = <String, List<AudioFirstSample>>{
  '4g-avg': const [
    AudioFirstSample(availKbps: 1290, rttMs: 107),
    AudioFirstSample(availKbps: 1290, rttMs: 75),
    AudioFirstSample(availKbps: 1290, rttMs: 119),
  ],
  '3g-poor': const [
    AudioFirstSample(availKbps: 471, rttMs: 248),
    AudioFirstSample(availKbps: 568, rttMs: 165),
    AudioFirstSample(rttMs: 229),
    AudioFirstSample(availKbps: 1184, rttMs: 236),
  ],
  'mobile-bad': const [
    AudioFirstSample(availKbps: 393, rttMs: 373),
    AudioFirstSample(availKbps: 144, rttMs: 269),
    AudioFirstSample(availKbps: 99, rttMs: 313),
    AudioFirstSample(availKbps: 129, rttMs: 304),
    AudioFirstSample(availKbps: 156, rttMs: 371),
  ],
  '2g': const [
    AudioFirstSample(availKbps: 49, rttMs: 5955),
    AudioFirstSample(availKbps: 30, rttMs: 6337),
    AudioFirstSample(rttMs: 7852),
    AudioFirstSample(),
    AudioFirstSample(availKbps: 33, rttMs: 6235),
    AudioFirstSample(availKbps: 30, rttMs: 10160),
  ],
};

class Clock {
  int t = 0;
}

List<String> feed(AudioFirstPolicy p, List<AudioFirstSample> samples, Clock c, int forMs) {
  final out = <String>[];
  final end = c.t + forMs;
  for (var i = 0; c.t <= end; c.t += 2 * s, i++) {
    final d = p.step(samples[i % samples.length], c.t);
    if (d != null) out.add(d.name);
  }
  return out;
}

class FakeOps implements AudioFirstOps {
  AudioFirstSample next = const AudioFirstSample();
  int engaged = 0, restored = 0, droppedVideo = 0;
  @override
  Future<AudioFirstSample> sample() async => next;
  @override
  Future<void> engage(int audioMaxBitrate, {required bool dropRemoteVideo}) async {
    engaged++;
    if (dropRemoteVideo) droppedVideo++;
  }

  @override
  Future<void> restore() async => restored++;
}

void main() {
  group('AudioFirstPolicy', () {
    test('never engages on a network that works today (4G, 3G, bad mobile), over 10 minutes', () {
      for (final net in ['4g-avg', '3g-poor', 'mobile-bad']) {
        final p = AudioFirstPolicy();
        expect(feed(p, field[net]!, Clock(), 600 * s), isEmpty, reason: net);
        expect(p.active, isFalse);
      }
    });

    test('engages on the measured 2G readings after the engage window', () {
      final p = AudioFirstPolicy();
      final c = Clock();
      expect(feed(p, field['2g']!, c, kAudioFirstEngageAfterMs - 2 * s), isEmpty);
      expect(feed(p, field['2g']!, c, 4 * s), ['engage']);
    });

    test('an empty reading neither extends nor breaks a streak', () {
      final p = AudioFirstPolicy();
      expect(p.step(const AudioFirstSample(rttMs: 3000), 0), isNull);
      expect(p.step(const AudioFirstSample(), 2 * s), isNull);
      expect(p.step(const AudioFirstSample(rttMs: 3000), kAudioFirstEngageAfterMs), AudioFirstDecision.engage);
    });

    test('a single normal reading breaks the overload streak', () {
      final p = AudioFirstPolicy();
      p.step(const AudioFirstSample(rttMs: 3000), 0);
      p.step(const AudioFirstSample(rttMs: 200, availKbps: 300), 5 * s);
      expect(p.step(const AudioFirstSample(rttMs: 3000), 6 * s), isNull);
      expect(p.step(const AudioFirstSample(rttMs: 3000), 12 * s), AudioFirstDecision.engage);
    });

    test('a low estimate with a normal RTT never engages', () {
      expect(
        feed(
          AudioFirstPolicy(),
          const [AudioFirstSample(availKbps: 42, rttMs: 366), AudioFirstSample(availKbps: 30)],
          Clock(),
          600 * s,
        ),
        isEmpty,
      );
    });

    test('restores only after a long healthy streak and never inside the switch gap', () {
      final p = AudioFirstPolicy();
      final c = Clock();
      feed(p, field['2g']!, c, kAudioFirstEngageAfterMs + 2 * s);
      expect(p.active, isTrue);
      expect(
        feed(p, const [AudioFirstSample(availKbps: 800, rttMs: 150)], c, kAudioFirstMinSwitchGapMs - 4 * s),
        isEmpty,
      );
      expect(feed(p, const [AudioFirstSample(availKbps: 800, rttMs: 150)], c, 8 * s), ['restore']);
    });

    test('stays engaged on the link that engaged it; restores on a 4G-class RTT with a stuck estimate', () {
      final p = AudioFirstPolicy();
      final c = Clock();
      feed(p, field['2g']!, c, kAudioFirstEngageAfterMs + 2 * s);
      expect(
        feed(
          p,
          const [AudioFirstSample(availKbps: 5, rttMs: 546), AudioFirstSample(availKbps: 5, rttMs: 666)],
          c,
          600 * s,
        ),
        isEmpty,
      );
      expect(
        feed(
          p,
          const [AudioFirstSample(availKbps: 5, rttMs: 107)],
          c,
          kAudioFirstMinSwitchGapMs + kAudioFirstRestoreAfterMs,
        ),
        ['restore'],
      );
    });

    test('a restore that does not hold doubles the next wait, up to the cap', () {
      final p = AudioFirstPolicy();
      final c = Clock();
      feed(p, const [AudioFirstSample(rttMs: 4000)], c, kAudioFirstEngageAfterMs + 2 * s);
      feed(p, const [AudioFirstSample(rttMs: 100)], c, kAudioFirstMinSwitchGapMs + kAudioFirstRestoreAfterMs);
      expect(p.active, isFalse);
      expect(feed(p, const [AudioFirstSample(rttMs: 4000)], c, kAudioFirstEngageAfterMs + 2 * s), ['engage']);
      expect(p.restoreHold, 2 * kAudioFirstMinSwitchGapMs);
      for (var i = 0; i < 12; i++) {
        feed(p, const [AudioFirstSample(rttMs: 100)], c, p.restoreHold + kAudioFirstRestoreAfterMs + 2 * s);
        feed(p, const [AudioFirstSample(rttMs: 4000)], c, kAudioFirstEngageAfterMs + 2 * s);
      }
      expect(p.restoreHold, kAudioFirstMaxRestoreHoldMs);
    });
  });

  group('audioFirstSampleFromStats', () {
    test('reads RTT and estimate from the selected pair, else the audio receiver-report RTT', () {
      final a = audioFirstSampleFromStats(const [
        {
          'type': 'candidate-pair',
          'nominated': true,
          'state': 'succeeded',
          'currentRoundTripTime': 0.25,
          'availableOutgoingBitrate': 800000,
        },
        {'type': 'remote-inbound-rtp', 'kind': 'audio', 'roundTripTime': 0.9},
      ]);
      expect(a.rttMs, 250);
      expect(a.availKbps, 800);
      final b = audioFirstSampleFromStats(const [
        {'type': 'remote-inbound-rtp', 'kind': 'audio', 'roundTripTime': 0.9},
      ]);
      expect(b.rttMs, 900);
      expect(audioFirstSampleFromStats(const []).rttMs, isNull);
    });
  });

  group('GravixAudioFirst', () {
    test('engages once, re-asserts while engaged, restores exactly once, reports both', () async {
      final ops = FakeOps();
      var now = 0;
      final changes = <bool>[];
      final af = GravixAudioFirst(ops, now: () => now, onChange: (on, _) => changes.add(on));
      ops.next = const AudioFirstSample(rttMs: 5000);
      for (; now <= kAudioFirstEngageAfterMs + 2 * s; now += 2 * s) {
        await af.check();
      }
      expect(af.active, isTrue);
      expect(changes, [true]);
      ops.next = const AudioFirstSample(rttMs: 100);
      for (
        ;
        now <= kAudioFirstEngageAfterMs + kAudioFirstMinSwitchGapMs + kAudioFirstRestoreAfterMs + 4 * s;
        now += 2 * s
      ) {
        await af.check();
      }
      expect(af.active, isFalse);
      expect(changes, [true, false]);
      expect(ops.restored, 1);
      expect(ops.engaged, greaterThan(1), reason: 're-asserted on every sample while engaged');
    });

    test('a working network never touches the room', () async {
      final ops = FakeOps()..next = const AudioFirstSample(rttMs: 120, availKbps: 1200);
      var now = 0;
      final af = GravixAudioFirst(ops, now: () => now);
      for (; now < 600 * s; now += 2 * s) {
        await af.check();
      }
      expect(ops.engaged + ops.restored, 0);
    });
  });
}

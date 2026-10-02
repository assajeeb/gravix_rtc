// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.
//
// Audio-first mode for very slow links (parity with the React SDK's
// src/core/room/gravix/audioFirst.ts, 0.3.0; ported 2026-09-27).
//
// When the round-trip time stays above [kAudioFirstEngageRttMs] for
// [kAudioFirstEngageAfterMs] (a queue in front of the link: 2G/EDGE), it does what
// Agora's audio-only fallback does, with no renegotiation:
//  - turns the camera off for others (muted, not stopped: nothing to re-acquire);
//  - caps the microphone sender at [kAudioFirstAudioMaxBitrate];
//  - stops receiving remote video (a 2G downlink is as slow as its uplink).
// It restores exactly what it changed once the link has a 4G-class RTT for
// [kAudioFirstRestoreAfterMs], and never sooner than a restore hold that doubles
// after every restore that did not hold. Opt-in: nothing runs until start().
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';

import '../rtc_core/src/core/room.dart';
import '../rtc_core/src/publication/remote.dart';
import '../rtc_core/src/track/local/local.dart';
import '../rtc_core/src/types/other.dart';

const kAudioFirstPollMs = 2000;
const kAudioFirstEngageRttMs = 1500;
const kAudioFirstEngageAfterMs = 6000;
const kAudioFirstRestoreAvailKbps = 400;
const kAudioFirstRestoreRttMs = 600;
const kAudioFirstRestoreLowRttMs = 300;
const kAudioFirstRestoreAfterMs = 30000;
const kAudioFirstMinSwitchGapMs = 60000;
const kAudioFirstMaxRestoreHoldMs = 16 * 60000;
const kAudioFirstAudioMaxBitrate = 16000;

/// One reading of the sender's view of its link; either value may be missing.
class AudioFirstSample {
  const AudioFirstSample({this.rttMs, this.availKbps});
  final double? rttMs;
  final double? availKbps;
}

enum AudioFirstDecision { engage, restore }

/// The decision as a pure state machine over (sample, time): testable exactly.
class AudioFirstPolicy {
  bool _active = false;
  int? _overloadedSince;
  int? _healthySince;
  int _lastSwitch = -1 << 52;
  int _restoreHold = kAudioFirstMinSwitchGapMs;
  bool _restoredOnce = false;

  bool get active => _active;

  /// Current wait before a restore is allowed (grows after restores that failed).
  int get restoreHold => _restoreHold;

  AudioFirstDecision? step(AudioFirstSample s, int nowMs) {
    final rtt = s.rttMs, avail = s.availKbps;
    if (rtt == null && avail == null) return null; // no reading: neither extends nor breaks
    if (rtt == null && _overloadedSince != null) return null; // an estimate says nothing about the queue
    final overloaded = rtt != null && rtt > kAudioFirstEngageRttMs;
    final healthy =
        rtt != null &&
        (rtt < kAudioFirstRestoreLowRttMs ||
            (avail != null && rtt < kAudioFirstRestoreRttMs && avail >= kAudioFirstRestoreAvailKbps));
    _overloadedSince = overloaded ? (_overloadedSince ?? nowMs) : null;
    _healthySince = healthy ? (_healthySince ?? nowMs) : null;

    if (!_active && _overloadedSince != null && nowMs - _overloadedSince! >= kAudioFirstEngageAfterMs) {
      if (_restoredOnce) {
        _restoreHold = (_restoreHold * 2).clamp(0, kAudioFirstMaxRestoreHoldMs);
      }
      _active = true;
      _lastSwitch = nowMs;
      _healthySince = null;
      return AudioFirstDecision.engage;
    }
    if (_active &&
        nowMs - _lastSwitch >= _restoreHold &&
        _healthySince != null &&
        nowMs - _healthySince! >= kAudioFirstRestoreAfterMs) {
      _active = false;
      _lastSwitch = nowMs;
      _restoredOnce = true;
      _overloadedSince = null;
      return AudioFirstDecision.restore;
    }
    return null;
  }
}

/// Reads one sample from a publisher's stats (each entry: the report's values plus
/// its `type`): the selected candidate pair, else the audio receiver-report RTT.
AudioFirstSample audioFirstSampleFromStats(List<Map<String, dynamic>> reports) {
  double? rtt, avail, audioRtt;
  for (final r in reports) {
    final type = r['type'];
    if (type == 'candidate-pair' && r['nominated'] == true && r['state'] == 'succeeded') {
      final cur = r['currentRoundTripTime'];
      final out = r['availableOutgoingBitrate'];
      if (cur is num) rtt = cur * 1000;
      if (out is num) avail = out / 1000;
    } else if (type == 'remote-inbound-rtp' && r['kind'] == 'audio' && r['roundTripTime'] is num) {
      audioRtt = (r['roundTripTime'] as num) * 1000;
    }
  }
  return AudioFirstSample(rttMs: rtt ?? audioRtt, availKbps: avail);
}

/// What audio-first does to a room; the default binds to a [Room].
abstract class AudioFirstOps {
  Future<AudioFirstSample> sample();

  /// Idempotent: called on every sample while engaged, so a camera or a remote
  /// video that appears after engaging is handled too.
  Future<void> engage(int audioMaxBitrate, {required bool dropRemoteVideo});

  /// Undo exactly what [engage] changed.
  Future<void> restore();
}

class RoomAudioFirstOps implements AudioFirstOps {
  RoomAudioFirstOps(this.room);
  final Room room;
  final _mutedCameras = <LocalTrack>{};
  final _cappedMics = <rtc.RTCRtpSender, int?>{};
  final _droppedVideo = <RemoteTrackPublication>{};

  @override
  Future<AudioFirstSample> sample() async {
    final pc = room.engine.publisher?.pc;
    if (pc == null) return const AudioFirstSample();
    final stats = await pc.getStats();
    return audioFirstSampleFromStats([
      for (final r in stats) {...r.values.map((k, v) => MapEntry(k.toString(), v)), 'type': r.type},
    ]);
  }

  @override
  Future<void> engage(int audioMaxBitrate, {required bool dropRemoteVideo}) async {
    final local = room.localParticipant;
    if (local != null) {
      for (final pub in local.trackPublications.values) {
        final track = pub.track;
        if (track == null) continue;
        try {
          if (pub.source == TrackSource.camera) {
            if (track.muted) continue; // off already (the user's choice or ours)
            await track.mute(stopOnMute: false);
            _mutedCameras.add(track);
          } else if (pub.source == TrackSource.microphone) {
            await capMic(track, audioMaxBitrate);
          }
        } catch (_) {
          // one track failing must not keep the others at full rate
        }
      }
    }
    if (dropRemoteVideo) {
      for (final p in room.remoteParticipants.values) {
        for (final pub in p.videoTrackPublications) {
          if (!pub.subscribed) continue;
          try {
            await pub.unsubscribe();
            _droppedVideo.add(pub);
          } catch (_) {}
        }
      }
    }
  }

  /// Caps one microphone sender, remembering its rate for [restore].
  ///
  /// A muted mic is skipped: it is already capped far below (MicUplinkPause)
  /// and its unmute restores the publish rate, so recording that muted cap as
  /// "before" would make [restore] put the UNMUTED mic back at the muted rate.
  @visibleForTesting
  Future<void> capMic(LocalTrack track, int audioMaxBitrate) async {
    if (track.muted) return;
    final sender = track.sender;
    if (sender == null || _cappedMics.containsKey(sender)) return;
    final params = sender.parameters;
    final enc = params.encodings;
    if (enc == null || enc.isEmpty) return;
    final before = enc.first.maxBitrate;
    enc.first.maxBitrate = audioMaxBitrate;
    await sender.setParameters(params);
    _cappedMics[sender] = before;
  }

  @override
  Future<void> restore() async {
    for (final t in _mutedCameras) {
      try {
        if (t.muted) await t.unmute(stopOnMute: false); // only if still off: the user may have toggled it
      } catch (_) {}
    }
    _mutedCameras.clear();
    for (final e in _cappedMics.entries) {
      try {
        final params = e.key.parameters;
        final enc = params.encodings;
        if (enc != null && enc.isNotEmpty) {
          enc.first.maxBitrate = e.value;
          await e.key.setParameters(params);
        }
      } catch (_) {}
    }
    _cappedMics.clear();
    for (final pub in _droppedVideo) {
      try {
        await pub.subscribe();
      } catch (_) {}
    }
    _droppedVideo.clear();
  }
}

/// Binds [AudioFirstPolicy] to a room.
///
///     final audioFirst = GravixAudioFirst.forRoom(room, onChange: (on, _) => showBanner(on))..start();
///     // on leave: await audioFirst.stopAndRestore();
class GravixAudioFirst {
  GravixAudioFirst(
    this._ops, {
    this.dropRemoteVideo = true,
    this.audioMaxBitrate = kAudioFirstAudioMaxBitrate,
    this.onChange,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  factory GravixAudioFirst.forRoom(
    Room room, {
    bool dropRemoteVideo = true,
    void Function(bool active, AudioFirstSample sample)? onChange,
  }) => GravixAudioFirst(RoomAudioFirstOps(room), dropRemoteVideo: dropRemoteVideo, onChange: onChange);

  final AudioFirstOps _ops;
  final bool dropRemoteVideo;
  final int audioMaxBitrate;
  final void Function(bool active, AudioFirstSample sample)? onChange;
  final int Function() _now;
  AudioFirstPolicy _policy = AudioFirstPolicy();
  Timer? _timer;
  bool _busy = false;

  /// True while engaged: bind a "video paused: weak connection" banner to it.
  bool get active => _policy.active;

  void start() {
    stop();
    _timer = Timer.periodic(const Duration(milliseconds: kAudioFirstPollMs), (_) => check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> stopAndRestore() async {
    stop();
    if (_policy.active) {
      await _ops.restore();
      _policy = AudioFirstPolicy();
      onChange?.call(false, const AudioFirstSample());
    }
  }

  /// One sample now; [start] calls this on a timer.
  Future<void> check() async {
    if (_busy) return; // a slow getStats must not stack polls
    _busy = true;
    try {
      AudioFirstSample sample;
      try {
        sample = await _ops.sample();
      } catch (_) {
        sample = const AudioFirstSample();
      }
      final d = _policy.step(sample, _now());
      if (d == AudioFirstDecision.restore) {
        await _ops.restore();
      } else if (_policy.active) {
        await _ops.engage(audioMaxBitrate, dropRemoteVideo: dropRemoteVideo);
      }
      if (d != null) onChange?.call(d == AudioFirstDecision.engage, sample);
    } finally {
      _busy = false;
    }
  }
}

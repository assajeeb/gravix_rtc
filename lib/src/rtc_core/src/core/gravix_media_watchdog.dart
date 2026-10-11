// Copyright (c) 2026 Gravity Compile. Apache 2.0.
//
// R1 + S4 (0.4.15): client-side detection of a subscribed video that stopped.
//
// Field 2026-10-09 (Pakhi viewer on doh1): media stopped at 03:49:52, ICE noticed
// it at 03:49:59 (7 s), the resume came at 03:50:01, and NO new video reached the
// working subscriber connection after it until the full rejoin at 03:50:11 (the
// server's downtrack was dead, report 2c). ~22 s of black. A viewer whose resume
// succeeds in that state stays black for good: nothing ever re-pulls.
//
//  - R1 (early stall): every subscribed video that should be flowing received no
//    packet for `stallNoPacketsFor` (~2 s) and no subscribed audio received any
//    either -> a resume at once instead of waiting ~7 s for ICE. At most once per
//    `stallMinInterval`, and not again until media flowed once (a source that
//    just stopped sending is not resumed over and over).
//  - S4 (no video after a resume): inside `noVideoWindow` after a resume, a
//    subscribed video that should be flowing decoded no new frame for
//    `noVideoFor` -> a full rejoin. At most once per `noVideoMinInterval`.
//
// Inputs are the receiver stats the remote tracks already poll every 2 s
// (VideoReceiverStatsEvent / AudioReceiverStatsEvent): no new poll, no wire cost.
// "Should be flowing" (eligible) is decided by the caller: subscribed, enabled,
// unmuted, not paused by the server (an unreported state counts as flowing), the
// publisher still publishing it.
import '../gravix_recovery_options.dart';

enum GravixStallAction { none, resume, rejoin }

class _TrackState {
  final bool video;
  num? packets;
  num? frames;
  DateTime packetsChangedAt;
  DateTime framesChangedAt;
  bool eligible = false;
  DateTime at;

  _TrackState.init(this.video, DateTime now) : packetsChangedAt = now, framesChangedAt = now, at = now;
}

class GravixVideoStallWatch {
  GravixVideoStallWatch({required this.options, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  GravixRecoveryOptions options;
  final DateTime Function() _clock;
  final _tracks = <String, _TrackState>{};

  DateTime? _resumedAt;
  DateTime? _lastStallResume;
  DateTime? _lastRejoin;

  /// R1 fired and media has not flowed since: no second R1 until it does.
  bool _stallResumePending = false;

  bool get enabled => options.earlyStallDetection || options.noVideoWatchdog;

  /// The session resumed: S4's window starts; every video's frame clock restarts.
  void noteResumed() {
    final now = _clock();
    _resumedAt = now;
    for (final t in _tracks.values) {
      t.framesChangedAt = now;
      t.packetsChangedAt = now;
    }
  }

  /// A full rejoin (or a disconnect) replaced every receiver.
  void reset() {
    _tracks.clear();
    _resumedAt = null;
    _stallResumePending = false;
  }

  void forget(String trackSid) => _tracks.remove(trackSid);

  /// One stats sample of a subscribed track. Returns what to do now.
  GravixStallAction sample(
    String trackSid, {
    required bool video,
    required bool eligible,
    num? packetsReceived,
    num? framesDecoded,
  }) {
    final now = _clock();
    var t = _tracks[trackSid];
    if (t == null) {
      t = _TrackState.init(video, now)
        ..packets = packetsReceived
        ..frames = framesDecoded
        ..eligible = eligible;
      _tracks[trackSid] = t;
      return GravixStallAction.none;
    }
    t.at = now;
    if (!eligible || !t.eligible) {
      // not expected to flow (or just became expected): restart its clocks
      t
        ..eligible = eligible
        ..packets = packetsReceived
        ..frames = framesDecoded
        ..packetsChangedAt = now
        ..framesChangedAt = now;
      return GravixStallAction.none;
    }
    if (packetsReceived != null && packetsReceived != t.packets) {
      t.packets = packetsReceived;
      t.packetsChangedAt = now;
      _stallResumePending = false; // media flows again
    }
    if (framesDecoded != null && framesDecoded != t.frames) {
      t.frames = framesDecoded;
      t.framesChangedAt = now;
    }
    if (!video) return GravixStallAction.none;

    // S4 first: inside the window after a resume it is the one that decides
    final resumedAt = _resumedAt;
    final inWindow = resumedAt != null && now.difference(resumedAt) <= options.noVideoWindow;
    if (options.noVideoWatchdog && inWindow) {
      final sinceFrame = now.difference(t.framesChangedAt);
      final canRejoin = _lastRejoin == null || now.difference(_lastRejoin!) >= options.noVideoMinInterval;
      if (sinceFrame >= options.noVideoFor && canRejoin) {
        _lastRejoin = now;
        _resumedAt = null;
        return GravixStallAction.rejoin;
      }
      return GravixStallAction.none;
    }

    if (options.earlyStallDetection && !_stallResumePending) {
      final canResume = _lastStallResume == null || now.difference(_lastStallResume!) >= options.stallMinInterval;
      if (canResume && _pathStalled(now)) {
        _lastStallResume = now;
        _stallResumePending = true;
        return GravixStallAction.resume;
      }
    }
    return GravixStallAction.none;
  }

  /// Every eligible video stalled for stallNoPacketsFor, and no eligible track
  /// (audio included) received a packet in that time: the path, not one source.
  bool _pathStalled(DateTime now) {
    var videos = 0;
    for (final t in _tracks.values) {
      if (!t.eligible) continue;
      final quiet = now.difference(t.packetsChangedAt) >= options.stallNoPacketsFor;
      if (!quiet) return false;
      if (t.video) videos++;
    }
    return videos > 0;
  }
}

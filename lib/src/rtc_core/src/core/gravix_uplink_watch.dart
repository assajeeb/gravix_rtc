// Copyright (c) 2026 Gravity Compile. Apache 2.0.
//
// uplinkFeedbackStallFor (2026-10-11, UDP-BLACK): client-side detection of an
// uplink the SFU no longer answers.
//
// Emulator 2026-10-11 r402 / r407 (host on the public fleet, rooted API 34):
// UDP to the SFU died mid-call and libwebrtc moved the host's publisher PC to
// ICE-TCP by itself, without an ICE restart. The SFU is the CONTROLLED ICE side
// of that PC and, as a full agent, ignored the client's nomination of the
// lower-priority TCP pair: it kept writing its RTCP (receiver reports, PLI,
// bandwidth feedback) into the dead UDP pair. The host's media still reached
// the SFU, but nothing came back ("No RTCP RR received" in libwebrtc 0.6-1 s
// after the switch): no PLI -> no keyframe -> viewers got video they could not
// decode (black, audio fine) for 15.8 s / 32.5 s, until the SFU's own ICE timed
// out and asked for a resume. A resume's ICE restart makes the SFU select again
// (r403-r405: video back 0.6 s after it).
//
// Rule: every published stream (audio track, video layer) that should flow
// reports `packetsSent` and the last receiver report the SFU sent about it
// (`remote-inbound-rtp`, [SenderStats.remoteReportMarker]) every 2 s. When a
// stream sent at least [minPacketsSent] packets since its last new report,
// that report is older than stallFor, and no other stream got a new report in
// that time either (the path, not one stream), the caller resumes. At most once
// per [minInterval]; [reset] after a resume or rejoin restarts every clock.
// A stream that never got a report has nothing to compare and never triggers.
//
// Inputs are the sender stats the local tracks already poll (no new poll, no
// wire cost).

class _UplinkStream {
  _UplinkStream(this.feedbackAt, this.packetsAtFeedback, this.feedback);
  DateTime feedbackAt;
  num? packetsAtFeedback;
  String? feedback;
}

class GravixUplinkFeedbackWatch {
  GravixUplinkFeedbackWatch({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// Packets a stream must have sent since its last report: a muted track or a
  /// paused simulcast layer sends (almost) nothing and is never "unanswered".
  static const minPacketsSent = 20;

  /// At most one resume per this long.
  static const minInterval = Duration(seconds: 20);

  final DateTime Function() _clock;
  final _streams = <String, _UplinkStream>{};
  DateTime? _lastFired;

  /// A resume or rejoin happened: new connections, every clock restarts.
  void reset() => _streams.clear();

  void forget(String key) => _streams.remove(key);

  /// One sender-stats sample of a published stream ([key]: track sid, plus the
  /// layer for video). True = resume now.
  bool sample(
    String key, {
    required bool eligible,
    required num? packetsSent,
    required String? feedback,
    required Duration stallFor,
  }) {
    if (stallFor <= Duration.zero) return false;
    final now = _clock();
    final s = _streams[key];
    if (s == null || !eligible || packetsSent == null || feedback == null || feedback != s.feedback) {
      // first sample, not expected to flow, no report yet, or a new report: (re)start its clock
      _streams[key] = _UplinkStream(now, packetsSent, feedback);
      return false;
    }
    if (now.difference(s.feedbackAt) < stallFor) return false;
    if (packetsSent - (s.packetsAtFeedback ?? packetsSent) < minPacketsSent) return false;
    // the path, not one stream: no other stream got a new report within stallFor either
    for (final e in _streams.entries) {
      if (e.key == key || e.value.feedback == null) continue;
      if (now.difference(e.value.feedbackAt) < stallFor) return false;
    }
    final last = _lastFired;
    if (last != null && now.difference(last) < minInterval) return false;
    _lastFired = now;
    for (final e in _streams.values) {
      e.feedbackAt = now; // the resume's restart gets a fresh stallFor
    }
    s.packetsAtFeedback = packetsSent;
    return true;
  }
}

// The connection-quality label an app should SHOW: the server's score, made worse
// when the device's own stats are clearly bad (0.4.7).
//
// Field 2026-10-02 (Saudi tester, doh1, Gravix Tester 0.3.7): the label said
// "excellent" for a whole minute while the tester's own stats read 25-43 %
// downlink loss, 67 % uplink loss and 3.7-7.9 s RTT, and the peer connection
// died 20 s later (the SFU closed the participant, PEER_CONNECTION_DISCONNECTED).
// `Participant.connectionQuality` is only ever what the SFU last sent in a
// ConnectionQualityUpdate. The SFU's scorer does mark a window without packets
// POOR/LOST, but (a) it skips scoring entirely while the track is muted or just
// unmuted (pkg/sfu/connectionquality/scorer.go: a muted mic stays EXCELLENT), and
// (b) its updates travel over the signalling WebSocket -- the same broken path:
// while the link is that bad no update arrives, and the client keeps the last
// one. Nothing in the server scoring is wrong for the data it has; the client
// is the one with the evidence, so the override lives here.
//
// This never changes `Participant.connectionQuality` itself: the audio-only
// fallback (large_room) and the room service's poor-network watch gate on the
// server's value, and an override there would change their behaviour. Apps
// call [gravixEffectiveQuality] for the label they display (and log both).
import '../rtc_core/gravix_client.dart' show ConnectionQuality;

/// Where local stats move the label down. A value is "at or above" a step.
///
/// Loss is the worse of uplink and downlink loss over the app's stats window (%);
/// RTT is the round trip the app measured (ms). Defaults: E-model-ish steps for
/// interactive audio -- 3 % loss / 400 ms is audible (good, not excellent), 10 % /
/// 1 s makes conversation hard (poor), 30 % / 3 s is effectively no call (lost).
class GravixQualityThresholds {
  const GravixQualityThresholds({
    this.goodLossPct = 3,
    this.poorLossPct = 10,
    this.lostLossPct = 30,
    this.goodRttMs = 400,
    this.poorRttMs = 1000,
    this.lostRttMs = 3000,
  });

  final double goodLossPct, poorLossPct, lostLossPct;
  final int goodRttMs, poorRttMs, lostRttMs;
}

/// Ordered worst -> best; `unknown` is "no evidence", not a rank.
int _rank(ConnectionQuality q) => switch (q) {
      ConnectionQuality.lost => 0,
      ConnectionQuality.poor => 1,
      ConnectionQuality.good => 2,
      ConnectionQuality.excellent => 3,
      ConnectionQuality.unknown => 4,
    };

ConnectionQuality _worse(ConnectionQuality a, ConnectionQuality b) => _rank(a) <= _rank(b) ? a : b;

/// The label the device's own stats support, or null when they show nothing
/// wrong / nothing at all (no evidence: the server's value stands).
///
/// [reconnecting]: the SDK is resuming or restarting the connection right now;
/// the label is at best `poor` then (the server cannot reach the device).
ConnectionQuality? gravixLocalQuality({
  double? uplinkLossPct,
  double? downlinkLossPct,
  int? rttMs,
  bool reconnecting = false,
  GravixQualityThresholds thresholds = const GravixQualityThresholds(),
}) {
  final t = thresholds;
  double? loss;
  for (final v in [uplinkLossPct, downlinkLossPct]) {
    if (v != null && v.isFinite && (loss == null || v > loss)) loss = v;
  }
  final rtt = rttMs != null && rttMs > 0 ? rttMs : null;
  ConnectionQuality? q;
  if ((loss != null && loss >= t.lostLossPct) || (rtt != null && rtt >= t.lostRttMs)) {
    q = ConnectionQuality.lost;
  } else if ((loss != null && loss >= t.poorLossPct) || (rtt != null && rtt >= t.poorRttMs)) {
    q = ConnectionQuality.poor;
  } else if ((loss != null && loss >= t.goodLossPct) || (rtt != null && rtt >= t.goodRttMs)) {
    q = ConnectionQuality.good;
  }
  if (reconnecting) q = q == null ? ConnectionQuality.poor : _worse(q, ConnectionQuality.poor);
  return q;
}

/// The label to show: the worse of the server's [server] score and what the
/// device's own stats support ([gravixLocalQuality]). With no local evidence the
/// server's value is returned unchanged (including `unknown`).
ConnectionQuality gravixEffectiveQuality(
  ConnectionQuality server, {
  double? uplinkLossPct,
  double? downlinkLossPct,
  int? rttMs,
  bool reconnecting = false,
  GravixQualityThresholds thresholds = const GravixQualityThresholds(),
}) {
  final local = gravixLocalQuality(
    uplinkLossPct: uplinkLossPct,
    downlinkLossPct: downlinkLossPct,
    rttMs: rttMs,
    reconnecting: reconnecting,
    thresholds: thresholds,
  );
  if (local == null) return server;
  return _worse(server, local);
}

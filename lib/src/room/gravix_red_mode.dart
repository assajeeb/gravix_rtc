// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// RED (RFC 2198 redundant audio) for the published microphone: on, off, or on only
// once the uplink is actually losing packets.
//
// Trade-off. With RED every audio packet also carries the previous frame(s), so a
// lost packet is recovered from the next one instead of being concealed: on a
// lossy uplink (field 2026-09-29, a Kuwaiti cellular uplink losing ~15 %) speech
// stays intelligible where plain Opus breaks up. It costs upload bandwidth: field
// 2026-09-30 measured ~125 kbps audio upload with RED vs ~50 kbps without (the
// redundant copy roughly doubles the payload at the 64 kbps cap, plus headers). On
// a clean uplink that is bandwidth spent for nothing, and on a constrained one it
// competes with video. E2EE always turns RED off (the SFU cannot rewrite
// encrypted RED payloads for Opus-only subscribers).
//
//  - [GravixRedMode.on]   (default, 0.4.3 behaviour): RED from the first packet.
//  - [GravixRedMode.off]: plain Opus.
//  - [GravixRedMode.auto]: plain Opus; once the uplink loss stays at or above the
//    threshold for [GravixRedAuto.windows] consecutive stats windows (5 s each,
//    20 s in all: a Wi-Fi roam or a cell handover does not trigger it), the
//    microphone is republished with RED, once per call (no flapping back: a
//    republish is an audible gap of ~100-300 ms and a new track for everyone).
//    A round trip above [GravixRedAuto.maxRttMs] blocks it: that link's loss is
//    its own queue overflowing, and RED would double the bitrate into it. Same
//    policy as the JS SDK's `red: 'auto'`.

/// How the published microphone uses RED. See the file comment for the trade-off.
enum GravixRedMode { on, off, auto }

/// The auto mode's decision, fed with the mic's cumulative sender counters.
class GravixRedAuto {
  GravixRedAuto({
    this.thresholdPct = kGravixRedLossThresholdPct,
    this.windows = 4,
    this.minPackets = 50,
    this.maxRttMs = 1500,
  });

  /// Uplink loss (%) that counts as lossy.
  final double thresholdPct;

  /// Consecutive lossy windows before RED is switched on.
  final int windows;

  /// A window with fewer packets sent says nothing (muted, DTX, just started).
  final int minPackets;

  /// A lossy window with a round trip above this does not count (a bufferbloated
  /// link loses packets because it is full; RED would add to it).
  final int maxRttMs;

  num? _sent, _lost;
  int _lossy = 0;
  bool _fired = false;

  /// Loss of the last window, % (null: not enough packets / first sample).
  double? lastLossPct;

  bool get fired => _fired;

  /// [packetsSent]: outbound-rtp packetsSent; [packetsLost]: the remote-inbound
  /// packetsLost the SFU reports for this stream. Returns true exactly once: when
  /// RED should be switched on.
  bool feed(num? packetsSent, num? packetsLost, {double? rttMs}) {
    if (_fired || packetsSent == null || packetsLost == null) return false;
    final ps = _sent, pl = _lost;
    _sent = packetsSent;
    _lost = packetsLost;
    if (ps == null || pl == null) return false;
    final dSent = packetsSent - ps;
    final dLost = packetsLost - pl;
    if (dSent < minPackets || dLost < 0) {
      lastLossPct = null;
      return false;
    }
    final loss = 100.0 * dLost / (dSent + dLost);
    lastLossPct = loss;
    final congested = rttMs != null && rttMs > maxRttMs;
    _lossy = loss >= thresholdPct && !congested ? _lossy + 1 : 0;
    if (_lossy >= windows) {
      _fired = true;
      return true;
    }
    return false;
  }
}

/// Default loss threshold of [GravixRedMode.auto] (JS SDK: `redLossThresholdPct`).
const double kGravixRedLossThresholdPct = 3.0;

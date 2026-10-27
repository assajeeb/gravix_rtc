// Copyright 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

// GRAVIX (0.7.1, field crash 2026-10-27): per-track stats without the per-track
// getStats call.
//
// `RTCRtpSender.getStats()` / `RTCRtpReceiver.getStats()` reach flutter_webrtc's
// Android `getStatsForTrack`, which calls `PeerConnection.getSenders()` and
// `getReceivers()` on the platform thread. libwebrtc's Java wrapper DISPOSES its
// cached sender/receiver objects (and their tracks) on every such call. When a
// remote track arrives at the same moment, the plugin's `onAddTrack` runs on the
// signalling thread over those same objects, throws "RtpTransceiver has been
// disposed" / "MediaStreamTrack has been disposed", and the pending Java
// exception aborts the process (jvm.cc:81, SIGABRT). Measured on a Redmi Note 11:
// ~1 join in 20 in back-to-back joins, on 0.6.1 and 0.7.0 alike.
//
// `RTCPeerConnection.getStats()` (no track) touches none of those wrappers. This
// keeps from its answer what the per-track call returned: the track's RTP
// stream(s) plus every report they reference, transitively (codec, transport,
// candidate pair, candidates, remote-inbound/-outbound, media-source), which is
// the WebRTC stats selection algorithm.

/// The reports of [all] that belong to the track [trackId]: inbound-rtp whose
/// `trackIdentifier` is [trackId], outbound-rtp whose media-source has it, and
/// everything those reference. Empty when [trackId] has no RTP stream (yet).
List<rtc.StatsReport> gravixScopeStatsToTrack(List<rtc.StatsReport> all, String trackId) {
  if (trackId.isEmpty) return const [];
  final byId = <String, rtc.StatsReport>{for (final r in all) r.id: r};
  final sourceIds = <String>{
    for (final r in all)
      if (r.type == 'media-source' && r.values['trackIdentifier'] == trackId) r.id,
  };
  final roots = [
    for (final r in all)
      if ((r.type == 'inbound-rtp' && r.values['trackIdentifier'] == trackId) ||
          (r.type == 'outbound-rtp' && sourceIds.contains(r.values['mediaSourceId'])))
        r,
  ];
  if (roots.isEmpty) return const [];
  final picked = <String>{};
  final out = <rtc.StatsReport>[];
  final queue = [...roots];
  while (queue.isNotEmpty) {
    final r = queue.removeLast();
    if (!picked.add(r.id)) continue;
    out.add(r);
    for (final e in r.values.entries) {
      final key = e.key.toString();
      final value = e.value;
      if (key.endsWith('Id') && value is String) {
        final ref = byId[value];
        if (ref != null && !picked.contains(ref.id)) queue.add(ref);
      }
    }
  }
  return out;
}

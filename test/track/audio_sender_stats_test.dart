// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Uplink loss / RTT of a published microphone live in the remote-inbound-rtp
// report (what the SFU's receiver reports back), not in outbound-rtp. Reading them
// from outbound-rtp gave packetsLost 0 and roundTripTime null on Android: the
// Kuwait tester showed 0 % loss while doh1 measured ~15 % uplink loss (2026-09-29).
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/participant/local.dart' show gravixDisableRed;
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';

void main() {
  // recorded shape (libwebrtc getStats of an audio RTCRtpSender, Android)
  final report = [
    rtc.StatsReport('OT01A1234', 'outbound-rtp', 1e15, {
      'kind': 'audio', 'ssrc': 1234, 'packetsSent': 1000, 'bytesSent': 80000, 'remoteId': 'RIA1234', //
      'codecId': 'COT01_111', 'mediaSourceId': 'SA1',
    }),
    rtc.StatsReport('RIA1234', 'remote-inbound-rtp', 1e15, {
      'kind': 'audio', 'ssrc': 1234, 'packetsLost': 150, 'jitter': 0.012, 'roundTripTime': 0.047, //
      'fractionLost': 0.15, 'localId': 'OT01A1234',
    }),
    rtc.StatsReport('COT01_111', 'codec', 1e15, {
      'mimeType': 'audio/opus',
      'payloadType': 111,
      'channels': 2,
      'clockRate': 48000,
    }),
  ];

  test('packetsLost / roundTripTime / jitter come from remote-inbound-rtp', () {
    final s = audioSenderStatsFrom(report)!;
    expect(s.packetsSent, 1000);
    expect(s.bytesSent, 80000);
    expect(s.packetsLost, 150);
    expect(s.roundTripTime, closeTo(0.047, 1e-9));
    expect(s.jitter, closeTo(0.012, 1e-9));
    expect(s.mimeType, 'audio/opus');
  });

  test('matched by localId when outbound-rtp names no remoteId', () {
    final r = [
      rtc.StatsReport('OT1', 'outbound-rtp', 1e15, {'kind': 'audio', 'packetsSent': 10, 'bytesSent': 800}),
      rtc.StatsReport('RI1', 'remote-inbound-rtp', 1e15, {
        'kind': 'audio',
        'packetsLost': 3,
        'roundTripTime': 0.05,
        'localId': 'OT1',
      }),
    ];
    final s = audioSenderStatsFrom(r)!;
    expect(s.packetsLost, 3);
    expect(s.roundTripTime, closeTo(0.05, 1e-9));
  });

  test('no remote-inbound-rtp yet (first seconds): loss and RTT unknown, not 0', () {
    final s = audioSenderStatsFrom([report.first])!;
    expect(s.packetsSent, 1000);
    expect(s.packetsLost, isNull);
    expect(s.roundTripTime, isNull);
  });

  test('RED is on by default for an audio publish, off with E2EE or when asked', () {
    expect(gravixDisableRed(e2ee: false, red: null), isFalse);
    expect(gravixDisableRed(e2ee: false, red: true), isFalse);
    expect(gravixDisableRed(e2ee: false, red: false), isTrue);
    expect(gravixDisableRed(e2ee: true, red: true), isTrue);
  });
}

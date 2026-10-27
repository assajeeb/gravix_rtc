// Copyright 2026 Gravity Compile. MIT License; see LICENSE.
//
// 0.7.1 (field crash 2026-10-27): per-track stats come from the connection-wide
// getStats(), never from sender/receiver.getStats() — on Android those make the
// plugin dispose its sender/receiver wrappers while onAddTrack uses them, and
// the app aborts (jvm.cc:81). See lib/src/rtc_core/src/stats/gravix_track_stats.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/stats/gravix_track_stats.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/remote/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

rtc.StatsReport _r(String id, String type, Map<String, dynamic> values) =>
    rtc.StatsReport(id, type, 0, {'id': id, 'type': type, ...values});

/// A connection carrying two remote audio tracks (A, B) and one local camera
/// with three simulcast layers, all on one transport.
final _all = <rtc.StatsReport>[
  _r('T1', 'transport', {'selectedCandidatePairId': 'CP1', 'localCertificateId': 'CF1'}),
  _r('CP1', 'candidate-pair', {'transportId': 'T1', 'localCandidateId': 'L1', 'remoteCandidateId': 'R1'}),
  _r('L1', 'local-candidate', {'transportId': 'T1'}),
  _r('R1', 'remote-candidate', {'transportId': 'T1'}),
  _r('CF1', 'certificate', {}),
  _r('COpus', 'codec', {'transportId': 'T1', 'mimeType': 'audio/opus'}),
  _r('CVP8', 'codec', {'transportId': 'T1', 'mimeType': 'video/VP8'}),
  _r('IA', 'inbound-rtp', {
    'kind': 'audio',
    'trackIdentifier': 'trackA',
    'codecId': 'COpus',
    'transportId': 'T1',
    'bytesReceived': 100,
  }),
  _r('IB', 'inbound-rtp', {
    'kind': 'audio',
    'trackIdentifier': 'trackB',
    'codecId': 'COpus',
    'transportId': 'T1',
    'bytesReceived': 200,
  }),
  _r('MS', 'media-source', {'kind': 'video', 'trackIdentifier': 'cam'}),
  for (final rid in ['q', 'h', 'f'])
    _r('O$rid', 'outbound-rtp', {
      'kind': 'video',
      'rid': rid,
      'mediaSourceId': 'MS',
      'codecId': 'CVP8',
      'transportId': 'T1',
      'remoteId': 'RI$rid',
    }),
  for (final rid in ['q', 'h', 'f'])
    _r('RI$rid', 'remote-inbound-rtp', {'kind': 'video', 'localId': 'O$rid', 'codecId': 'CVP8'}),
];

Set<String> _ids(List<rtc.StatsReport> rs) => {for (final r in rs) r.id};

void main() {
  group('gravixScopeStatsToTrack', () {
    test('a remote track: its inbound-rtp and what it references, not the other track', () {
      final ids = _ids(gravixScopeStatsToTrack(_all, 'trackA'));
      expect(ids, {'IA', 'COpus', 'T1', 'CP1', 'L1', 'R1', 'CF1'});
    });

    test('a local camera: every simulcast layer via its media-source, with the remote-inbound reports', () {
      final ids = _ids(gravixScopeStatsToTrack(_all, 'cam'));
      expect(ids, containsAll(['Oq', 'Oh', 'Of', 'RIq', 'RIh', 'RIf', 'MS', 'CVP8', 'T1', 'CP1']));
      expect(ids, isNot(contains('IA')));
      expect(ids, isNot(contains('COpus')));
    });

    test('a track with no RTP stream yet, or no id: nothing', () {
      expect(gravixScopeStatsToTrack(_all, 'nope'), isEmpty);
      expect(gravixScopeStatsToTrack(_all, ''), isEmpty);
    });

    test('a reference cycle (remote-inbound <-> outbound) terminates, each report once', () {
      final rs = gravixScopeStatsToTrack(_all, 'cam');
      expect(rs.length, _ids(rs).length);
    });
  });

  group('track stats read the connection, never the receiver', () {
    test('RemoteAudioTrack.getReceiverStats uses pc.getStats() and returns this track\'s numbers', () async {
      final receiver = FakeReceiver();
      final pc = FakePeerConnection(0)..stats = _all;
      final track = RemoteAudioTrack(
        TrackSource.microphone,
        FakeMediaStream([]),
        FakeMediaTrack('trackB'),
        receiver: receiver,
      )..gravixStatsPeerConnection = () => pc;
      final stats = await track.getReceiverStats();
      expect(receiver.getStatsCalls, 0, reason: 'the per-track call races onAddTrack on Android');
      expect(pc.getStatsCalls, 1);
      expect(stats?.bytesReceived, 200);
    });

    test('no connection known: no stats, and still no per-track call', () async {
      final receiver = FakeReceiver();
      final track = RemoteAudioTrack(
        TrackSource.microphone,
        FakeMediaStream([]),
        FakeMediaTrack('trackA'),
        receiver: receiver,
      );
      expect(await track.getReceiverStats(), isNull);
      expect(receiver.getStatsCalls, 0);
    });

    test('no sender/receiver getStats() call is left in the SDK', () {
      final offenders = <String>[];
      for (final f in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i].trimLeft();
          if (l.startsWith('//')) continue;
          if (RegExp(r'(sender|receiver)\b[!?]?\.getStats\(').hasMatch(l)) offenders.add('${f.path}:${i + 1}');
        }
      }
      expect(offenders, isEmpty);
    });
  });
}

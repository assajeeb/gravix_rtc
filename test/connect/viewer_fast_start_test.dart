// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  // A trimmed libwebrtc subscriber answer: BUNDLE, one data + audio + video section.
  const answer =
      'v=0\r\n'
      'o=- 1 2 IN IP4 127.0.0.1\r\n'
      's=-\r\n'
      't=0 0\r\n'
      'a=group:BUNDLE 0 1 2\r\n'
      'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
      'a=fingerprint:sha-256 AA:BB\r\n'
      'a=setup:active\r\n'
      'a=mid:0\r\n'
      'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
      'a=setup:active\r\n'
      'a=mid:1\r\n'
      'a=recvonly\r\n'
      'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
      'a=setup:active\r\n'
      'a=mid:2\r\n'
      'a=recvonly\r\n';

  group('gravixPassiveDtlsAnswer', () {
    test('every a=setup:active becomes passive, CRLF kept, nothing else changes', () {
      final out = gravixPassiveDtlsAnswer(answer);
      expect(RegExp('a=setup:active').hasMatch(out), isFalse);
      expect(RegExp(r'a=setup:passive\r\n').allMatches(out).length, 3);
      expect(out.replaceAll('a=setup:passive', 'a=setup:active'), answer);
    });

    test('LF-only SDP keeps LF', () {
      final lf = answer.replaceAll('\r\n', '\n');
      final out = gravixPassiveDtlsAnswer(lf);
      expect(out.contains('\r'), isFalse);
      expect(RegExp(r'^a=setup:passive$', multiLine: true).allMatches(out).length, 3);
    });

    test('passive / actpass lines and look-alikes are left alone', () {
      const sdp = 'a=setup:passive\r\na=setup:actpass\r\na=setup:activeX\r\nx a=setup:active\r\n';
      expect(gravixPassiveDtlsAnswer(sdp), sdp);
    });

    test('idempotent: a second pass (a renegotiation) asks for the same role', () {
      final once = gravixPassiveDtlsAnswer(answer);
      expect(gravixPassiveDtlsAnswer(once), once);
    });
  });

  group('gravixSkipFirstVisibilityReport', () {
    test('skips only with the switch on and no view yet', () {
      expect(gravixSkipFirstVisibilityReport(enabled: true, viewCount: 0), isTrue);
      expect(gravixSkipFirstVisibilityReport(enabled: true, viewCount: 1), isFalse);
      expect(gravixSkipFirstVisibilityReport(enabled: false, viewCount: 0), isFalse);
    });
  });

  group('gravixWithSubscriberConnectPing', () {
    test('adds the key, keeps every other entry, does not touch the input', () {
      final base = <String, dynamic>{
        'iceServers': [
          {'urls': 'stun:example.org'},
        ],
        'sdpSemantics': 'unified-plan',
      };
      final out = gravixWithSubscriberConnectPing(base, 100);
      expect(out['stableWritableConnectionPingIntervalMs'], 100);
      // never shorter than the strong-connectivity interval, or libwebrtc refuses the config
      expect(out['iceCheckIntervalStrongConnectivityMs'], lessThanOrEqualTo(100));
      expect(out['iceServers'], same(base['iceServers']));
      expect(out['sdpSemantics'], 'unified-plan');
      expect(base.containsKey('stableWritableConnectionPingIntervalMs'), isFalse);
    });
  });

  // 0.4.9 defaults: passive DTLS on (measured, no plugin dependency); the
  // connect ping (needs a plugin that maps both keys) and the skipped first
  // report (no measurable gain) are opt-in.
  test('defaults (0.4.9): passive DTLS on, connect ping and no-disable off', () {
    expect(GravixViewerFastStart.passiveSubscriberDtls, isTrue);
    expect(GravixViewerFastStart.noDisableBeforeFirstView, isFalse);
    expect(GravixViewerFastStart.subscriberConnectPingIntervalMs, isNull);
  });

  // The two call sites live in vendored files that need a native peer
  // connection / a Room; pin the wiring at source level so a rebase that drops
  // it fails here.
  test('wiring: the subscriber answer and the subscription use the switches', () {
    final engine = File('lib/src/rtc_core/src/core/engine.dart').readAsStringSync();
    expect(engine, contains('GravixViewerFastStart.passiveSubscriberDtls'));
    expect(engine, contains('gravixPassiveDtlsAnswer(sdp)'));
    expect(engine, contains("_gravixMark('answerFailed'"));
    expect(engine, contains('gravixWithSubscriberConnectPing(config, connectPing)'));
    // restored (setConfiguration without the key) once the subscriber is connected
    expect(engine, contains('.setConfiguration(restore.toMap())'));
    final remote = File('lib/src/rtc_core/src/publication/remote.dart').readAsStringSync();
    expect(remote, contains('GravixViewerFastStart.noDisableBeforeFirstView'));
    expect(remote, contains('(GravixViewerFastStart.noDisableBeforeFirstView && _lastSentTrackSettings == null) ||'));
  });
}

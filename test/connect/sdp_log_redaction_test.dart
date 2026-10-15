// Copyright 2026 Gravity Compile
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// No SDP body in a log line (2026-10-15): the upstream setMungedSDP warnings
// printed the whole offer (a=ice-pwd, a=ice-ufrag, a=fingerprint) whenever
// libwebrtc refused it. Now a log names the type and the m-line list only, and
// an error's text is cut before any SDP it quotes.
@Timeout(Duration(seconds: 5))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/gravix_pub_log.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/transport.dart' show Transport;
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/logger.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:logging/logging.dart';

import '../support/fake_rtc.dart';

const _pwd = 'S3cr3tIcePwdValue0123456789ab';
const _ufrag = 'UfRgX9';
const _fp = 'AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89';

const _sdp =
    'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=ice-ufrag:$_ufrag\r\na=ice-pwd:$_pwd\r\n'
    'a=fingerprint:sha-256 $_fp\r\na=setup:actpass\r\na=mid:0\r\na=sendonly\r\na=rtpmap:111 opus/48000/2\r\n';

/// Refuses every local description; the error quotes the SDP like a libwebrtc
/// parse error quotes the offending line.
class _RefusingPc extends FakePeerConnection {
  _RefusingPc() : super(0);

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async =>
      throw Exception('Failed to set local offer sdp: SessionDescription is NULL. ${description.sdp}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  void expectClean(String text) {
    expect(text, isNot(contains('a=ice-pwd')));
    expect(text, isNot(contains(_pwd)));
    expect(text, isNot(contains(_ufrag)));
    expect(text, isNot(contains(_fp)));
  }

  test('setMungedSDP refused twice: the warnings, the [GravixPub] lines and the error carry no SDP body', () async {
    final records = <String>[];
    final pubLines = <String>[];
    final hierarchical = hierarchicalLoggingEnabled;
    hierarchicalLoggingEnabled = true;
    final level = logger.level;
    final sink = GravixPubLog.sink;
    logger.level = Level.ALL;
    final sub = logger.onRecord.listen((r) => records.add('${r.level.name} ${r.message}'));
    GravixPubLog.sink = pubLines.add;
    addTearDown(() async {
      await sub.cancel();
      logger.level = level;
      hierarchicalLoggingEnabled = hierarchical;
      GravixPubLog.sink = sink;
    });

    final transport = await Transport.create(
      (Map<String, dynamic> c, [Map<String, dynamic>? k]) async => _RefusingPc(),
      connectOptions: const ConnectOptions(),
    );
    addTearDown(transport.dispose);

    Object? thrown;
    try {
      await transport.setMungedSDP(
        sd: rtc.RTCSessionDescription(_sdp, 'offer'),
        munged: _sdp.replaceFirst('a=sendonly', 'a=sendrecv'),
      );
    } catch (e) {
      thrown = e;
    }

    final warnings = records.where((r) => r.startsWith('WARNING')).toList();
    expect(warnings, hasLength(2), reason: records.join('\n'));
    expect(warnings.first, contains('mlines=audio:0/sendrecv'));
    expect(warnings.last, contains('mlines=audio:0/sendonly'));
    expect(warnings.last, contains('<sdp omitted>'));
    for (final line in [...records, ...pubLines]) {
      expectClean(line);
    }
    // the native error itself is rethrown to the transport, which wraps it
    // (redacted) in a NegotiationError: see the next test
    expect(thrown, isNotNull);
  });

  test('a refused offer surfaces as a NegotiationError without the SDP', () async {
    final transport = await Transport.create(
      (Map<String, dynamic> c, [Map<String, dynamic>? k]) async => _RefusingPc(),
      connectOptions: const ConnectOptions(),
    );
    addTearDown(transport.dispose);
    transport.onOffer = (_) {};
    Object? thrown;
    try {
      await transport.createAndSendOffer();
    } catch (e) {
      thrown = e;
    }
    expect('$thrown', contains('NegotiationError'));
    expect('$thrown', contains('Failed to set local offer sdp'));
    expect('$thrown', isNot(contains('v=0')));
    expectClean('$thrown');
  });

  test('signal offer / answer events print the type and m-lines, never the body', () {
    final sd = rtc.RTCSessionDescription(_sdp, 'offer');
    for (final s in ['${SignalOfferEvent(sd: sd)}', '${SignalAnswerEvent(sd: sd)}']) {
      expect(s, contains('offer mlines=audio:0/sendonly'));
      expectClean(s);
    }
  });

  test('safeError redacts values even without an SDP body around them', () {
    final s = GravixPubLog.safeError('bad line ice-pwd:$_pwd and fingerprint:sha-256 $_fp, ufrag ice-ufrag $_ufrag');
    expectClean(s);
    expect(s, contains('ice-pwd:<redacted>'));
    expect(GravixPubLog.safeError("The order of m-lines in subsequent offer doesn't match"), contains('m-lines'));
  });
}

// Copyright 2026 LiveKit, Inc.
// Modifications Copyright 2026 Gravity Compile
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

// Upstream 2.13.1 port (client-sdk-flutter #1226, test/core/transport_negotiate_test.dart
// at tag v2.13.1): Transport.negotiate is debounced, so a failed offer (e.g. a
// rejected setLocalDescription) escaped as an unhandled error and the
// try/catch in Engine.negotiate never saw it -- the reconnect it meant to start
// never ran. (The 2026-10-10 report listed the fork's catch at engine.dart:455
// as "already equivalent"; it was the dead pre-#1226 catch.) The errors now go
// to Transport.onNegotiationError, which the engine wires to the reconnect when
// GravixRecoveryOptions.upstreamReconnectFixes is on.
@Timeout(Duration(seconds: 5))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/transport.dart' show Transport;
import 'package:gravix_rtc/src/rtc_core/src/exceptions.dart' show NegotiationError;
import 'package:gravix_rtc/src/rtc_core/src/options.dart';

import '../support/fake_rtc.dart';

class _RejectAfterAnswerPeerConnection extends FakePeerConnection {
  _RejectAfterAnswerPeerConnection({this.rejectLocal = false}) : super(0);
  bool rejectLocal;

  /// One m-line per sender: a sender change the replay must carry (0.4.19: a
  /// replay whose senders did not change is skipped).
  int senderCount = 1;

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    offers.add(Map.of(constraints ?? const {}));
    final b = StringBuffer('v=0\r\ns=-\r\nt=0 0\r\n');
    for (var i = 0; i < senderCount; i++) {
      b.write('m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:$i\r\na=sendonly\r\n');
    }
    return rtc.RTCSessionDescription(b.toString(), 'offer');
  }

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async {
    if (rejectLocal) {
      throw Exception('The order of m-lines in subsequent offer doesn\'t match order from previous offer/answer.');
    }
    await super.setLocalDescription(description);
  }
}

Future<Transport> _transportOn(rtc.RTCPeerConnection pc) => Transport.create(
  (Map<String, dynamic> c, [Map<String, dynamic>? k]) async => pc,
  connectOptions: const ConnectOptions(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  group('Transport.negotiate', () {
    test('reports a failed offer to onNegotiationError instead of leaking an unhandled error', () async {
      final uncaught = <Object>[];
      final reported = Completer<Object>();

      await runZonedGuarded(() async {
        final transport = await _transportOn(_RejectAfterAnswerPeerConnection(rejectLocal: true));
        addTearDown(transport.dispose);
        transport.onOffer = (_) {};
        transport.onNegotiationError = reported.complete;

        transport.negotiate(null);

        // Outlast the debounce and the rejected setLocalDescription.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }, (error, stack) => uncaught.add(error));

      expect(uncaught, isEmpty);
      expect(reported.isCompleted, isTrue);
      expect(await reported.future, isA<NegotiationError>());
    });

    test('does not report when the offer is sent', () async {
      final offers = <rtc.RTCSessionDescription>[];
      final transport = await _transportOn(FakePeerConnection(0));
      addTearDown(transport.dispose);
      transport.onOffer = offers.add;
      transport.onNegotiationError = (error) => fail('unexpected negotiation error: $error');

      transport.negotiate(null);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(offers, hasLength(1));
    });

    test('reports a failed deferred offer to onNegotiationError', () async {
      final pc = _RejectAfterAnswerPeerConnection();
      final transport = await _transportOn(pc);
      addTearDown(transport.dispose);
      transport.onOffer = (_) {};
      final reported = Completer<Object>();
      transport.onNegotiationError = reported.complete;

      // An offer is already waiting for its answer, so the next one is deferred.
      // (0.4.19: made by the Transport, whose Dart-side pending mark replaced the
      // native signaling-state read; then a sender change while it is out)
      await transport.createAndSendOffer();
      pc.senderCount = 2;
      await transport.createAndSendOffer();
      expect(transport.renegotiate, isTrue);

      pc.rejectLocal = true;
      await transport.setRemoteDescription(rtc.RTCSessionDescription('v=0', 'answer'));

      expect(reported.isCompleted, isTrue);
      expect(await reported.future, isA<NegotiationError>());
    });

    test('throws from setRemoteDescription when a deferred offer fails and no handler is set', () async {
      final pc = _RejectAfterAnswerPeerConnection();
      final transport = await _transportOn(pc);
      addTearDown(transport.dispose);
      transport.onOffer = (_) {};

      // (0.4.19: made by the Transport, whose Dart-side pending mark replaced the
      // native signaling-state read; then a sender change while it is out)
      await transport.createAndSendOffer();
      pc.senderCount = 2;
      await transport.createAndSendOffer();
      expect(transport.renegotiate, isTrue);

      pc.rejectLocal = true;
      await expectLater(
        transport.setRemoteDescription(rtc.RTCSessionDescription('v=0', 'answer')),
        throwsA(isA<NegotiationError>()),
      );
    });

    test('still throws from a direct createAndSendOffer', () async {
      final transport = await _transportOn(_RejectAfterAnswerPeerConnection(rejectLocal: true));
      addTearDown(transport.dispose);
      transport.onOffer = (_) {};
      transport.onNegotiationError = (error) => fail('unexpected negotiation error: $error');

      await expectLater(transport.createAndSendOffer(), throwsA(isA<NegotiationError>()));
    });
  });

  group('engine wiring', () {
    test('the publisher reports to the engine with the fixes on, not with them off', () async {
      final on = await connectedFakeEngine(FakeSignalServer(), FakePcFactory());
      addTearDown(on.dispose);
      expect(on.publisher!.onNegotiationError, isNotNull);
      final off = await connectedFakeEngine(
        FakeSignalServer(),
        FakePcFactory(),
        roomOptions: const RoomOptions(recovery: GravixRecoveryOptions(upstreamReconnectFixes: false)),
      );
      addTearDown(off.dispose);
      expect(off.publisher!.onNegotiationError, isNull);
    });
  });
}

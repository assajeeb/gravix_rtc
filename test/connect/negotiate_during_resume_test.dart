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

// BUG-3 (REAL iPhone 2026-10-10 21:39:06, d7_app.log, SDK 8470448): a ping
// timeout started a resume; 6 ms later the data saver unpublished the camera,
// the debounced renegotiation created offer O2 (video sender gone) and
// setLocalDescription(O2) put the publisher in have-local-offer, but the offer
// was DROPPED ("Could not send message, socket not connected": offers cannot
// be queued while reconnecting). The resume's ICE-restart offer then found
// have-local-offer and re-applied the CURRENT remote answer A1 -- the answer to
// O1, which still had the video sender -- so libwebrtc refused it:
// "Failed to set remote answer sdp: Incompatible send direction", twice, and
// the session fell back to a full reconnect.
//
// Two fixes, two flags:
//  - Transport.gravixHoldOffers (GravixRecoveryOptions.deferNegotiateDuringResume):
//    an offer the socket cannot carry is not created at all; it is marked
//    `renegotiate` and replayed after the next answer (the resume's restart
//    answer), so the publisher never sits on an offer nobody will answer.
//  - Transport.gravixRollbackStaleOffer (rollbackStaleOfferOnRestart): when an
//    ICE restart still finds a local offer that was sent but never answered (the
//    socket died after it left), roll that offer back instead of re-applying an
//    answer to a different offer.
@Timeout(Duration(seconds: 5))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/transport.dart' show Transport;
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/types.dart' show RTCOfferOptions;

import '../support/fake_rtc.dart';

/// libwebrtc's offer/answer state as far as this bug needs it: a pending local
/// offer, the current (last applied) local/remote pair that `remoteDescription`
/// keeps returning while an offer is pending, and an answer that only applies
/// to the offer it answered (the m-line directions must match).
class _SdpStatePc extends FakePeerConnection {
  _SdpStatePc() : super(0);

  /// Bumped by the test to model a sender change (removeTrack -> the next
  /// offer's video m-line direction differs).
  int senderVersion = 1;
  final log = <String>[];

  rtc.RTCSessionDescription? _pending;
  rtc.RTCSessionDescription? _currentLocal;
  rtc.RTCSessionDescription? _currentRemote;

  static String _tag(String? sdp) => RegExp(r's=(\w+)').firstMatch(sdp ?? '')?.group(1) ?? '-';

  rtc.RTCSessionDescription answerTo(rtc.RTCSessionDescription offer) =>
      rtc.RTCSessionDescription('v=0\r\ns=${_tag(offer.sdp)}\r\nt=0 0\r\n', 'answer');

  rtc.RTCSessionDescription? get pending => _pending;

  @override
  rtc.RTCSignalingState? get signalingState => _pending != null
      ? rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer
      : rtc.RTCSignalingState.RTCSignalingStateStable;

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    offers.add(Map.of(constraints ?? const {}));
    log.add('createOffer:v$senderVersion${constraints?['iceRestart'] == true ? ':restart' : ''}');
    return rtc.RTCSessionDescription('v=0\r\ns=v$senderVersion\r\nt=0 0\r\n', 'offer');
  }

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async {
    log.add('local:${description.type}');
    if (description.type == 'rollback') {
      if (_pending == null) throw Exception('Failed to set local rollback: Called in wrong state: stable');
      _pending = null;
      return;
    }
    _pending = description;
  }

  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription description) async {
    log.add('remote:${description.type}:${_tag(description.sdp)}');
    final pending = _pending;
    if (pending == null) throw Exception('Failed to set remote answer sdp: Called in wrong state: stable');
    if (_tag(description.sdp) != _tag(pending.sdp)) {
      throw Exception('Failed to set remote answer sdp: Incompatible send direction');
    }
    _currentLocal = pending;
    _currentRemote = description;
    _pending = null;
  }

  @override
  Future<rtc.RTCSessionDescription?> getRemoteDescription() async => _currentRemote;
  @override
  Future<rtc.RTCSessionDescription?> getLocalDescription() async => _pending ?? _currentLocal;
}

Future<Transport> _transportOn(rtc.RTCPeerConnection pc) => Transport.create(
  (Map<String, dynamic> c, [Map<String, dynamic>? k]) async => pc,
  connectOptions: const ConnectOptions(),
);

/// O1 sent and answered: the publisher is stable with a video sender (v1).
Future<(Transport, _SdpStatePc, List<rtc.RTCSessionDescription>)> _publishedOnce() async {
  final pc = _SdpStatePc();
  final transport = await _transportOn(pc);
  final sent = <rtc.RTCSessionDescription>[];
  transport.onOffer = sent.add;
  await transport.createAndSendOffer();
  await transport.setRemoteDescription(pc.answerTo(sent.single));
  expect(pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
  return (transport, pc, sent);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  group('BUG-3: an offer made during a resume dial', () {
    test('legacy: the restart re-applies the old answer to a changed, unanswered offer and fails', () async {
      final (transport, pc, sent) = await _publishedOnce();
      addTearDown(transport.dispose);

      // The resume is dialling; the camera is unpublished (v2) and the
      // renegotiation fires. Its offer is applied locally but never answered.
      pc.senderVersion = 2;
      await transport.createAndSendOffer();
      expect(pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer);

      final mark = pc.log.length;
      await expectLater(
        transport.createAndSendOffer(const RTCOfferOptions(iceRestart: true)),
        throwsA(predicate((e) => '$e'.contains('Incompatible send direction'))),
      );
      expect(pc.log.sublist(mark), contains('remote:answer:v1'));
    });

    test(
      'hold: no offer is created while the socket cannot carry it; it is replayed after the restart answer',
      () async {
        final (transport, pc, sent) = await _publishedOnce();
        addTearDown(transport.dispose);
        var socketDown = true;
        transport.gravixHoldOffers = () => socketDown;

        pc.senderVersion = 2;
        transport.negotiate(null);
        await Future<void>.delayed(const Duration(milliseconds: 150)); // outlast the debounce
        expect(pc.log.where((l) => l == 'createOffer:v2'), isEmpty, reason: 'the held offer must not be created');
        expect(pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
        expect(transport.renegotiate, isTrue);

        // The resume's ReconnectResponse: the socket is back; the restart offer is
        // never held and carries the current senders.
        socketDown = false;
        await transport.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
        expect(pc.log.last, 'local:offer');
        expect(sent.length, 2);
        await transport.setRemoteDescription(pc.answerTo(sent.last));

        // the held renegotiation is replayed after that answer
        expect(sent.length, 3);
        expect(transport.renegotiate, isFalse);
      },
    );

    test('rollback: a restart rolls back a sent-but-unanswered offer instead of re-applying the old answer', () async {
      final (transport, pc, sent) = await _publishedOnce();
      addTearDown(transport.dispose);
      transport.gravixRollbackStaleOffer = true;

      // The renegotiation offer left before the socket died; its answer is lost.
      pc.senderVersion = 2;
      await transport.createAndSendOffer();
      expect(sent.length, 2);
      expect(pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer);

      final mark = pc.log.length;
      await transport.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
      expect(
        pc.log.sublist(mark),
        isNot(contains('remote:answer:v1')),
        reason: 'the old answer must not be re-applied',
      );
      expect(pc.log.sublist(mark), contains('local:rollback'));
      expect(pc.log.last, 'local:offer');
      expect(pc.offers.last['iceRestart'], isTrue);
      expect(sent.length, 3);

      await transport.setRemoteDescription(pc.answerTo(sent.last));
      expect(pc.signalingState, rtc.RTCSignalingState.RTCSignalingStateStable);
    });

    test('rollback refused by the native side: falls back to re-applying the answer (the old behaviour)', () async {
      final pc = _NoRollbackPc();
      final transport = await _transportOn(pc);
      addTearDown(transport.dispose);
      final sent = <rtc.RTCSessionDescription>[];
      transport.onOffer = sent.add;
      transport.gravixRollbackStaleOffer = true;
      await transport.createAndSendOffer();
      await transport.setRemoteDescription(pc.answerTo(sent.single));

      await transport.createAndSendOffer(); // same senders: the old answer still fits
      final mark = pc.log.length;
      await transport.createAndSendOffer(const RTCOfferOptions(iceRestart: true));
      expect(pc.log.sublist(mark), contains('remote:answer:v1'));
      expect(pc.offers.last['iceRestart'], isTrue);
    });
  });

  group('engine: the BUG-3 sequence (resume dialling, camera unpublished, renegotiation)', () {
    late Engine engine;
    tearDown(() async => engine.dispose());

    /// Returns (resumed, full restarts, the publisher's description log).
    Future<(int, int, List<String>)> run(GravixRecoveryOptions recovery) async {
      final server = FakeSignalServer()
        ..answerOffers = true
        ..answerSdp = (offer) => 'v=0\r\ns=${_SdpStatePc._tag(offer)}\r\nt=0 0\r\n';
      final pcs = _SdpPcFactory();
      engine = await connectedFakeEngine(
        server,
        pcs,
        roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
      );
      var resumed = 0, restarting = 0;
      engine.events.on<EngineResumedEvent>((_) => resumed++);
      engine.events.on<EngineFullRestartingEvent>((_) => restarting++);
      final pub = pcs.publisher as _SdpStatePc;

      // a published camera: O1 (v1) sent and answered
      await engine.negotiate();
      expect(await eventually(() => pub.log.contains('remote:answer:v1') && pub.pending == null), isTrue);

      // The socket dies (the ping timeout); the resume dial is slow.
      final dial = Completer<void>();
      server.onDial = (u) async {
        if (u.queryParameters['reconnect'] == '1' && !dial.isCompleted) await dial.future;
      };
      await server.last.serverClose();
      await settle(40); // the resume is dialling
      // the data saver unpublishes the camera; the renegotiation fires during the dial
      pub.senderVersion = 2;
      await engine.negotiate();
      await settle(40);
      dial.complete();
      await eventually(() => resumed > 0 || restarting > 0, timeout: const Duration(seconds: 4));
      await settle(300);
      return (resumed, restarting, List.of(pub.log));
    }

    test('legacy (both flags off): the resume fails on the stale answer and falls back to a full reconnect', () async {
      final (resumed, restarting, log) = await run(
        const GravixRecoveryOptions().copyWith(deferNegotiateDuringResume: false, rollbackStaleOfferOnRestart: false),
      );
      expect(restarting, greaterThan(0), reason: 'iPhone d7: "resume failed 2 times; full reconnect"');
      expect(log, contains('createOffer:v2'), reason: 'the dropped renegotiation offer was made during the dial');
    });

    test('defaults: the renegotiation is held, the resume succeeds, the camera removal reaches the server', () async {
      final (resumed, restarting, log) = await run(const GravixRecoveryOptions());
      expect(restarting, 0);
      expect(resumed, 1);
      expect(log, contains('createOffer:v2:restart'), reason: 'the restart offer carries the current senders');
      expect(log.last, 'remote:answer:v2', reason: 'stable on an answer to a v2 offer');
    });

    test('flags on/off: on by default, off in legacy, kept by copyWith', () {
      const on = GravixRecoveryOptions();
      expect(on.deferNegotiateDuringResume && on.rollbackStaleOfferOnRestart, isTrue);
      expect(GravixRecoveryOptions.legacy.deferNegotiateDuringResume, isFalse);
      expect(GravixRecoveryOptions.legacy.rollbackStaleOfferOnRestart, isFalse);
      final c = on.copyWith(deferNegotiateDuringResume: false);
      expect(c.deferNegotiateDuringResume, isFalse);
      expect(c.rollbackStaleOfferOnRestart, isTrue);
    });
  });
}

class _SdpPcFactory extends FakePcFactory {
  @override
  Future<rtc.RTCPeerConnection> create(Map<String, dynamic> configuration, [Map<String, dynamic>? constraints]) async {
    final pc = _SdpStatePc();
    all.add(pc);
    onCreate?.call(pc);
    return pc;
  }
}

class _NoRollbackPc extends _SdpStatePc {
  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async {
    if (description.type == 'rollback') {
      log.add('local:rollback:refused');
      throw Exception('rollback not supported');
    }
    await super.setLocalDescription(description);
  }
}

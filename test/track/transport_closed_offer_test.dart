// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Device run A4 (Infinix, 2026-10-10, c8fc3c4): leaving the room unpublished
// the microphone, the debounced renegotiation fired, and the leave closed the
// publisher peer connection while the offer was in flight: an unhandled
// "[NegotiationError] Unable to RTCPeerConnection::setLocalDescription ...
// Called in wrong state: closed" at Transport.createAndSendOffer. A transport
// that is being disposed has nothing to negotiate: the failure is dropped.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/transport.dart';
import 'package:gravix_rtc/src/rtc_core/src/exceptions.dart' show NegotiationError;
import 'package:gravix_rtc/src/rtc_core/src/options.dart';

class _FakePc implements rtc.RTCPeerConnection {
  final offerGate = Completer<void>();
  bool closed = false;

  @override
  Future<rtc.RTCSignalingState?> getSignalingState() async =>
      closed ? rtc.RTCSignalingState.RTCSignalingStateClosed : rtc.RTCSignalingState.RTCSignalingStateStable;

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    await offerGate.future;
    return rtc.RTCSessionDescription('v=0\r\n', 'offer');
  }

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async {
    if (closed) {
      throw Exception(
        'peerConnectionSetLocalDescription(): WEBRTC_SET_LOCAL_DESCRIPTION_ERROR: Called in wrong state: closed',
      );
    }
    throw Exception('rejected for another reason');
  }

  @override
  Future<List<rtc.RTCRtpSender>> getSenders() async => const [];

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isSetter ? null : super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(Transport, _FakePc)> transport() async {
    final pc = _FakePc();
    final t = await Transport.create(
      (config, [constraints = const <String, dynamic>{}]) async => pc,
      connectOptions: const ConnectOptions(),
    );
    t.onOffer = (_) {};
    return (t, pc);
  }

  test('an offer in flight when the transport is disposed (a leave) does not throw', () async {
    final (t, pc) = await transport();
    final offer = t.createAndSendOffer();
    await t.dispose(); // the leave: closes the peer connection
    expect(pc.closed, isTrue);
    pc.offerGate.complete();
    await expectLater(offer, completes);
  });

  test('the debounced negotiate after a leave leaves no uncaught error', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final (t, pc) = await transport();
      t.negotiate(null);
      await Future<void>.delayed(const Duration(milliseconds: 150)); // past the debounce: in flight
      await t.dispose();
      pc.offerGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
  });

  test('a live transport still reports a real negotiation failure', () async {
    final (t, pc) = await transport();
    pc.offerGate.complete();
    await expectLater(t.createAndSendOffer(), throwsA(isA<NegotiationError>()));
    await t.dispose();
  });
}

// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The F1 root cause, as the server agent re-read the device logs (r023 / r025 /
// r032, 2026-10-10): ONE subscriber ICE-restart offer per resume (the second
// "Remote peer requests ICE restart" line was the publisher). resumeConnection
// set `subscriber.restartingIce = true` only after the publisher offer and
// getConnectionState(); the server's restart offer was already applied by
// then, so every later trickle candidate waited in the pending list forever,
// the phone kept pairing with the OLD server candidate on the same mux address
// ("bad remote username" x22-24) and the resume timed out. (Upstream has the
// same order.)
//
// 1. Exactly that sequence: the offer applied BEFORE the flag would be set, then
//    N trickle candidates: every one reaches the peer connection.
// 2. The stronger form (livekit-client JS triggerIceRestart order): the flag is
//    set BEFORE the resume request goes out, so candidates trickled between the
//    ReconnectResponse and the restart offer are held and added after the offer
//    -- not added against the OLD remote description, where the new ufrag's
//    candidates do not belong.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

import '../support/fake_rtc.dart';

lk_rtc.SignalResponse _offer(String tag) => lk_rtc.SignalResponse(
  offer: lk_rtc.SessionDescription(type: 'offer', sdp: 'v=0\r\ns=-\r\nt=0 0\r\na=tag:$tag\r\n'),
);

lk_rtc.SignalResponse _trickle(String foundation) => lk_rtc.SignalResponse(
  trickle: lk_rtc.TrickleRequest(
    target: lk_rtc.SignalTarget.SUBSCRIBER,
    candidateInit: json.encode({
      'candidate': 'candidate:$foundation 1 udp 2130706431 203.0.113.10 7882 typ host',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    }),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late Engine engine;
  tearDown(() async => engine.dispose());

  Future<void> viewer() async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(server, pcs, subscriberPrimary: true);
    // the session's first subscriber offer: the subscriber has a remote
    // description (the OLD one, once the resume restarts ICE)
    server.last.deliver(_offer('initial'));
    expect(await eventually(() => pcs.subscriber.descriptionLog.contains('local:answer')), isTrue);
  }

  test('the restart offer applied before restartingIce would be set: all N later candidates reach the PC', () async {
    await viewer();
    final sub = pcs.subscriber;
    // the server's one restart offer lands right behind the ReconnectResponse,
    // and is applied while resumeConnection is still in its publisher offer /
    // getConnectionState() step (r023: offer 7.245 s, the flag at 7.287 s)
    server.afterResumeAnswer = (ws) => ws.deliver(_offer('restart'));
    sub.connectionStateDelay = const Duration(milliseconds: 80);
    sub.disconnect();
    expect(await eventually(() => sub.descriptionLog.contains('remote:offer:done:restart')), isTrue);
    await settle(200); // resumeConnection is past the point where it set the flag
    final before = sub.addedCandidates.length;
    const n = 5;
    for (var i = 0; i < n; i++) {
      server.last.deliver(_trickle('c$i'));
    }
    await settle(100);
    expect(sub.addedCandidates.length - before, n, reason: '0.4.14 / 735974b: all $n wait in the pending list forever');
    expect(engine.subscriber!.restartingIce, isFalse);
    sub.connect();
  });

  test(
    'candidates trickled between the ReconnectResponse and the restart offer are held, then added after it',
    () async {
      await viewer();
      final sub = pcs.subscriber;
      server.afterResumeAnswer = (ws) {
        // the new candidates race ahead of the offer
        ws.deliver(_trickle('early1'));
        ws.deliver(_trickle('early2'));
        Future<void>.delayed(const Duration(milliseconds: 150), () => ws.deliver(_offer('restart')));
      };
      // resumeConnection is still in its getConnectionState() step when the
      // candidates are handled (the order the phone can see)
      sub.connectionStateDelay = const Duration(milliseconds: 80);
      sub.descriptionLog.clear();
      sub.disconnect();
      expect(await eventually(() => sub.descriptionLog.contains('remote:offer:done:restart')), isTrue);
      await settle(100);
      final log = sub.descriptionLog;
      final offerAt = log.indexOf('remote:offer:done:restart');
      final early = [log.indexOf('cand:early1'), log.indexOf('cand:early2')];
      expect(early, everyElement(greaterThan(offerAt)), reason: 'added against the OLD remote description: $log');
      sub.connect();
    },
  );
}

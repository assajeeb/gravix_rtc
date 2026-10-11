// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Device test of integ/sdk-2026-10-10 735974b (2026-10-10, fail_excerpts/):
//  F1 (r023): a viewer (subscriberPrimary) resumed; the deployed server sent the
//     subscriber ICE-restart offer twice ~180 ms apart, the client then logged
//     "bad remote username" x22 and resumeConnection waited the full
//     Timeouts.peerConnection (10 s) for the subscriber before a full rejoin:
//     video back 12.1 s after the network. S3 only covered the publisher.
//  F2 (r029): 87 ms after the ReconnectResponse the server sent
//     Leave{RESUME, CONNECTION_TIMEOUT} and closed the socket; the client kept
//     "Waiting for primary to connect..." for 10 s.
//  F3 (r017): after a 20 s per-app network block the attempt waited for a
//     connectivity event that never came (the unblock fires none): still
//     disconnected 62 s after the unblock.
// Plus a latent one found on the way: a subscriber restart offer handled
// before resumeConnection set `restartingIce` left every later trickle
// candidate stranded in the pending list.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';

import '../support/fake_rtc.dart';

lk_rtc.SignalResponse offer(String tag) => lk_rtc.SignalResponse(
  offer: lk_rtc.SessionDescription(type: 'offer', sdp: 'v=0\r\ns=-\r\nt=0 0\r\na=tag:$tag\r\n'),
);

lk_rtc.SignalResponse trickle(String foundation) => lk_rtc.SignalResponse(
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

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';

  Future<void> viewer({
    SignalClient? signal,
    Duration connection = const Duration(seconds: 5),
    Duration peerConnection = const Duration(seconds: 8),
    GravixRecoveryOptions? recovery,
  }) async {
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(
      server,
      pcs,
      subscriberPrimary: true,
      peerConnection: peerConnection,
      connection: connection,
      signalClient: signal,
      roomOptions: recovery == null ? null : RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
  }

  test('F1: the subscriber (primary) not back ~3 s after the resume -> full rejoin, not the 8 s wait', () async {
    server = FakeSignalServer();
    await viewer();
    final sub = pcs.subscriber;
    final dials = server.dials.length;
    final t0 = DateTime.now();
    sub.disconnect(); // ICE drops; the resume's subscriber restart never completes (bad ufrag)
    expect(await eventually(() => server.dials.skip(dials).any(isResume)), isTrue);
    autoConnectPcs(pcs); // the rejoin's new peer connections connect
    expect(
      await eventually(() => server.dials.skip(dials).any((u) => !isResume(u)), timeout: const Duration(seconds: 7)),
      isTrue,
    );
    final took = DateTime.now().difference(t0);
    expect(took, lessThan(const Duration(milliseconds: 4500)), reason: 'base: Timeouts.peerConnection (8 s here)');
  });

  test(
    'F1: a subscriber restart offer handled before the resume reached its wait does not strand candidates',
    () async {
      server = FakeSignalServer();
      await viewer();
      final sub = pcs.subscriber;
      // the server's ICE-restart offer lands right behind the ReconnectResponse
      server.afterResumeAnswer = (ws) => ws.deliver(offer('o1'));
      sub.connectionStateDelay = const Duration(milliseconds: 60); // the offer is handled first
      sub.disconnect();
      expect(await eventually(() => sub.descriptionLog.contains('remote:offer:done:o1')), isTrue);
      await settle(150);
      final before = sub.addedCandidates.length;
      server.last.deliver(trickle('c1')); // the server trickles its new candidates
      await settle(50);
      expect(sub.addedCandidates.length, before + 1, reason: 'base: queued until another offer that never comes');
      sub.connect();
    },
  );

  test('F1: two restart offers back to back are applied strictly in order (guard; already serialized)', () async {
    server = FakeSignalServer();
    await viewer();
    final sub = pcs.subscriber;
    sub.remoteDescriptionDelay = const Duration(milliseconds: 30);
    sub.descriptionLog.clear();
    server.last.deliver(offer('o1'));
    server.last.deliver(offer('o2'));
    expect(await eventually(() => sub.descriptionLog.where((e) => e == 'local:answer').length == 2), isTrue);
    expect(sub.descriptionLog, [
      'remote:offer:start:o1',
      'remote:offer:done:o1',
      'local:answer',
      'remote:offer:start:o2',
      'remote:offer:done:o2',
      'local:answer',
    ]);
    final answers = server.last.sent.where((r) => r.hasAnswer()).length;
    expect(answers, 2);
  });

  test('F2: a Leave{RESUME} while the resume waits for the primary aborts the wait at once', () async {
    server = FakeSignalServer();
    await viewer();
    final sub = pcs.subscriber;
    var resumes = 0;
    final srv = server;
    srv.afterResumeAnswer = (ws) {
      resumes++;
      if (resumes == 1) {
        // r029: 87 ms after the ReconnectResponse, Leave{RESUME, CONNECTION_TIMEOUT}, then close
        Timer(const Duration(milliseconds: 87), () async {
          ws.deliver(
            lk_rtc.SignalResponse(
              leave: lk_rtc.LeaveRequest(
                canReconnect: false,
                action: lk_rtc.LeaveRequest_Action.RESUME,
                reason: lk_models.DisconnectReason.CONNECTION_TIMEOUT,
              ),
            ),
          );
          await ws.serverClose();
        });
      } else {
        Timer(const Duration(milliseconds: 50), sub.connect);
      }
    };
    final t0 = DateTime.now();
    sub.disconnect();
    expect(await eventually(() => resumes >= 2, timeout: const Duration(seconds: 6)), isTrue);
    expect(
      DateTime.now().difference(t0),
      lessThan(const Duration(milliseconds: 2000)),
      reason: 'base: the Leave was dropped and the resume sat out its wait',
    );
  });

  test(
    'F3: connectivity comes back without an event -> the attempt goes within ~2 s, not after 10 x connection',
    () async {
      server = FakeSignalServer();
      final signal = FakeConnectivitySignalClient(server.connect);
      await viewer(signal: signal, connection: const Duration(seconds: 2)); // base wait: 20 s
      final dials = server.dials.length;
      signal.online = false;
      unawaited(engine.handleReconnect(ClientDisconnectReason.signal));
      await settle(300);
      expect(server.dials.length, dials, reason: 'offline: no dial');
      signal.online = true; // the per-app block is lifted: no connectivity event fires
      final t0 = DateTime.now();
      expect(
        await eventually(() => server.dials.length > dials, timeout: const Duration(seconds: 6)),
        isTrue,
        reason: 'base: waits for a SignalConnectivityChangedEvent that never comes',
      );
      expect(DateTime.now().difference(t0), lessThan(const Duration(milliseconds: 3000)));
      pcs.subscriber.connect();
    },
  );

  test('F3: the connectivity reading stays "none" but the server answers -> the attempt goes', () async {
    server = FakeSignalServer();
    final signal = FakeConnectivitySignalClient(server.connect);
    await viewer(signal: signal, connection: const Duration(seconds: 2));
    final dials = server.dials.length;
    signal.online = false; // stale: never flips back
    final t0 = DateTime.now();
    unawaited(engine.handleReconnect(ClientDisconnectReason.signal));
    // (the test HTTP client answers every request: the server is reachable)
    expect(
      await eventually(() => server.dials.length > dials, timeout: const Duration(seconds: 6)),
      isTrue,
      reason: 'base: waits 10 x connection for an event',
    );
    expect(DateTime.now().difference(t0), lessThan(const Duration(milliseconds: 3500)));
    pcs.subscriber.connect();
  });

  group('switches off = the 0.4.14/first-round behaviour', () {
    test('resumePrimaryDeadline: null -> the full Timeouts.peerConnection wait', () async {
      server = FakeSignalServer();
      await viewer(
        peerConnection: const Duration(seconds: 4),
        recovery: const GravixRecoveryOptions(resumePrimaryDeadline: null),
      );
      final dials = server.dials.length;
      final t0 = DateTime.now();
      pcs.subscriber.disconnect();
      autoConnectPcs(pcs);
      expect(
        await eventually(() => server.dials.skip(dials).any((u) => !isResume(u)), timeout: const Duration(seconds: 7)),
        isTrue,
      );
      expect(DateTime.now().difference(t0), greaterThanOrEqualTo(const Duration(milliseconds: 3800)));
    });

    test('leaveAbortsResumeWait: false -> the Leave does not end the wait', () async {
      server = FakeSignalServer();
      await viewer(recovery: const GravixRecoveryOptions(leaveAbortsResumeWait: false, resumePrimaryDeadline: null));
      var resumes = 0;
      server.afterResumeAnswer = (ws) {
        resumes++;
        if (resumes == 1) {
          Timer(const Duration(milliseconds: 87), () async {
            ws.deliver(
              lk_rtc.SignalResponse(
                leave: lk_rtc.LeaveRequest(
                  action: lk_rtc.LeaveRequest_Action.RESUME,
                  reason: lk_models.DisconnectReason.CONNECTION_TIMEOUT,
                ),
              ),
            );
            await ws.serverClose();
          });
        }
      };
      pcs.subscriber.disconnect();
      await settle(2000);
      expect(resumes, 1);
    });

    test('networkWaitProbeInterval: null -> only a connectivity event ends the wait', () async {
      server = FakeSignalServer();
      final signal = FakeConnectivitySignalClient(server.connect);
      await viewer(
        signal: signal,
        connection: const Duration(seconds: 2),
        recovery: const GravixRecoveryOptions(networkWaitProbeInterval: null),
      );
      final dials = server.dials.length;
      signal.online = false;
      unawaited(engine.handleReconnect(ClientDisconnectReason.signal));
      await settle(200);
      signal.online = true;
      await settle(2500);
      expect(server.dials.length, dials);
    });
  });
}
